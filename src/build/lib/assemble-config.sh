#!/usr/bin/env bash
# Assemble human-maintained JSON files without resolving or downloading artifacts.
set -Eeuo pipefail
export LC_ALL=C
if (( $# != 1 )); then
    echo 'Usage: bash src/build/lib/assemble-config.sh INDEX.json' >&2
    exit 1
fi
index="$(readlink -f "$1")"
directory="$(dirname "$index")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

read_object() {
    jq -es '
        if length != 1 or (.[0] | type) != "object" then
            error("expected one JSON object")
        elif any(.[0] | .. | objects; has("sha256") or has("sha512")) then
            error("checksums belong in conf/versions.json")
        else .[0] end
    ' "$1"
}
read_object "$index" > "$work/index.json"
jq -e '
    (keys == ["archives", "joomlaVersions", "phpVersions"])
    and all(.[]; type == "string" and length > 0 and (test("[\r\n]") | not))
' "$work/index.json" > /dev/null || {
    echo 'Index requires archives, phpVersions and joomlaVersions paths.' >&2
    exit 1
}
source_path() {
    local path
    path="$(jq -r --arg key "$1" '.[$key]' "$work/index.json")"
    if [[ $path != /* ]]; then path="$directory/$path"; fi
    printf '%s\n' "$path"
}
read_object "$(source_path archives)" > "$work/archives.json"

shopt -s nullglob
for group in phpVersions joomlaVersions; do
    source_directory="$(source_path "$group")"
    files=("$source_directory/"*.json)
    if (( ${#files[@]} == 0 )); then
        echo "No JSON profiles found in $source_directory" >&2
        exit 1
    fi
    : > "$work/$group.ndjson"
    for file in "${files[@]}"; do
        name="${file##*/}"
        name="${name%.json}"
        if [[ ! $name =~ ^[0-9]+\.[0-9]+$ ]]; then
            echo "Invalid version filename: $file" >&2
            exit 1
        fi
        read_object "$file" > "$work/profile.json"
        jq -n --arg name "$name" --slurpfile profile "$work/profile.json" \
            '{($name): $profile[0]}' >> "$work/$group.ndjson"
    done
    jq -s 'add' "$work/$group.ndjson" > "$work/$group.json"
done

# Source overrides replace arrays; the renderer separately composes normal,
# development and variant settings using its existing additive package lists.
jq -en --slurpfile archives "$work/archives.json" \
    --slurpfile profiles "$work/phpVersions.json" --slurpfile series "$work/joomlaVersions.json" '
    def require($condition; $message):
        if $condition then . else error($message) end;
    def merge($other):
        reduce ($other | to_entries[]) as $entry (.;
            $entry.key as $key | $entry.value as $value
            | .[$key] = (if (.[$key] | type) == "object" and ($value | type) == "object"
                then .[$key] | merge($value) else $value end));
    $series[0] | with_entries(
        .key as $seriesName
        | .value |= (
            require(has("archives") | not; "\($seriesName): archives are configured in the index")
            | require(.phpVersions | type == "object" and length > 0;
                "\($seriesName): select at least one PHP profile")
            | .phpVersions |= with_entries(
                .key as $php | .value as $selection
                | require($profiles[0] | has($php); "\($seriesName): missing PHP profile \($php)")
                | require($selection | type == "object"; "\($seriesName)/\($php): invalid PHP selection")
                | require($selection | keys - ["development", "overrides"] | length == 0;
                    "\($seriesName)/\($php): unknown PHP selection setting")
                | require(($selection | has("development") | not) or ($selection.development | type) == "boolean";
                    "\($seriesName)/\($php): development must be a boolean")
                | require(($selection | has("overrides") | not) or ($selection.overrides | type) == "object";
                    "\($seriesName)/\($php): overrides must be an object")
                | .value = ($profiles[0][$php] | merge($selection.overrides // {})
                    | if $selection.development == true then
                        require(.dev | type == "object"; "\($seriesName)/\($php): development profile is missing")
                      else del(.dev) end)
              )
            | .archives = $archives[0]
          )
      )
'
