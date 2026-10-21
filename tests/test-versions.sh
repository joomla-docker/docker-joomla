#!/usr/bin/env bash
# shellcheck disable=SC2016 # The edit_helper arguments contain jq variables.
set -Eeuo pipefail
test_case="version resolver test setup"
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/src/build/lib" "$work/repo/conf" "$work/bin"
cp "$root/src/build/versions.sh" "$work/repo/src/build/"
cp -r "$root/src/build/lib/." "$work/repo/src/build/lib/"
fixture() {
    jq --arg fixture "$1" \
        -f "$root/tests/fixtures.jq" "${TEST_VERSIONS_FILE:-$root/conf/versions.json}"
}
helper_settings() {
    jq 'walk(if type == "object" then del(.sha256, .sha512) else . end)'
}
split_helper() {
    local php series
    cat >"$work/helper-source.json"
    mkdir -p conf/php conf/joomla
    jq 'to_entries[0].value.archives' "$work/helper-source.json" >conf/archives.json
    while IFS= read -r php; do
        # A shared profile retains its optional dev additions; each series opts in.
        jq --arg php "$php" '[.[] | .phpVersions[$php] | select(. != null)] | sort_by(.dev != null) | last' \
            "$work/helper-source.json" >"conf/php/$php.json"
    done < <(jq -r '[.[] | .phpVersions | keys[]] | unique[]' "$work/helper-source.json")
    while IFS= read -r series; do
        jq --arg series "$series" '
            .[$series] | del(.archives)
            | .phpVersions |= with_entries(.value = {development: (.value.dev != null)})
        ' "$work/helper-source.json" >"conf/joomla/$series.json"
    done < <(jq -r 'keys[]' "$work/helper-source.json")
    cat >conf/versions-helper.json <<'JSON'
{
  "archives": "archives.json",
  "phpVersions": "php",
  "joomlaVersions": "joomla"
}
JSON
}
edit_profiles() {
    local profile
    for profile in "conf/$(jq -r '.phpVersions' conf/versions-helper.json)"/*.json; do
        jq "$1" "$profile" >"$work/helper"
        mv "$work/helper" "$profile"
    done
}
printf 'verified Joomla fixture\n' > "$work/payload"
export FIXTURE_PAYLOAD="$work/payload" FIXTURE_CALLS="$work/calls"
FIXTURE_SHA256="$(sha256sum "$work/payload" | cut -d ' ' -f1)"
FIXTURE_SHA512="$(sha512sum "$work/payload" | cut -d ' ' -f1)"
export FIXTURE_SHA256 FIXTURE_SHA512
: > "$FIXTURE_CALLS"
cat > "$work/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
url= destination=
while (($#)); do
    case "$1" in
        -o) destination="$2"; shift 2 ;;
        -H|--retry|--retry-max-time|--connect-timeout|--max-time|--proto|--proto-redir) shift 2 ;;
        --*) shift ;;
        https://*) url="$1"; shift ;;
        *) echo "Unexpected curl argument: $1" >&2; exit 1 ;;
    esac
done
printf '%s\n' "$url" >> "$FIXTURE_CALLS"
[[ "${FIXTURE_FAILURE:-}" != http ]] || exit 22
[[ "${FIXTURE_FAILURE:-}" != connection ]] || exit 7
if [[ "${FIXTURE_FAILURE:-}" == pie && "$url" == https://github.com/php/pie/* ]]; then exit 22; fi
if [[ "${FIXTURE_FAILURE:-}" == tool && "$url" != https://*github.com/* ]]; then exit 22; fi
if [[ "$url" == https://api.github.com/* ]]; then
    version="${url##*/}"
    case "$version" in
        *-alpha*) label=Alpha ;; *-beta*) label=Beta ;; *-rc*) label=Release_Candidate ;; *) label=Stable ;;
    esac
    asset="Joomla_${version}-${label}-Full_Package.tar.zst"
    jq -n --arg version "$version" --arg asset "$asset" --arg digest "sha256:$FIXTURE_SHA256" \
       --arg failure "${FIXTURE_FAILURE:-}" '{tag_name:$version, draft:false,
         assets:[{name:$asset,browser_download_url:("https://github.com/joomla/joomla-cms/releases/download/"+$version+"/"+$asset),digest:$digest}]
       } | if $failure == "missing" then .assets=[]
           elif $failure == "duplicate" then .assets += .assets
           elif $failure == "digest" then .assets[0].digest="invalid"
           elif $failure == "no-digest" then .assets[0].digest=null else . end' > "$destination"
