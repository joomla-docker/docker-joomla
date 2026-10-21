# Configuration reference

The files under `conf/` describe the image contents. Shell scripts implement the
installation and generation mechanics. Make package and release changes in the
source JSON, run `./generate.sh`, and commit the sources, `conf/versions.json`,
and generated contexts together.

Start with [maintenance](maintenance.md) for a routine change,
[releases](releases.md) for release tracks, or [the generation walkthrough](generation.md)
to follow the shell implementation.

## Source files and resolved configuration

| File or directory | Maintained content |
| --- | --- |
| `conf/versions-helper.json` | Index pointing to the three configuration sources below |
| `conf/archives.json` | Archive format names and temporary extraction packages |
| `conf/joomla/` | One JSON file per numeric Joomla series: selected PHP profiles, variants and release states |
| `conf/php/` | One complete JSON profile per numeric PHP version |
| `conf/maintainers.json` | Maintainer names, email addresses and GitHub handles used in image labels and the publication manifest |
| `conf/versions.json` | Generated snapshot with complete image settings, resolved URLs and download checksums |

The default index is:

```json
{
  "archives": "archives.json",
  "phpVersions": "php",
  "joomlaVersions": "joomla"
}
```

Index paths are relative to the index file. The assembler discovers `*.json`
files in the two directories. Filenames must be numeric `major.minor.json`;
the filename supplies the corresponding version key. Creating a new file needs
no entry in a shell script or index list. Each file must contain one JSON object.

A PHP profile is complete and reusable. It does not inherit another PHP file.
A Joomla series chooses the profiles it supports. No Joomla or PHP version
threshold implicitly enables development images.

`conf/versions.json` is committed, generated data. It contains the expanded
profiles and archive settings for each series; it has no source-file references
or unresolved URL placeholders. `build.sh` reads this snapshot, never the source
fragments. `conf/maintainers.json` supplies the separate maintainer metadata.
Do not hand-edit hashes into source files: the assembler rejects them, including
in profiles not currently selected by a Joomla series.

## Local configuration overrides

`versions.sh` chooses its source index in this order:

1. The `VERSIONS_HELPER` environment variable, when nonempty.
2. `conf/.versions-helper.json`, when present.
3. `conf/versions-helper.json`.

The local index is ignored by Git. It uses exactly the same index format; it is
not a partial object merged into the default index. A relative `VERSIONS_HELPER`
path is resolved from the repository root, while paths inside that index are
resolved from the index's directory. An absolute index path is also supported.

Local overrides still generate the normal `conf/versions.json` and `images/`
outputs. Review the diff before committing, and regenerate with the default
index before submitting changes intended for the shared configuration.

To inspect source assembly without downloading anything:

```bash
bash src/build/lib/assemble-config.sh conf/versions-helper.json | jq .
```

Assembly alone checks file structure and profile selection. The complete
semantic and tag validation occurs in `versions.sh`.

## Joomla series and release states

Each Joomla series file has the following fields:

| Field | Meaning |
| --- | --- |
| `phpVersions` | Map of selected PHP profile names to selection objects |
| `variant` | Default runtime variant for unsuffixed aliases |
| `variants` | Runtime variants to generate: `apache`, `fpm`, and/or `fpm-alpine` |
| `states` | Configured `stable`, `alpha`, `beta` and/or `rc` tracks |

A PHP selection accepts `development` and `overrides`. `development: true`
includes the profile's `dev` configuration and requires it to exist. False or
omitted removes the development configuration after applying overrides.
`overrides` is an optional object containing changes to that selected profile
for this Joomla series only.

Every state owns:

| Field | Meaning |
| --- | --- |
| `version` | Exact release version, including the prerelease suffix when applicable |
| `aliases` | Additional publication aliases; the exact version is always included |
| `php` | Selected PHP profile receiving the default aliases for this state |
| `packageType` | Archive format: `tar.zst`, `tar.gz`, or `tar.bz2` |
| `package` | HTTPS package URL, optionally using the fixed substitutions below |

`php` and `packageType` must be in each state, not at series level. The default
PHP must be one of that series' selected profiles. It chooses aliases; it does
not narrow the build matrix. Every selected PHP profile is built for every
selected variant and configured state, with matching development contexts where
enabled. Supported variants must have matching settings in the selected profiles.

The source `package` may be omitted to use the resolver's official Joomla full
package URL. Keeping it explicit makes the source easier to review. The resolved
file always contains `package` and `sha512`.

See [release management](releases.md) for version syntax, alias ownership and
promotion between release states.

## PHP profile fields

The same installation fields can appear in a profile, its `dev` additions, or
its applicable variant settings. A complete profile also supplies the required
runtime metadata and base variants.

| Group | Meaning |
| --- | --- |
| `apt`, `apk` | Distribution packages retained in the final image; only the matching manager is used |
| `build.apt`, `build.apk` | Temporary build dependencies installed with the base image's `$PHPIZE_DEPS` |
| `extensions.configure` | Bundled module names mapped to configure-argument arrays |
| `extensions.install` | Bundled modules compiled and enabled with `docker-php-ext-install` |
| `extensions.enable` | Already compiled modules enabled with `docker-php-ext-enable` |
| `extensions.check` | Additional PHP runtime module names that must load after cleanup |
| `pie`, `pecl` | Extension package names mapped to pinned versions |
| `npm` | Globally installed npm package names mapped to pinned versions |
| `download` | Explicit artifact downloads, versions, installation types and destinations |
| `config` | Absolute file paths mapped to complete arrays of configuration lines |
| `environment` | Runtime environment variables mapped to string defaults |
| `checks` | Commands to run during the build, each expressed as an array of arguments |
| `variants` | Named variant settings including an official `php:` base image and runtime `command` array |
| `apache.modules`, `apache.enable` | Apache modules and configuration names to enable |
| `apache.remoteAddress` | Whether to replace Apache log `%h` fields with `%a` for configured remote-IP handling |
| `dev` | Additional installation, configuration and runtime settings for development images |
| `volume`, `workdir`, `entrypoint` | Docker runtime metadata |

