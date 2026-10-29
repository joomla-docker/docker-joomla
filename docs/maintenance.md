# Maintaining the images

This guide is for contributors preparing changes to the Joomla Docker Official
Image. To run Joomla or develop a Joomla site, pull the published `joomla` image
from [Docker Hub](https://hub.docker.com/_/joomla) using the
[usage](usage.md) or [development](development.md) guide.

## From a change to Docker Hub

An image update passes through two repositories: this repository holds the image
sources, and `docker-library/official-images` holds the manifest telling the
Official Images builders which committed sources and tags to publish.

1. Work on a branch in your fork of the image repository. Edit the small source
   files under `conf/` or the runtime files under `src/runtime/`.
2. Run `./generate.sh`. It resolves the complete build configuration into
   `conf/versions.json` and generates the Docker build contexts under `images/`.
3. Build the affected candidate images on your development machine and run the
   [generator and image tests](testing.md). These local builds verify the changes
   before publication. Commit the source and generated changes together.
4. Submit the image changes for review against the upstream `staging` branch.
   After checks pass, maintainers merge into `staging`, then into `master`, and
   check the publication commit's CI results.
5. From that committed upstream publication checkout, generate the manifest
   into a neighbouring checkout of your Official Images fork:

   ```bash
   ./release.sh > ../official-images/library/joomla
   ```

   Review and commit the manifest, push your branch, and submit a pull request
   to `docker-library/official-images`. The [publishing guide](publishing.md)
   explains the checkout setup, review fields and submission commands.
6. Follow the Official Images review and build results. Once the accepted images
   are published on Docker Hub, users pull the official `joomla` tags in Docker
   or Compose. Confirm the published tags as described in
   [Confirm publication](publishing.md#confirm-publication).

Generating files, passing this repository's CI, or merging the image changes
does not by itself publish a Docker Hub tag. Publication follows the Official
Images manifest process; maintainers do not upload their locally tested images
to the official `joomla` namespace.

Use [release management](releases.md) for Joomla alpha, beta, RC and stable
tracks. The [configuration reference](configuration.md) explains every group,
and the [generation walkthrough](generation.md) explains the scripts themselves.

## Prepare the working environment

Use a Linux environment with Bash, Git, jq, curl, and the usual GNU command-line
tools, including `readlink`, `mktemp`, `sha256sum` and `sha512sum`. The scripts are
Bash scripts; do not invoke them with `sh`. ShellCheck is needed for the shell
checks. For local image validation, use Docker Engine or Docker Desktop running
Linux containers. On a Windows desktop, run the repository commands in a Linux
WSL 2 environment with Docker integration enabled. On other desktops, a Linux
VM provides the same GNU tool environment. See [testing](testing.md) for setup
and a first candidate build. Generation itself does not require Docker, PHP,
Python or a template engine.

Work on a branch and run the commands below from the repository root. The
entry scripts find the repository relative to their own location, so calling an
entry script by its path from another working directory also works.

An optional `GITHUB_TOKEN` or `GH_TOKEN` lets the release resolver authenticate
its GitHub API requests. Supply credentials through the environment or CI secret
configuration, never in JSON or a committed file.

## Find the configuration to edit

List the source files:

```bash
printf '%s\n' conf/joomla/*.json conf/php/*.json
```

Inspect the currently resolved release tracks:

```bash
jq -r '
  to_entries[] | .key as $series | .value.states | to_entries[]
  | [$series, .key, .value.version, .value.php, .value.packageType] | @tsv
' conf/versions.json
```

Use the source file belonging to the series or PHP profile you are changing.
Do not edit generated `Dockerfile` files or their copied runtime files. Runtime
behaviour is maintained in `src/runtime/docker-entrypoint.sh` and
`src/runtime/makedb.php`.

## Normal update workflow

1. Edit the relevant files under `conf/` or `src/runtime/`.
2. Run `./generate.sh`. This resolves changed direct downloads and regenerates
   all configured contexts under `images/`.
3. Inspect `git diff --stat` and `git diff`. Check source selections, resolved
   URLs and hashes, package removals, aliases, and the generated Dockerfiles.
4. Run the [generator tests and relevant Docker tests](testing.md).
5. Commit the edited sources, `conf/versions.json`, and affected `images/`
   contexts together. Include implementation, tests and documentation when
   those changed too.
6. Push the branch for review and CI against upstream `staging`. After the
   reviewed changes reach `master` and its checks pass, follow
   [publishing](publishing.md) to request the Official Images update.

The generator intentionally leaves directories for removed tracks alone.
Removing configuration and deleting an old context are separate decisions;
see [retiring a track](releases.md#retire-a-track-or-series).

## Update one selected track

A selector is a series or `series/state`. Discover the values rather than
copying an old release number from a guide:

```bash
jq -r 'to_entries[] | .key as $series | .value.states | keys[] | $series + "/" + .' conf/versions.json
read -r -p 'Track to regenerate: ' track
./generate.sh "$track"
```

This limits generated contexts to the selection. The resolver still assembles
and validates the whole configuration and checks all aliases for collisions.
Unselected releases must have reusable resolved metadata. If another source
release or artifact has changed, include it too or run `./generate.sh` without
selectors. A PHP profile shared across series is usually best regenerated with
no selector so every affected Dockerfile stays in sync.

To regenerate Dockerfiles from an already resolved snapshot without resolving
versions or downloading artifacts:

```bash
./src/build/build.sh
```

To resolve configuration without generating Dockerfiles:

```bash
./src/build/versions.sh
```

## Download cache and force refresh

Ordinary generation reuses a Joomla checksum when the release version, package
URL and archive type still match. Tool downloads reuse a checksum by their
resolved artifact URL. Changing a URL with `{version}` changes that cache key
when the version changes. A fixed URL whose bytes change needs a force refresh.

Force a fresh check of all configured downloads with:

```bash
./generate.sh --force
```

Or refresh the selected track using the `track` value selected above:

```bash
./generate.sh --force "$track"
```

A shared artifact referenced by a selected series is refreshed once and its hash
is reused across all references. Unselected Joomla releases with unchanged
metadata remain cached. Review unexpected hash changes before committing them;
`--force` accepts newly fetched bytes after the configured publisher checks, it
does not prove that an upstream replacement was intentional.

Download or validation failure leaves the previous resolved JSON intact.
Dockerfile generation stages every selected context before replacing generated
files. The two stages are sequential: if rendering fails after resolution,
`conf/versions.json` may already be updated while the previous image contexts
remain. Correct the failure and rerun generation before committing.

## Update an existing PHP profile

Open the matching file under `conf/php/`. It is shared by every Joomla series
selecting that PHP version. Changes to its base settings affect normal and
matching development images through inheritance; changes under `dev` affect
only development images. Keep `dev` limited to additions and overrides needed
for development. Per-variant settings apply to the normal parent.

When changing a base-image tag, update the corresponding `variants` entries and
check compatibility with the selected PHP extensions, distribution package names
and runtime commands. The manifest generator discovers architectures from the
official PHP image metadata; do not maintain a second architecture list in the
profile. The supported base-image format is an official `php:` tag.

Use an explicit OS release in each base reference, such as
`php:8.4-apache-trixie` or `php:8.4-fpm-alpine3.24`. This keeps OS release
transitions under review while allowing PHP and distribution updates within
the selected release. These base references do not change the published Joomla
tag names or the `apache`, `fpm` and `fpm-alpine` variant names.

A base tag can receive upstream rebuilds without a JSON change. Use Docker's
`--pull` option when validating against the refreshed base. Updating a tool pin
or extension requirement is still an explicit source change.

Choose PHP versions using the [Joomla roadmap](https://developer.joomla.org/roadmap),
the [Joomla 5 requirements](https://manual.joomla.org/docs/5.4/get-started/technical-requirements/)
and [Joomla 6 requirements](https://manual.joomla.org/docs/next/get-started/technical-requirements/).
Joomla compatibility does not extend [upstream PHP security support](https://www.php.net/supported-versions.php).
Retire the PHP 8.2 image selections when that support ends on 31 December 2026;
Joomla 5 also provides PHP 8.3 images. Development images remain focused
on the current Joomla 6 series.

## Add a PHP version

Create a new complete profile by copying the most suitable existing one:

```bash
printf '%s\n' conf/php/*.json
read -r -p 'Existing PHP profile to copy, without .json: ' source_php
read -r -p 'New PHP major.minor: ' new_php
[[ "$source_php" =~ ^[0-9]+\.[0-9]+$ && "$new_php" =~ ^[0-9]+\.[0-9]+$ ]] &&
  test -f "conf/php/$source_php.json" &&
  test ! -e "conf/php/$new_php.json" &&
  cp "conf/php/$source_php.json" "conf/php/$new_php.json"
```

Before generating, review the new file completely:

- Set every `variants` base-image tag to the intended PHP release and runtime.
- Review bundled extensions, configure flags and enablement against that PHP
  release. An extension becoming built in can change the required enablement.
- Check PIE/PECL compatibility and the versions of every pinned extension.
- Check APT and APK package names for the selected base distributions.
- Review `dev`, especially Xdebug compatibility, Composer, Node/npm requirements
  and the commands used to verify those tools.
- Keep runtime dependencies separate from build-only dependencies.

In each Joomla series that supports it, add the new PHP key under `phpVersions`
with `development: true` or `false`. Change a state's `php` only if that new PHP
version should receive that state's default aliases. Adding the profile file
alone does not select it for a Joomla series. Development selections require a
`dev` object in the assembled profile.

Run `./generate.sh`, inspect the expanded matrix and exercise every selected
runtime variant with the tests described in [testing](testing.md). No index or
shell-script version list needs updating.

## Add or update software

Choose the existing installation mechanism that fits the package:

| Software type | Configuration to change | Additional work |
| --- | --- | --- |
| Distribution utility | `apt` and `apk` | Use each distribution's package name; retain it only where needed |
| Temporary compiler/library headers | `build.apt` and `build.apk` | Confirm the runtime still works after cleanup |
| Bundled PHP extension | `extensions.install`, optionally `extensions.configure` | Add the needed build libraries; installation also enables and checks it |
| External PHP extension available through PIE | `pie` | Add build dependencies and its runtime name in `extensions.check` |
| Extension installed through PECL | `pecl` | Add `extensions.enable` and `extensions.check`; remove its PIE selection |
| Global npm tool | `npm` | Ensure a compatible Node.js and npm bootstrap are available; add a command check |
| Tool requiring a direct pinned download | `download` | Specify URL, install type and destination; add a command check |

Apply these groups inside `dev` when the package is only for development.
Use variant settings only when the difference is specific to that runtime.
To change one Joomla series' use of a shared profile, use its explicit
`phpVersions` selection's `overrides` object. Read the
[two merge steps](configuration.md#the-two-merge-steps) before replacing lists.

APT and APK package lists are separate because their package names and cleanup
mechanisms differ. Runtime and build lists are separate because build packages
must be removed while requested runtime utilities remain. Combining them loses
that distinction and can either enlarge the image or remove required tools.

PIE and PECL are explicit alternatives. A build failure is not silently retried
through another installer. When moving a package to PECL, remove its PIE entry,
set the PECL package name and pin, enable its module using the Docker helper,
and verify its runtime module name. Custom extension archive builds are not part
of the configuration flow.

For a direct download, prefer a version-bearing URL using `{version}` and a
publisher checksum URL when supplied. `versions.sh` generates the hash; do not
paste it into the profile. Set `temporary: true` for an installer needed only
during the build, and verify that no retained command depends on its removed
files. The `download` formats and limitations are listed in the
[configuration reference](configuration.md#direct-downloads-and-hashes).

Node.js follows the selected distribution. The development profile temporarily
installs the distribution's npm, uses it to install the configured npm release
under `/usr/local`, and removes the bootstrap with the build dependencies.
The installation enforces engine compatibility. Composer remains a direct PHAR
download so it does not pull in a separate distribution PHP runtime.

Project-specific Composer dependencies, frontend packages and test frameworks
belong in the application's lock files. Add a global image tool only when it is
part of the intended shared development environment.

## Keep image verification aligned

Every external extension needs a runtime load check, and every added executable
should have an appropriate harmless `checks` command when practical. These
commands run after dependency cleanup and final configuration, so they catch
missing libraries and executables in the resulting image.

For new behaviour, extend the relevant shell tests and runtime tests. Source-only
checks cannot establish that a package builds on every supported base. Review
normal and development contexts and both distribution families when a shared
profile changes.

Changes to `src/runtime/` are copied into normal image contexts by `build.sh`.
Development contexts contain only a Dockerfile and inherit those runtime files
from their matching normal image. Never change generated copies independently
or replace them with links outside the Docker build context.
