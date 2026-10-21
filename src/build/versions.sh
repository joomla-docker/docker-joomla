#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.."

usage() {
    echo 'Usage: ./src/build/versions.sh [--force] [SERIES | SERIES/STATE ...]'
}
force=false
targets=()
for argument; do
    case "$argument" in
        -f|--force) force=true ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $argument" >&2; exit 1 ;;
        *) targets+=("${argument%/}") ;;
    esac
done

helper="${VERSIONS_HELPER:-}"
if [ -z "$helper" ]; then
    helper=conf/versions-helper.json
    [ ! -f conf/.versions-helper.json ] || helper=conf/.versions-helper.json
fi
work="$(mktemp -d conf/.versions.XXXXXXXX)"
trap 'rm -rf "$work"' EXIT
bash src/build/lib/assemble-config.sh "$helper" > "$work/assembled.json"
jq --arg mode helper -f src/build/lib/validate-config.jq "$work/assembled.json" > "$work/validated.json"
# Substitute only documented literal URL fields; no expressions or templates
# are evaluated. Cache identities and the final snapshot always use full URLs.
jq '
    def url($version; $type):
        split("{version}") | join($version)
        | if $type != null then split("{packageType}") | join($type) else . end
        | if test("[{}]") then error("unsupported URL placeholder: " + .) else . end;
    with_entries(.value.states |= map_values(
        . as $release | if .package != null then .package |= url($release.version; $release.packageType) else . end))
    | reduce (paths(objects) | select(.[-2] == "download")) as $path (.;
        getpath($path) as $item
        | setpath($path + ["package"]; $item.package | url($item.version; null))
        | if $item.checksum != null then
            setpath($path + ["checksum"]; $item.checksum | url($item.version; null))
          else . end)
' "$work/validated.json" > "$work/helper.json"
# Check every expanded tag before making network requests or replacing metadata.
jq -f src/build/lib/tags.jq "$work/helper.json" > /dev/null

mapfile -t releases < <(jq -r 'to_entries[] | .key as $series | .value.states | keys[] | "\($series)/\(.)"' "$work/helper.json")
for target in "${targets[@]}"; do
    jq -e --arg target "$target" '
        ($target | split("/")) as $parts |
        if ($parts | length) == 1 then has($parts[0])
        elif ($parts | length) == 2 then .[$parts[0]].states | has($parts[1])
        else false end
    ' "$work/helper.json" > /dev/null || { echo "Unknown release target: $target" >&2; exit 1; }
done

selected() {
    local release="$1" target
    [ "${#targets[@]}" -gt 0 ] || return 0
    for target in "${targets[@]}"; do
        # Accept either a complete track or a series shared by selected tracks.
        if [ "$target" = "$release" ] || [ "$target" = "${release%%/*}" ] || [ "${target%%/*}" = "$release" ]; then return 0; fi
    done
    return 1
}

# Existing resolved releases provide a cache keyed by version and package URL.
if [ -f conf/versions.json ]; then jq -e 'type == "object"' conf/versions.json > /dev/null; fi
cp "$work/helper.json" "$work/result.json"
fetch() {
    curl --fail --show-error --silent --location --retry 3 --retry-all-errors --retry-max-time 300 \
        --connect-timeout 15 --max-time 300 --proto '=https' --proto-redir '=https' "$@"
}

