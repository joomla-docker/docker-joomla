# About this Repo

This is the Git repo of the Docker [official image](https://docs.docker.com/docker-hub/official_repos/) for [joomla](https://registry.hub.docker.com/_/joomla/). See [the Docker Hub page](https://registry.hub.docker.com/_/joomla/) for the full readme on how to use this Docker image and for information regarding contributing and issues.

The full readme is generated over in [docker-library/docs](https://github.com/docker-library/docs), specifically in [docker-library/docs/joomla](https://github.com/docker-library/docs/tree/master/joomla).

See a change merged here that doesn't show up on the Docker Hub yet? Check [the "library/joomla" manifest file in the docker-library/official-images repo](https://github.com/docker-library/official-images/blob/master/library/joomla), especially [PRs with the "library/joomla" label on that repo](https://github.com/docker-library/official-images/labels/library%2Fjoomla). For more information about the official images process, see the [docker-library/official-images readme](https://github.com/docker-library/official-images/blob/master/README.md).

---

### Build / Manifest Architecture Support

| Overall Status | Supported Architectures |
|---|---|
| [![All arches status](https://doi-janky.infosiftr.net/job/repo-info/job/local/job/joomla/badge/icon)](https://doi-janky.infosiftr.net/job/repo-info/job/local/job/joomla) | ✅ [amd64](https://hub.docker.com/r/amd64/joomla/) • ✅ [riscv64](https://hub.docker.com/r/riscv64/joomla/) • ✅ [arm32v5](https://hub.docker.com/r/arm32v5/joomla/) • ✅ [arm32v6](https://hub.docker.com/r/arm32v6/joomla/) • ✅ [arm32v7](https://hub.docker.com/r/arm32v7/joomla/) • ✅ [arm64v8](https://hub.docker.com/r/arm64v8/joomla/) • ✅ [i386](https://hub.docker.com/r/i386/joomla/) • ✅ [ppc64le](https://hub.docker.com/r/ppc64le/joomla/) • ✅ [s390x](https://hub.docker.com/r/s390x/joomla/) |

[See OS/ARCH](https://registry.hub.docker.com/_/joomla/?tab=tags) on official images.

---

### Repository checks

| Check | Status |
| --- | --- |
| This branch: image builds and runtime tests | [![Image tests](https://github.com/joomla-docker/docker-joomla/actions/workflows/ci.yml/badge.svg)](https://github.com/joomla-docker/docker-joomla/actions/workflows/ci.yml) |
| This branch: generation and shell tests | [![Generation tests](https://github.com/joomla-docker/docker-joomla/actions/workflows/verify-build.yml/badge.svg)](https://github.com/joomla-docker/docker-joomla/actions/workflows/verify-build.yml) |

These branch checks validate proposed image definitions. Published tag and
architecture availability is recorded in the Official Images manifest linked
above.

## Use the images

Pull the official Joomla image from [Docker Hub](https://hub.docker.com/_/joomla):

```bash
docker pull joomla:latest
```

Use `image: joomla:latest` in your Compose file, or choose a specific published
tag from Docker Hub. The [usage guide](docs/usage.md) provides a complete Compose
example with a database, persistent storage and update instructions. Docker
downloads the image for you; using it requires no checkout of this repository.

For Composer, frontend tooling and Xdebug, see [development images](docs/development.md).
Choose development and prerelease tags from the published Hub listing; a tag
configured on a development branch becomes available after the Official Images
release process completes.

## Maintain and test the images

Contributors work in a repository checkout. Edit the matching Joomla file in
`conf/joomla/` or PHP profile in `conf/php/`, then run from the repository root:

```bash
./generate.sh
```

This resolves download URLs and hashes into `conf/versions.json` and regenerates
the build contexts under `images/`. Follow the [maintenance guide](docs/maintenance.md)
to prepare a change and [testing guide](docs/testing.md) to build and test candidate
images locally before release. Commit source configuration, resolved configuration
and generated files together for review.

A new Joomla series or PHP profile is discovered from its JSON filename.
Routine Joomla release bumps change the state's `version`; its configured URL
pattern supplies the new package URL. See [release tracks](docs/releases.md)
for alpha, beta, RC and stable release management.

## Prepare an Official Images release

After review, successful checks and merge into the publication branch, run from
that checkout with an `official-images` checkout alongside:

```bash
./release.sh > ../official-images/library/joomla
```

Review and submit that manifest through the Official Images pull-request
process. The Official Images infrastructure builds and publishes the accepted
images to Docker Hub. This command prepares the manifest. See
[publishing](docs/publishing.md) for the complete release procedure and how to
confirm that the new tags are available.

## Documentation

| Guide | What it covers |
| --- | --- |
| [Usage](docs/usage.md) | Pull official images, run Joomla with Compose and update containers |
| [Development](docs/development.md) | Use published development images, project tools and Xdebug |
| [Maintenance](docs/maintenance.md) | Update software and take a change through to Docker Hub |
| [Testing](docs/testing.md) | Build candidates locally, run checks and investigate failures |
| [Publishing](docs/publishing.md) | Submit the Official Images manifest and confirm publication |
| [Release tracks](docs/releases.md) | Add and promote alpha, beta, RC and stable releases |
| [Configuration](docs/configuration.md) | JSON settings, PHP profiles and development tools |
| [Generation walkthrough](docs/generation.md) | Diagrams and a guided explanation of the shell scripts |

The [documentation index](docs/README.md) also explains the repository layout.