Version pins in `pie`, `pecl`, `npm` and `download` currently use numeric
`major.minor.patch` strings. Ranges, moving labels and prerelease pins for these
tools are not accepted. Joomla release states have their own prerelease syntax.

Commands in `checks` are literal argument lists, not shell fragments. Put the
executable in the first array element and each argument in its own element.
Do not put pipes, redirects or a whole command line in one string.

## The two merge steps

Source assembly and image selection serve different purposes:

1. **Series overrides:** the assembler merges a selection's `overrides` into its
   shared PHP profile. Objects merge recursively; arrays and scalar values
   replace the original value. This is the place to replace a whole package
   list for one Joomla series.
2. **Image selection:** the renderer starts with the assembled PHP profile,
   applies `dev` for a development context, then applies the selected variant.
   Objects merge recursively, arrays append with duplicates removed, and scalar
   values replace earlier values. For `config`, each file's complete line array
   is replaced rather than appended.

An empty development package list does not remove packages inherited from the
normal image. Remove a package in its shared source list, or replace the list in
a series override. Variant settings are applied last; review their effect when
changing settings also present in `dev`.

## Direct downloads and hashes

Every entry under `download` has a simple lowercase name and these fields:

| Field | Meaning |
| --- | --- |
| `version` | Pinned tool version |
| `package` | Explicit HTTPS artifact URL |
| `type` | `binary` or `tar.gz` |
| `destination` | Absolute installation file path for a binary, or directory for an archive |
| `checksum` | Optional HTTPS URL for a publisher's SHA256 file |
| `temporary` | True removes the destination after installation work in the same image layer |
| `links` | Optional object mapping absolute symlink destinations to their targets |
| `sha256` | Generated by `versions.sh`; present only in resolved configuration |

A `binary` is downloaded to its destination and made executable. A `tar.gz` is
extracted into its destination with one leading archive directory removed.
Choose an archive with that structure; other layouts need an intentional
implementation change. Installed links are not removed automatically when a
temporary destination is removed, so keep links for retained tools only.

Literal `{version}` in a tool's `package` or `checksum` URL expands to that
entry's version. A Joomla state's package URL also accepts `{packageType}`.
For example, the PIE source URL is
`https://github.com/php/pie/releases/download/{version}/pie.phar`.
Only these fixed substitutions are supported. They do not evaluate shell code,
variables or expressions, and unresolved placeholders are rejected before
network requests.

The resolver records SHA256 for tool downloads and SHA512 for Joomla archives.
The generated Dockerfile validates these hashes before using the downloaded
files. When available, the resolver additionally verifies an official Joomla
release asset's published SHA256; a tool's configured publisher checksum URL is
also verified. A computed hash pins the fetched bytes; it is not by itself a
publisher signature. See [maintenance](maintenance.md) for cache and force-refresh
behaviour.

APT, APK, PIE, PECL and npm package installations do not get duplicate source
URLs or artifact hashes in this JSON. Their installation pipelines manage their
own downloads. `download.pie` is the temporary PIE installer itself, while
`pie` lists the extensions it installs. The PIE download must be a temporary
binary whenever PIE extensions are selected.

## Extension enablement and checks

Bundled extensions use Docker's configure, install and enable helpers. PIE
installs each exact configured `package:version` noninteractively and uses the
Docker PHP enablement helper. PECL is an explicit alternative for a package;
list its compiled module in `extensions.enable`. Do not configure the same
extension through both installers. There is no silent automatic fallback after
a failed PIE installation.

Add external modules to `extensions.check`, using the name PHP reports, which
can differ from the package name or module filename. `Zend OPcache` is one such
runtime name. Every module in `extensions.install` is already checked. After
cleanup and configuration, the generated build checks PHP startup diagnostics
and runs `php --ri` for the required modules, followed by the configured
`checks` commands. These checks establish that the final runtime can load its
extensions; they do not compare package header strings to pins.

## Cleanup and configuration boundaries

Keep retained packages and temporary build dependencies separate. Debian saves
the requested package set and retains the package owners of extension shared
libraries before removing build-only dependencies. Alpine records the required
shared libraries before deleting its temporary build group. Both paths remove
installer workspaces and caches in the installation layer.

Archive extraction has its own cleanup. `conf/archives.json` maps each supported
format to `apt` and `apk` arrays of temporary extraction packages. Those packages
and the downloaded Joomla archive are removed in the extraction layer.

Configuration lines are emitted literally. PHP environment references such as
`${JOOMLA_XDEBUG_CLIENT_HOST}` survive generation and are interpreted inside the
container. `${DEB_BUILD_MULTIARCH}` is the one supported build-time substitution
in bundled extension configure arguments; it expands inside the Debian image,
not on the generation host.

The Dockerfile has three installation/configuration layers: PHP extensions and
tools with cleanup; runtime configuration and checks; then Joomla extraction
with cleanup. Joomla release metadata is emitted after the first two layers,
allowing a release-only change to reuse their cache. See the
[build walkthrough](generation.md) for the corresponding script flow.
