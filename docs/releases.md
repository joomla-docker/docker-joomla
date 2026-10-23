# Joomla release management

Each file in `conf/joomla/` describes one numeric Joomla series. Its `states`
object holds the tracks selected for publication for that series. Add a file to
add a series; add a state to add a track. The assembler discovers the files
automatically.

Use [maintenance](maintenance.md) for the common generation, testing and commit
workflow, and [configuration](configuration.md) for field details.

## Understand a release state

The supported state names and version forms are:

| State key | Version form | Official package label |
| --- | --- | --- |
| `alpha` | Numeric major.minor.patch followed by `-alphaN` | `Alpha` |
| `beta` | Numeric major.minor.patch followed by `-betaN` | `Beta` |
| `rc` | Numeric major.minor.patch followed by `-rcN` | `Release_Candidate` |
| `stable` | Numeric major.minor.patch with no prerelease suffix | `Stable` |

`N` means a positive sequence number. The version string must use the lowercase
suffix shown and must belong to the series identified by the JSON filename.
These forms describe the accepted syntax; the release still has to exist at the
configured package URL.

Every state contains `version`, `aliases`, `php`, `variant`, `packageType` and normally an
explicit `package` URL. The fields `php`, `variant` and `packageType` belong in the state.
They must not be placed at series level.

The state's `php` selects the PHP profile that receives its default aliases.
The state's `variant` selects the corresponding default runtime. All configured
states share the series' `phpVersions` and `variants` build matrix. A different
state default does not exclude the other selected PHP versions from that state.
Check that every active state supports the shared selections.

## Package URL patterns

Use the appropriate explicit URL pattern for the state:

| State | Package URL |
| --- | --- |
| `alpha` | `https://github.com/joomla/joomla-cms/releases/download/{version}/Joomla_{version}-Alpha-Full_Package.{packageType}` |
| `beta` | `https://github.com/joomla/joomla-cms/releases/download/{version}/Joomla_{version}-Beta-Full_Package.{packageType}` |
| `rc` | `https://github.com/joomla/joomla-cms/releases/download/{version}/Joomla_{version}-Release_Candidate-Full_Package.{packageType}` |
| `stable` | `https://github.com/joomla/joomla-cms/releases/download/{version}/Joomla_{version}-Stable-Full_Package.{packageType}` |

`{version}` and `{packageType}` are supported literal substitutions, not text to
replace manually on every bump. The state label is explicit: changing from an
RC state to stable also changes the label in its URL. Confirm that the requested
archive format is actually published for that release.

For an official URL, the resolver checks the exact release tag and full-package
asset. It rejects draft releases and ambiguous/missing assets; it does not infer
the track merely from GitHub's prerelease flag. A custom HTTPS package URL is
also supported, but does not receive that official-release metadata check.
Every resolved Joomla package receives a SHA512 in `conf/versions.json` and is
verified when the image builds.

## Bump an existing release

For an ordinary patch or next prerelease in an existing state, change only its
`version` when the URL already contains the substitutions above. Keep the state,
PHP selection, aliases and archive type unless that release needs them changed.

List the configured tracks:

```bash
jq -r '
  to_entries[] | .key as $series | .value.states | to_entries[]
  | [$series, .key, .value.version] | @tsv
' conf/versions.json
```

The following Bash block prompts for the selected track and new version,
updates its existing source entry, then generates that track. Run it from the
repository root. If generation rejects the new value or download, correct the
source and rerun generation before committing.

```bash
(
    set -e
    read -r -p 'Joomla series: ' series
    read -r -p 'State (alpha, beta, rc or stable): ' state
    read -r -p 'Published Joomla version: ' version
    [[ "$series" =~ ^[0-9]+\.[0-9]+$ ]]
    source_file="conf/joomla/$series.json"
    temporary_file="$(mktemp)"
    trap 'rm -f "$temporary_file"' EXIT
    jq -e --arg state "$state" --arg version "$version" '
        if .states | has($state) then .states[$state].version = $version
        else error("state is not configured") end
    ' "$source_file" > "$temporary_file"
    mv "$temporary_file" "$source_file"
    ./generate.sh "$series/$state"
)
```

The new resolved URL changes the release cache identity, so its download and
checksum are refreshed without `--force`. Other configured states remain at
their existing releases. Review and test the generated contexts as described
in [maintenance](maintenance.md).

## Add alpha, beta or RC to an existing series

Open the series file and add the desired key to `states`. Use an existing state
as a structural reference, then set all of the following deliberately:

1. `version`: the published release with the correct suffix for this state.
2. `aliases`: only the prerelease aliases this track should own.
3. `php`: one of the PHP profiles selected by the series.
4. `variant`: one of the runtime variants selected by the series.
5. `packageType`: a supported format published for this package.
6. `package`: the matching state-label URL from the table above.

A state does not need another source file, a new shell branch, or a CI matrix
entry. `./generate.sh` discovers the added state and produces its normal and
selected development contexts.

Leave stable configured when it should continue to be built and published.
Adding a prerelease never automatically moves `latest` or the stable aliases.
Several prerelease states can coexist when that is intentional; each owns its
own exact version and explicit aliases.

## Add a new Joomla series

Create a new numeric `major.minor.json` under `conf/joomla/`, copying a suitable
existing series file as a starting point. Then review the complete new file:

- Select only PHP profiles supported by this Joomla series. Create any missing
  profile first using [the PHP procedure](maintenance.md#add-a-php-version).
- Set each PHP selection's `development` flag intentionally.
- Select the supported `variants`.
- Replace the copied states with the release tracks to publish. Every state
  version must belong to the new series.
- Set the default `php` and `variant`, package format and matching package URL per state.
- Replace copied aliases. In particular, do not copy ownership of `latest`,
  a major alias or a global prerelease alias without removing that ownership
  from the previous track.

No change to `conf/versions-helper.json` is needed. Run `./generate.sh` without
selectors so new releases and any related alias changes are resolved together.
All active contexts and the tag namespace are validated as one configuration.

## Alias ownership and generated tags

The tag plan always includes the exact version; `aliases` lists only additional
names. An empty aliases array is valid when only exact-version tags are wanted.

Stable aliases normally identify the series or major release, with `latest`
owned by the intended default stable track. Prerelease aliases must preserve
their state: the bare state name is allowed, as are names ending with that
state and an optional numeric sequence suffix. Do not assign `latest` or a
plain stable-looking alias to a prerelease state.

The names `dev` and names already ending in `-dev` are reserved for generated
development aliases. The generator derives development names from normal tags;
`latest` becomes `dev`, and other normal names receive `-dev`.

Fully qualified tags identify the release/alias, PHP version and runtime.
The default PHP/runtime combination also receives the shorter aliases.
`src/build/lib/tags.jq` creates this mapping and rejects duplicate tag ownership
across the entire configuration, even for a selected generation request.

Inspect the actual mapping after generation instead of maintaining a second tag
list in documentation:

```bash
jq -r -f src/build/lib/tags.jq conf/versions.json |
    jq -r '.[] | [.directory, (.tags | join(", "))] | @tsv'
```

The same plan supplies generated context paths, the CI matrix and release
manifest entries. A configured tag is not a statement that the image has already
been published; follow [publishing](publishing.md) to update the distribution.

## Promote a prerelease to stable

Promotion is an explicit configuration change, not a suffix-stripping operation:

1. Add or update `states.stable` with the published stable version.
2. Set its package URL to the `Stable` pattern and verify the archive format.
3. Choose its default `php` and `variant` from the series' selected build matrix.
4. Assign its stable aliases. Transfer `latest` and other shared aliases from
   their previous owner only when the new release should take them over.
5. Keep or remove alpha, beta and RC states according to which tracks should
   remain maintained. Removing them is not required just to create stable.
6. Run `./generate.sh`, review all alias moves and generated contexts, then test
   before committing.

When moving between alpha, beta and RC, use the same explicit approach: add or
update the target state and its URL label, then decide whether the old state
should remain. There is no implicit promotion based on the version number.

## Retire a track or series

Remove the state from its series file when it should no longer be maintained.
If no states remain, remove the series file. A series must have at least one
state to be valid. Check that aliases such as `latest` still have the intended
owner after the change, then run `./generate.sh`.

Generation does not delete old contexts. Review the corresponding directory
under `images/` and explicitly remove it from Git when it is no longer needed.
The repository also retains earlier contexts without a state directory; these
are historical files unless selected by the current context plan. Do not infer
supported releases merely from directories present on disk.

`release.sh` includes only contexts from the current resolved configuration in
its manifest; retained historical directories do not automatically re-enter it.
Removing a manifest entry stops maintaining that tag through this configuration;
it does not request deletion of an already published registry image.

## Finish the release

Commit the source configuration, `conf/versions.json`, generated contexts and
any intentional removals together. After review and successful checks, the
manifest command remains:

```bash
./release.sh > ../official-images/library/joomla
```

The sibling Official Images checkout and publication steps are described in
[publishing](publishing.md). Generate the manifest from committed contexts,
because its `GitCommit` values identify the exact image source being released.