elif [[ "$url" == https://getcomposer.org/*/composer.phar.sha256sum ]]; then
    case "${FIXTURE_FAILURE:-}" in
        composer-digest) printf 'invalid\n' > "$destination" ;;
        composer-checksum) printf '%064d  composer.phar\n' 0 > "$destination" ;;
        *) printf '%s  composer.phar\n' "$FIXTURE_SHA256" > "$destination" ;;
    esac
elif [[ "${FIXTURE_FAILURE:-}" == checksum ]]; then printf 'tampered\n' > "$destination"
else cp "$FIXTURE_PAYLOAD" "$destination"
fi
MOCK
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
unset VERSIONS_HELPER
cd "$work/repo"

test_case="reuse resolved hashes without downloads"
fixture current | jq --arg mode resolved -S -f src/build/lib/validate-config.jq > conf/versions.json
helper_settings < conf/versions.json | split_helper
cp conf/versions.json "$work/baseline.json"
(cd /; "$work/repo/src/build/versions.sh")
cmp conf/versions.json "$work/baseline.json"
[[ ! -s "$FIXTURE_CALLS" ]]

test_case="resolve every configured artifact and reuse URL-keyed checksums"
./src/build/versions.sh --force
jq -e --arg sha "$FIXTURE_SHA256" --arg sha512 "$FIXTURE_SHA512" '
  all(.[]; all(.states[]; .sha512 == $sha512))
  and all(.. | objects | select(has("destination")); .sha256 == $sha)
' conf/versions.json >/dev/null
before="$(wc -l < "$FIXTURE_CALLS")"
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$before" ]]

test_case="forcing a later series refreshes a shared artifact exactly once"
shared="$(jq -ce '
    [to_entries[] | .key as $series | .value.phpVersions[]
        | {series: $series, package: .download.pie.package}]
    | group_by(.package)
    | map({package: .[0].package, series: (map(.series) | unique | sort)})
    | map(select(.package != null and (.series | length) > 1)) | first
' conf/versions.json)"
shared_package="$(jq -r '.package' <<<"$shared")"
selected_series="$(jq -r '.series[-1]' <<<"$shared")"
cp conf/versions.json "$work/before-targeted.json"
./src/build/versions.sh --force "$selected_series"
tail -n "+$((before + 1))" "$FIXTURE_CALLS" >"$work/targeted-requests"
[[ "$(grep -Fxc -- "$shared_package" "$work/targeted-requests")" == 1 ]]
jq --arg series "$selected_series" 'del(.[$series]) | map_values(.states)' \
    "$work/before-targeted.json" >"$work/unselected-before.json"
jq --arg series "$selected_series" 'del(.[$series]) | map_values(.states)' \
    conf/versions.json >"$work/unselected-after.json"
cmp "$work/unselected-before.json" "$work/unselected-after.json"
while IFS= read -r url; do
    if grep -Fxq -- "$url" "$work/targeted-requests"; then
        echo "FAIL: targeted force fetched an unselected Joomla release: $url" >&2; exit 1
    fi
