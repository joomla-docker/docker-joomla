# Testing image changes before release

This guide is for maintainers and contributors validating changes from a local
checkout before requesting an Official Images release. For running Joomla or
developing a site with a published image, follow [Using the images](usage.md) or
[Development images](development.md) and pull from Docker Hub.

There are two separate checks: testing the shell generators and building and
testing actual Docker images. Generator tests do not prove that a package
compiles or that a container serves Joomla. Run the commands below from the
repository root unless stated otherwise.

## Host requirements

Generation uses Bash, jq, curl and standard Linux utilities, including GNU
coreutils, findutils, awk, sed and grep. Tests also use Git and PHP CLI.
ShellCheck checks the generator, runtime and test scripts. No Python interpreter or template engine is
needed to generate Dockerfiles.

On a Debian-based development host, install the generator and test tools with:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bash jq curl git coreutils findutils gawk sed grep shellcheck php-cli
```

Actual image tests require a working Docker daemon running Linux containers
and the Docker Buildx plugin, which builds the images with BuildKit.
Docker Engine on Linux or Docker Desktop can provide it. On Windows, run the
commands in a Linux WSL 2 environment with
[Docker Desktop integration enabled](https://docs.docker.com/desktop/features/wsl/).
A Linux
VM is another option for a desktop whose host tools differ from GNU utilities.
Keep the checkout and test commands in that Linux environment.

Check that the daemon is reachable before attempting a build:

```bash
docker version
docker info
docker buildx version
```

The FPM tests also require `cgi-fcgi` in the environment running the test scripts;
on a Debian-based host it is provided by `libfcgi-bin`:

```bash
sudo apt-get install -y --no-install-recommends libfcgi-bin
```

Docker Compose is needed for the examples in [Using the images](usage.md), but
not for the generator tests or the direct Docker runtime test scripts.

## Check the generators

```bash
shellcheck generate.sh release.sh src/build/*.sh src/build/lib/*.sh src/runtime/*.sh tests/*.sh
for suite in assemble generate config versions tags manifest build cleanup hardening makedb; do
  "./tests/test-$suite.sh" || exit 1
done
```

The suites create isolated temporary fixtures. Package downloads and package
manager calls used by these unit-style checks are mocked; their behaviour and
failure handling are tested without installing the image's packages on the
host.

| Suite | Main responsibility |
| --- | --- |
| `test-assemble.sh` | Source discovery, profile selection, overrides, invalid source rejection and deterministic assembly |
| `test-generate.sh` | The root command's orchestration, argument forwarding and invocation from outside the repository |
| `test-config.sh` | Configuration schema, required values and invalid combinations |
| `test-versions.sh` | Download URL expansion, hashes, caching, selective force refresh and preservation of the previous resolved file on failure |
| `test-tags.sh` | Release states, aliases, PHP defaults, development tags, collisions and context paths |
| `test-manifest.sh` | BuildKit publication metadata, generator provenance, architecture parsing, selected contexts and independent committed-context pins |
| `test-build.sh` | Dockerfile contents, runtime file copies, installation/check/cleanup order, quoting and deterministic generation |
| `test-cleanup.sh` | Debian and Alpine dependency retention and removal behaviour |
| `test-makedb.sh` | PostgreSQL connection-string quoting, query parameters, database identifiers and failure handling using isolated PHP stubs |
| `test-hardening.sh` | Real PHP settings, copying/removing the active profile while preserving its source, repeat startup and restoration of the underlying configuration in an isolated INI directory |

Inspect assembled inputs without downloading artifacts:

```bash
bash src/build/lib/assemble-config.sh conf/versions-helper.json | jq .
```

Then regenerate and review all tracked changes:

```bash
./generate.sh
git diff --check
git status --short
git diff -- conf images
```

`src/build/build.sh` reads the resolved `conf/versions.json` and writes contexts;
it does not refresh download metadata. Running it twice with unchanged inputs
must produce the same files. CI compares context checksums before and after the
second generation. A changed Joomla release should leave the earlier extension
and PHP configuration layers unchanged unless their own inputs also changed.

## Build and test one candidate on your machine

Start here when changing a particular release, runtime or development profile.
Run `./generate.sh` first as shown above. The example lists configured context
directories with their variant and development flag, then asks which one to
test. Choose the affected directory from that list; it works for stable and
prerelease tracks and for normal and development images.

```bash
(
set -Eeuo pipefail
plan="$(jq -c -f src/build/lib/tags.jq conf/versions.json)"
jq -r '.[] | [.directory, .variant, .development] | @tsv' <<<"$plan"
read -r -p 'Context directory to test: ' directory
context="$(jq -ce --arg directory "$directory" \
  '.[] | select(.directory == $directory)' <<<"$plan")"
variant="$(jq -r '.variant' <<<"$context")"
development="$(jq -r '.development' <<<"$context")"
image=joomla-test:candidate

docker buildx build --load --pull --progress=plain --tag "$image" "$directory" \
  2>&1 | tee /tmp/joomla-candidate-build.log
./tests/test-images.sh "$image" "$variant" "$development"
./tests/test-joomla.sh "$image" "$variant"
./tests/test-joomla.sh "$image" "$variant" true
docker history "$image"
)
```

`joomla-test:candidate` is a local validation tag. The parentheses scope the shell
failure settings, and `pipefail` preserves a failed build's status when its log
is also written by `tee`. `--pull` refreshes the PHP parent image. `--load` makes
the built image available to the local Docker daemon for the runtime tests. Keep
the log when reporting a failure, together with the context directory, source commit
and host architecture. The next run replaces this candidate tag and log.

The first test checks PHP modules and the tooling appropriate to that image.
The second starts a disposable database and verifies an actual Joomla install,
page request and CLI command. This can also expose release-specific Joomla
compatibility problems that a successful Docker build cannot detect. The
scripts remove their temporary containers and networks, while the local image
and build log remain available for inspection.

One successful local build covers your Docker platform and selected context.
For shared configuration or runtime changes, test all affected PHP profiles,
normal and development images, and Debian and Alpine variants. The full matrix
below and CI provide broader coverage; Official Images builds establish the
publication result for each declared architecture.

## Build and test every configured image

This reads the same context plan used by generation, CI and release metadata.
It includes all configured Joomla tracks, PHP profiles, variants and selected
development images without maintaining a separate version list:

```bash
(
set -Eeuo pipefail
plan_file="$(mktemp)"
trap 'rm -f "$plan_file"' EXIT
jq -c -f src/build/lib/tags.jq conf/versions.json > "$plan_file"
while IFS= read -r context; do
  directory="$(jq -r '.directory' <<<"$context")"
  image="joomla-test:$(jq -r '.tags[0]' <<<"$context")"
  variant="$(jq -r '.variant' <<<"$context")"
  development="$(jq -r '.development' <<<"$context")"
  docker buildx build --load --pull --progress=plain --tag "$image" "$directory"
  ./tests/test-images.sh "$image" "$variant" "$development"
  if jq -e '.tags | index("latest") != null' <<<"$context" > /dev/null; then
    ./tests/test-joomla.sh "$image" "$variant"
    ./tests/test-joomla.sh "$image" "$variant" true
  fi
done < <(jq -c '.[]' "$plan_file")
)
```

The parentheses keep the failure settings and exit trap in a subshell.
`set -e` stops at the first failure, and the trap removes the temporary plan.
The test containers and
networks are disposable; the test scripts remove the resources they create.
The locally tagged test images remain available for inspection.

`test-images.sh` verifies PHP startup, required modules and opt-in hardening
with the image's real PHP configuration and isolated lifecycle checks. It checks
repeated on/off cycles, restoration of the original PHP settings, source-profile
preservation and already configured non-root/read-only starts. Normal images
are checked for the absence of development tooling. Development images also check
Composer, npm and native build tools; a small offline npm build; Xdebug mode
overrides; and real debugger protocol exchanges from CLI and HTTP/FastCGI
requests. The tests check that temporary installers and bootstrap files were
removed.

`test-joomla.sh` starts a disposable database, automatically installs Joomla
through the normal entrypoint, requests a page, and runs the installed Joomla
CLI as the web user. The database image reference is maintained in that test
script. Its optional third argument enables hardening when set to `true`.
CI runs this installation check both with and without hardening for the context owning `latest`; it does
not install every prerelease against every supported database.

To investigate a failed matrix entry, use its directory with the single-candidate
recipe above. Read the first relevant compiler, installer or runtime failure in
the saved log; the final Docker exit message usually only reports that the
earlier command failed.

## What the workflows enforce

[`verify-build.yml`](../.github/workflows/verify-build.yml) runs ShellCheck and
the generator suites, then regenerates the configured outputs. It rejects
uncommitted differences in `conf/versions.json` and the active image contexts.
Commit edited source configuration, the resolved file and generated contexts
together.

[`ci.yml`](../.github/workflows/ci.yml) creates its matrix from the shared
context plan, checks deterministic generation and rejects uncommitted outputs.
It then runs `release.sh` with full Git history, checks `Builder: buildkit`, and
verifies that every manifest pin contains the same context tree as the reviewed
checkout. The manifest is retained as the `publication-manifest` workflow
artifact for inspection; regenerate it from the publication checkout before
submission, as branch CI does not validate remote fetchability. Each matrix job
extracts its context with `git archive` from that
exact pin and builds it using native Docker Buildx. This exercises the committed
inputs selected for publication, rather than an uncommitted generated directory.
No Bashbrew installation is required.

After building, CI runs the Docker Official Images test suite and this
repository's runtime tests, plus the Joomla installation check for `latest`.
A scheduled run also detects changes in mutable parent images or distribution
packages. These jobs test the runner's architecture; the Official Images
pipeline still validates its own manifest processing and all publication
architectures.

The publication manifest requires committed, clean contexts and full Git history
so each directory's last change can be identified independently. After committing,
verify it separately with:

```bash
./release.sh > /tmp/joomla-library-review
```

Review the result before following [Publishing](publishing.md). Generating a
manifest does not publish an image. Its comment identifies `release.sh` at the
checkout's `HEAD`; the image entries retain their independent context commits.
The global `Builder: buildkit` field makes Bashbrew use the same modern builder
as the image tests. Omitting it selects Bashbrew's legacy backend, even when
ordinary local Docker builds use BuildKit by default.

## Before requesting publication

- Review the source changes and generated differences together. There should be
  no unexplained URL, checksum, tag or dependency changes.
- Require the shell checks and generated-output checks to pass, and resolve
  failures in the affected image builds and runtime tests.
- Confirm the image repository's CI passes for the reviewed publication commit.
  A local build alone does not cover the entire configured matrix.
- Generate and review the manifest from committed, clean contexts, then follow
  the [publication steps](publishing.md). Keep build and test results with the
  change so reviewers can see what was exercised.

## Diagnose failures at the correct stage

| Symptom | Where to look and what to check |
| --- | --- |
| Source file or profile cannot be found | Check paths in `conf/versions-helper.json`, numeric profile filenames and selected PHP keys. Index paths are relative to the index file. |
| Invalid version, state or duplicate tag | Compare the state key, release string and aliases in `conf/joomla/`. Prereleases must keep their state in aliases. See [Releases](releases.md). |
| Artifact download or checksum failure | Check the resolved URL, source version and upstream release asset. Do not bypass the checksum. A failed resolution leaves the previous `conf/versions.json` in place. |
| A cached URL was not downloaded again | `versions.sh` reuses matching metadata. Use the documented `--force` option when an intentional re-fetch is required; inspect the resulting hash change. |
| APT/APK package is unavailable | Check the selected PHP base image and its distribution. Package names can differ between Debian and Alpine. |
| PIE/PECL or bundled extension fails to compile | Read the first compiler/configure error. Check PHP compatibility and the profile's temporary development headers and tools. |
| PHP reports a missing shared library after cleanup | Inspect the retained dependency calculation and runtime package list. Keep the required library; do not retain the entire compiler toolchain as a workaround. |
| npm rejects its Node.js engine | Node.js comes from the base distribution; select a compatible npm release in the profile or deliberately update the base/runtime configuration. |
| Generated-output check fails in CI | Run `./generate.sh`, inspect `git diff`, and commit both configuration and generated output. Do not edit Dockerfiles directly. |
| Manifest reports an untracked or dirty context | Commit the generated context, including its copied runtime files, before running `release.sh`. |
| Manifest reports shallow Git history | Run `git fetch --unshallow`, then regenerate the manifest so unchanged image contexts retain their own commit pins. |
| Publication uses a different builder from CI | Confirm the generated manifest includes the global `Builder: buildkit` field. |
| Container cannot connect to the database | Check host/port, network, credentials, readiness and database permissions; inspect `docker compose logs`. |
| A new container still serves the old Joomla release | Inspect the persistent site volume. Image replacement does not overwrite an installed site. See [Using the images](usage.md). |
| Xdebug loads but the IDE does not stop | Check the trigger, outbound address/port, listener and path mappings using [Development images](development.md#check-an-ide-connection). |

The shell scripts and tests use failure messages to identify the stage. For
architecture and shell syntax explanations, follow
[How generation works](generation.md) alongside the relevant script.