for release in "${releases[@]}"; do
    series="${release%%/*}"
    state="${release#*/}"
    metadata="$(jq -c --arg series "$series" --arg state "$state" '.[$series].states[$state]' "$work/helper.json")"
    version="$(jq -r '.version' <<< "$metadata")"
    packageType="$(jq -r '.packageType' <<< "$metadata")"
    case "$state" in
        stable) label=Stable ;;
        alpha) label=Alpha ;;
        beta) label=Beta ;;
        rc) label=Release_Candidate ;;
    esac
    asset="Joomla_${version}-${label}-Full_Package.${packageType}"
    officialPackage="https://github.com/joomla/joomla-cms/releases/download/$version/$asset"
    package="$(jq -r --arg default "$officialPackage" '.package // $default' <<< "$metadata")"
    cached='{}'
    if [ -f conf/versions.json ]; then
        cached="$(jq -c --arg series "$series" --arg state "$state" '
            .[$series].states[$state] // {}
        ' conf/versions.json)"
    fi
    validCache=false
    if jq -e --arg version "$version" --arg package "$package" --arg type "$packageType" '
        .version == $version and .package == $package and .packageType == $type
        and (.sha512 | type == "string" and test("^[a-fA-F0-9]{128}$"))
    ' <<< "$cached" > /dev/null; then validCache=true; fi

    if $validCache && { ! $force || ! selected "$release"; }; then
        sha512="$(jq -r '.sha512 | ascii_downcase' <<< "$cached")"
        echo "Using resolved Joomla $version ($release)" >&2
    else
        if ! selected "$release"; then
            echo "Unresolved or changed release $release; include it or run ./generate.sh without selectors." >&2
            exit 1
        fi
        echo "Resolving Joomla $version ($release)" >&2
        digest=
        if [ "$package" = "$officialPackage" ]; then
            # Resolve an exact published full-package asset. GitHub's prerelease
            # flag alone is not a reliable indication of Joomla's release state.
            headers=(-H 'Accept: application/vnd.github+json')
            token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
            if [ -n "$token" ]; then headers+=(-H "Authorization: Bearer $token"); fi
            fetch "${headers[@]}" "https://api.github.com/repos/joomla/joomla-cms/releases/tags/$version" -o "$work/release.json"
            digest="$(jq -r --arg version "$version" --arg asset "$asset" --arg package "$package" '
                if .tag_name != $version or .draft != false then error("unexpected or draft release") else . end |
                [.assets[] | select(.name == $asset and .browser_download_url == $package)] |
                if length != 1 then error("expected exactly one matching full-package asset") else .[0].digest end |
                if . == null then ""
                elif type == "string" and test("^sha256:[a-fA-F0-9]{64}$") then ltrimstr("sha256:")
                else error("invalid published SHA256") end
            ' "$work/release.json")"
        fi
        fetch "$package" -o "$work/package"
        if [ -n "$digest" ]; then
            printf '%s  %s\n' "$digest" "$work/package" | sha256sum --check --status
        fi
        sha512="$(sha512sum "$work/package")"
        sha512="${sha512%% *}"
        rm -f "$work/package"
    fi
    jq --arg series "$series" --arg state "$state" --arg package "$package" --arg sha512 "$sha512" '
        .[$series].states[$state] += {package: $package, sha512: $sha512}
    ' "$work/result.json" > "$work/next.json"
    mv "$work/next.json" "$work/result.json"
done

# Resolve every configured artifact generically. The helper owns URLs and install
# metadata; only the resulting file receives checksums. URL is the cache identity.
declare -A artifactHashes=()
while IFS=$'\t' read -r series path package checksumUrl; do
    key="$package"
    if [[ ! -v "artifactHashes[$key]" ]]; then
        # A shared download belongs to every series referencing its URL. Decide
        # selection before caching it, so source-file order cannot skip --force.
        artifactSelected=false
        while IFS= read -r artifactSeries; do
            if selected "$artifactSeries"; then artifactSelected=true; break; fi
        done < <(jq -r --arg package "$package" '
            paths(objects) as $path | select($path[-2] == "download")
            | select(getpath($path).package == $package) | $path[0]
        ' "$work/helper.json")
        cached=
        if [[ -f conf/versions.json ]]; then
            cached="$(jq -r --arg package "$package" '[.. | objects | select(.package? == $package) | .sha256? | select(type == "string" and test("^[a-fA-F0-9]{64}$"))][0] // ""' conf/versions.json)"
        fi
        if [[ -n "$cached" ]] && { ! $force || ! $artifactSelected; }; then
            artifactHashes[$key]="${cached,,}"
        else
            if ! $artifactSelected; then
                echo "Unresolved artifact $package for $series; include it or update all series." >&2
                exit 1
            fi
            echo "Resolving $package ($series)" >&2
            fetch "$package" -o "$work/artifact"
            checksum="$(sha256sum "$work/artifact")"
            artifactHashes[$key]="${checksum%% *}"
            if [[ "$checksumUrl" != - ]]; then
                fetch "$checksumUrl" -o "$work/published.sha256"
                read -r expected _ < "$work/published.sha256" || true
                [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { echo 'Invalid published SHA256' >&2; exit 1; }
                printf '%s  %s\n' "$expected" "$work/artifact" | sha256sum --check --status
            fi
        fi
    fi
    jq --argjson path "$path" --arg sha256 "${artifactHashes[$key]}" 'setpath($path + ["sha256"]; $sha256)' "$work/result.json" > "$work/next.json"
    mv "$work/next.json" "$work/result.json"
done < <(jq -r 'paths(objects) as $path | select($path[-2] == "download") | getpath($path) | [$path[0], ($path | tojson), .package, (.checksum // "-")] | @tsv' "$work/helper.json")

jq --arg mode resolved -S -f src/build/lib/validate-config.jq "$work/result.json" > "$work/versions.json"
mv "$work/versions.json" conf/versions.json
