# Publishing image updates

Maintainers publish Joomla through the Docker Official Images process. Users
then pull the released `joomla` tags from [Docker Hub](https://hub.docker.com/_/joomla);
they do not need this repository or a local image build.

After reviewing and testing an image change, the release command is:

```bash
./release.sh > ../official-images/library/joomla
```

Run it from the image repository with a checkout of `docker-library/official-images`
in the neighbouring `official-images` directory. It creates the library manifest
used by the Official Images build system. It does not upload images or open a
pull request. The manifest submission and the subsequent Official Images builds
are the steps that deliver the new tags to Docker Hub.

## Prepare the image changes

1. Update configuration or runtime source files using the [maintenance guide](maintenance.md).
2. Run `./generate.sh` and the [tests](testing.md).
3. Review and commit the changed inputs, `conf/versions.json`, and image contexts
   together. Check that CI passes for that commit.
4. Submit the changes against the upstream image repository's `staging` branch.
   Maintainers merge approved changes into `staging`, then into `master`, and
   verify the checks again. Update your publication checkout to that merged
   `master` commit before generating the final manifest. The commit must be
   available from the repository identified by `GitRepo`.

By default `release.sh` writes
`GitRepo: https://github.com/joomla-docker/docker-joomla.git`.
A commit that exists only on a fork cannot be fetched from that upstream URL.
Use the fork settings below while testing this branch; use the upstream default
for the upstream publication checkout after merge.

Use a full-history checkout when preparing a release. A shallow clone cannot
reliably identify the last commit affecting each context; fetch its history
with `git fetch --unshallow` before running `release.sh`.

The script requires its release inputs and each selected context to be tracked
and clean. It checks the
configured PHP parent and Joomla version against each Dockerfile, derives tags
and directories from the shared tag plan, and reads the official PHP manifest to
determine the parent architectures. Each context has its own `GitCommit`, based
on the last commit affecting that directory. Unchanged contexts retain their
existing pins even when another image changes. A source edit must therefore be
regenerated and committed before it can appear in an image release.

The generated comment links to `release.sh` at the checkout's current `HEAD`,
identifying the generator used to produce the manifest. That commit can differ
from the individual context pins. The global `Builder: buildkit` field selects
the supported BuildKit builder through Bashbrew for every image. Keep this field:
the Dockerfiles use `COPY --chmod`, which the deprecated legacy builder cannot
process.

## Prepare the neighbouring Official Images checkout

Fork [docker-library/official-images](https://github.com/docker-library/official-images)
on GitHub if you do not already have a fork. Sync that fork with upstream, then
clone it beside your `docker-joomla` publication checkout, using the directory
name `official-images`. For an existing checkout, update its `master` branch
from the synced fork before starting the submission branch. Both repositories
should have clean working trees.

The image repository supplies the committed Dockerfiles and runtime files; the
Official Images checkout receives the `library/joomla` manifest. No built image
files are copied between these repositories.

## Submit the manifest

Prepare a branch in your synced Official Images fork. With both repositories
checked out, the image repository remains your current directory:

```bash
git -C ../official-images switch -c joomla-update
./release.sh > ../official-images/library/joomla
git -C ../official-images diff -- library/joomla
```

Use an available branch name if `joomla-update` already exists. Review the tags,
architectures, `GitRepo`, `Builder`, `GitCommit` and `Directory` fields. Directory
paths must point into the committed `images/` tree. Only proceed if the release command
succeeded: shell redirection opens the destination before the script runs, so a
failed command can leave an empty destination. Correct the error and rerun it.

Then commit and push the manifest to your fork:

```bash
git -C ../official-images add library/joomla
git -C ../official-images commit -m 'Update Joomla images'
git -C ../official-images push -u origin HEAD
```

Open a pull request against
[docker-library/official-images](https://github.com/docker-library/official-images).
Describe the changed releases and image behaviour, and link the corresponding
image-repository commits. Follow the
[Official Images contribution and manifest requirements](https://github.com/docker-library/official-images/blob/master/README.md).

Do not change existing aliases casually: [release tracks](releases.md) explains
stable ownership, prerelease names and the development counterparts.

## Generate a manifest for a fork

Set the repository URL and fetch ref explicitly. This example reads the current
checkout's origin and branch, rather than assuming a particular fork or branch:

```bash
STACKBREW_GIT_REPO="$(git remote get-url origin)" \
STACKBREW_GIT_FETCH="$(git symbolic-ref HEAD)" \
    ./release.sh > ../official-images/library/joomla
```

Use a publicly fetchable HTTPS Git URL for `STACKBREW_GIT_REPO` when sharing the
manifest. If origin uses a private or SSH-only URL, supply the fork's public
HTTPS URL instead. The current branch and generated context commits must already
be pushed. `STACKBREW_GIT_FETCH` is useful for branch testing; it does not replace
the per-context commit hashes.

## Inspect a subset

`release.sh` accepts the same series or series/state selectors used during
generation. To inspect one configured track:

```bash
jq -r 'to_entries[] | .key as $series | .value.states | keys[] | $series + "/" + .' \
    conf/versions.json
read -r -p 'Track to inspect: ' track
./release.sh "$track"
```

A selected-track manifest contains only that selection. For a normal publication
update, use the full `./release.sh` command so the existing supported tracks stay
in the manifest. A retirement is an explicit change reviewed with the release.

## Confirm publication

The repository's CI checks image builds and runtime behaviour. Actual Official
Images publication happens through the manifest review and build process. A
merged source change or manifest is not evidence that every tag is already
available: the builders must complete publication for the selected architectures.
Check:

- The [Joomla manifest](https://github.com/docker-library/official-images/blob/master/library/joomla)
  for the accepted tags, commits, directories and architectures.
- The [Joomla publication pull requests](https://github.com/docker-library/official-images/labels/library%2Fjoomla)
  for review and build progress.
- The [official build status](https://doi-janky.infosiftr.net/job/repo-info/job/local/job/joomla)
  and [Docker Hub tags](https://hub.docker.com/_/joomla/tags) for published results.

Once the intended tag is listed on Docker Hub, verify it can be pulled. Select
the released tag rather than a local test tag:

```bash
read -r -p 'Published Joomla tag to verify: ' tag
: "${tag:?A published tag is required}"
docker pull "joomla:$tag"
docker image inspect --format '{{json .RepoDigests}}' "joomla:$tag"
```

This checks availability for your Docker platform. Review the official build
results for the other declared architectures as well. A normal, prerelease or
development tag becomes usable by consumers only after its publication succeeds.

The public Docker Hub description is maintained in
[docker-library/docs/joomla](https://github.com/docker-library/docs/tree/master/joomla).
Update it separately when the published image's user-facing contract changes.