done < <(jq -r --arg series "$selected_series" '
    del(.[$series]) | .[].states[]
    | .package, ("https://api.github.com/repos/joomla/joomla-cms/releases/tags/" + .version)
' "$work/before-targeted.json")

test_case="shared artifact failure during targeted force preserves conf/versions.json"
cp conf/versions.json "$work/baseline.json"
if env FIXTURE_FAILURE=pie ./src/build/versions.sh --force "$selected_series" >"$work/error" 2>&1; then
    echo 'FAIL: targeted force accepted a failed shared PIE download' >&2; exit 1
fi
cmp conf/versions.json "$work/baseline.json"
before="$(wc -l < "$FIXTURE_CALLS")"

test_case="settings changes require no downloads"
cp -r conf/php conf/alternate-php
for profile in conf/alternate-php/*.json; do
    jq '.environment.TEST_SETTING = "configured"' "$profile" >"$work/helper"
    mv "$work/helper" "$profile"
done
jq '.phpVersions = "alternate-php"' conf/versions-helper.json > conf/.versions-helper.json
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$before" ]]
jq -e 'all(.[]; all(.phpVersions[]; .environment.TEST_SETTING == "configured"))' conf/versions.json >/dev/null
mv conf/.versions-helper.json conf/versions-helper.json

test_case="explicit helper override accepts a split-source index"
cp conf/versions-helper.json conf/custom-index.json
VERSIONS_HELPER=conf/custom-index.json ./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$before" ]]

test_case="installer version changes do not resolve source downloads"
edit_profiles 'walk(if type == "object" then
    (if has("pie") and (.pie | type == "object") and (.pie | has("type") | not) then .pie |= map_values("100.0.0") else . end)
    | (if has("npm") and (.npm | type == "object") then .npm |= map_values("100.0.0") else . end)
  else . end)'
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$before" ]]

test_case="new arbitrary download needs no resolver code"
series="$(jq -r 'keys[0]' conf/versions.json)"
series_source="conf/$(jq -r '.joomlaVersions' conf/versions-helper.json)/$series.json"
state="$(jq -r '.states | keys[0]' "$series_source")"
php="$(jq -r --arg state "$state" '.states[$state].php' "$series_source")"
profile_source="conf/$(jq -r '.phpVersions' conf/versions-helper.json)/$php.json"
jq '
 .download.example = {
   version:"100.0.0", package:"https://example.test/tool.phar", type:"binary", destination:"/usr/local/bin/example"}
' "$profile_source" > "$work/helper"
mv "$work/helper" "$profile_source"
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$((before + 1))" ]]

# A source change, even with the same version, must never reuse an old digest.
test_case="changed URL refreshes its checksum"
jq '.download.example.package = "https://example.test/replacement.phar"' "$profile_source" > "$work/helper"
mv "$work/helper" "$profile_source"
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$((before + 2))" ]]

test_case="tool version alone updates its package and publisher-checksum URLs"
jq '.download.example |= . + {
    version: "100.0.0",
    package: "https://getcomposer.org/download/{version}/composer.phar",
    checksum: "https://getcomposer.org/download/{version}/composer.phar.sha256sum"
}' "$profile_source" >"$work/helper"
mv "$work/helper" "$profile_source"
./src/build/versions.sh
before="$(wc -l < "$FIXTURE_CALLS")"
jq '.download.example.version = "100.0.1"' "$profile_source" >"$work/helper"
mv "$work/helper" "$profile_source"
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$((before + 2))" ]]
tail -n 2 "$FIXTURE_CALLS" >"$work/tool-requests"
printf '%s\n' \
    'https://getcomposer.org/download/100.0.1/composer.phar' \
    'https://getcomposer.org/download/100.0.1/composer.phar.sha256sum' | cmp - "$work/tool-requests"
jq -e --arg php "$php" --arg sha "$FIXTURE_SHA256" '
    [.[] | .phpVersions[$php].download.example? | select(. != null)]
    | length > 0 and all(.[];
        .version == "100.0.1" and .sha256 == $sha
        and .package == "https://getcomposer.org/download/100.0.1/composer.phar"
        and .checksum == "https://getcomposer.org/download/100.0.1/composer.phar.sha256sum")
' conf/versions.json >/dev/null

test_case="Joomla version alone updates its package URL"
case "$state" in
    stable) label=Stable; suffix= ;;
    alpha) label=Alpha; suffix=-alpha1 ;;
    beta) label=Beta; suffix=-beta1 ;;
    rc) label=Release_Candidate; suffix=-rc1 ;;
esac
package="https://github.com/joomla/joomla-cms/releases/download/{version}/Joomla_{version}-${label}-Full_Package.{packageType}"
jq --arg state "$state" --arg package "$package" '.states[$state].package = $package' "$series_source" >"$work/helper"
mv "$work/helper" "$series_source"
before="$(wc -l < "$FIXTURE_CALLS")"
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$before" ]]
new_version="$series.999$suffix"
jq --arg state "$state" --arg version "$new_version" '.states[$state].version = $version' "$series_source" >"$work/helper"
mv "$work/helper" "$series_source"
./src/build/versions.sh
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$((before + 2))" ]]
package_type="$(jq -r --arg state "$state" '.states[$state].packageType // .packageType' "$series_source")"
tail -n 2 "$FIXTURE_CALLS" >"$work/joomla-requests"
printf '%s\n' \
    "https://api.github.com/repos/joomla/joomla-cms/releases/tags/$new_version" \
    "https://github.com/joomla/joomla-cms/releases/download/$new_version/Joomla_${new_version}-${label}-Full_Package.$package_type" \
    | cmp - "$work/joomla-requests"
jq -e --arg series "$series" --arg state "$state" --arg version "$new_version" --arg sha "$FIXTURE_SHA512" '
    .[$series].states[$state]
    | .version == $version and .sha512 == $sha
      and (.package | contains($version))
      and (.package | contains("{version}") or contains("{packageType}") | not)
' conf/versions.json >/dev/null

test_case="unknown URL placeholders fail before downloads or metadata changes"
cp "$profile_source" "$work/profile-before.json"
cp conf/versions.json "$work/baseline.json"
before="$(wc -l < "$FIXTURE_CALLS")"
jq '.download.example.package = "https://example.test/{unsupported}/tool.phar"' "$profile_source" >"$work/helper"
mv "$work/helper" "$profile_source"
if ./src/build/versions.sh >"$work/error" 2>&1; then echo 'FAIL: unknown URL placeholder accepted' >&2; exit 1; fi
[[ "$(wc -l < "$FIXTURE_CALLS")" == "$before" ]]
cmp conf/versions.json "$work/baseline.json"
mv "$work/profile-before.json" "$profile_source"

for failure in http connection missing duplicate digest checksum tool pie composer-digest composer-checksum; do
    test_case="failed $failure resolution leaves existing conf/versions.json untouched"
    cp conf/versions.json "$work/baseline.json"
    if env FIXTURE_FAILURE="$failure" ./src/build/versions.sh --force >"$work/error" 2>&1; then
        echo "FAIL: accepted $failure" >&2; exit 1
    fi
    cmp conf/versions.json "$work/baseline.json"
done

test_case="missing published Joomla digest still computes SHA512"
env FIXTURE_FAILURE=no-digest ./src/build/versions.sh --force >/dev/null
jq -e --arg sha "$FIXTURE_SHA512" 'all(.[]; all(.states[]; .sha512 == $sha))' conf/versions.json >/dev/null
jq -se '[.[] | .. | objects | keys[] | select(. == "sha256" or . == "sha512")] | length == 0' \
    conf/versions-helper.json conf/archives.json conf/php/*.json \
    conf/alternate-php/*.json conf/joomla/*.json >/dev/null
if ./src/build/versions.sh unknown/state >"$work/error" 2>&1; then echo 'FAIL: unknown selector accepted' >&2; exit 1; fi
echo 'Version resolution tests passed.'
