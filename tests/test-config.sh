#!/usr/bin/env bash
set -Eeuo pipefail
test_case="configuration test setup"
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

test_case="maintained helper and resolved snapshot are valid"
# Validate the maintained helper and the current resolved snapshot independently.
bash "$repo/src/build/lib/assemble-config.sh" "$repo/conf/versions-helper.json" \
    | jq --arg mode helper -f "$repo/src/build/lib/validate-config.jq" >/dev/null
jq --arg fixture current \
    -f "$repo/tests/fixtures.jq" "${TEST_VERSIONS_FILE:-$repo/conf/versions.json}" \
    | jq --arg mode resolved -f "$repo/src/build/lib/validate-config.jq" >/dev/null

# Malformed input cases use one isolated fake series, never a maintained release.
jq --arg fixture synthetic \
    -f "$repo/tests/fixtures.jq" "${TEST_VERSIONS_FILE:-$repo/conf/versions.json}" \
    | jq '.["100.0"]' > "$work/settings.json"
check() {
    jq '{"100.0": .}' "$1" | jq --arg mode "${2:-resolved}" -f "$repo/src/build/lib/validate-config.jq" >/dev/null
}
# Humans provide settings and versions, including custom package URLs. Hashes
# are generated into the resolved snapshot and must never be required here.
jq 'walk(if type == "object" then del(.sha256, .sha512) else . end)' \
    "$work/settings.json" > "$work/helper.json"
test_case="helper accepts versions and settings without checksums"
check "$work/helper.json" helper
if check "$work/settings.json" helper >"$work/log" 2>&1; then
    echo 'FAIL: helper accepted generated checksums' >&2; exit 1
fi
reject() {
    test_case="reject invalid configuration: $1"
    jq "$1" "$work/settings.json" > "$work/invalid.json"
    if check "$work/invalid.json" >"$work/log" 2>&1; then
        echo "FAIL: accepted invalid configuration: $1" >&2; exit 1
    fi
}
reject '.states.stable.version = "101.0.0"'
reject '.states.stable.version += "-rc1"'
reject '.states.nightly = .states.stable'
for aliases in '""' 'false' '[true]' '[""]'; do
    reject ".states.stable.aliases = $aliases"
done
reject 'del(.states.stable.sha512)'
reject '.states.stable.sha512 = "invalid"'
reject '.php = .states.stable.php'
reject '.states.stable.php = "missing"'
reject '.states.stable.php = false'
reject 'del(.states.stable.php)'
reject '.variants = ["apache-dev"]'
reject '.variants += [.variants[0]]'
reject '.variant = "missing"'
reject '.variant = [.variant]'
reject '.packageType = .states.stable.packageType'
reject '.states.stable.packageType = "zip"'
reject '.states.stable.packageType = false'
reject 'del(.states.stable.packageType)'
reject 'del(.archives)'
reject '.archives.zip = {apt: [], apk: []}'
reject '.archives[.states.stable.packageType].apt = ["zstd; command"]'
reject '.archives[.states.stable.packageType].apt = ["zstd\n"]'
reject 'del(.archives[.states.stable.packageType].apk)'
reject 'del(.archives[.states.stable.packageType])'
reject '.states.stable.packageType = "tar.gz" | del(.archives["tar.gz"])'
reject '.phpVersions[.states.stable.php].pie["phpredis/phpredis"] = "latest"'
reject '.phpVersions[.states.stable.php].download.pie.sha256 = "invalid"'
reject '.phpVersions[.states.stable.php].download.pie.version = "latest"'
reject '.phpVersions[.states.stable.php].download["bad-name"] = .phpVersions[.states.stable.php].download.pie'
reject '.phpVersions[.states.stable.php].download.PIE = .phpVersions[.states.stable.php].download.pie'
reject '.phpVersions[.states.stable.php].download["pie\n"] = .phpVersions[.states.stable.php].download.pie'
reject '.phpVersions[.states.stable.php].download.joomla = .phpVersions[.states.stable.php].download.pie'
reject 'del(.phpVersions[.states.stable.php].download.pie.package)'
reject '.phpVersions[.states.stable.php].download.pie.package = "http://example.test/pie.phar"'
reject '.phpVersions[.states.stable.php].sources = {}'
reject '.phpVersions[.states.stable.php].npm.npm = "latest"'
reject '.phpVersions[.states.stable.php].pecl = .phpVersions[.states.stable.php].pie'
reject '.phpVersions[.states.stable.php].apt = ["package;command"]'
reject '.phpVersions[.states.stable.php].extensions.check = ["imagick;command"]'
reject '.phpVersions[.states.stable.php].extensions.check = ["imagick\nxdebug"]'
reject '.phpVersions[.states.stable.php].extensions.check = ["imagick\n"]'
reject '.phpVersions[.states.stable.php].checks = [["php", "--version\ninvalid"]]'
reject '.phpVersions[.states.stable.php].checks = [[]]'
reject '.phpVersions[.states.stable.php].checks = ["php --version"]'
reject '.phpVersions[.states.stable.php].download.pie.destination = "/tmp/../bin/pie"'
reject '.states = {}'
for change in '.states.stable.aliases = []' '.states.stable.aliases = null' 'del(.states.stable.aliases)' 'del(.states.stable)'; do
    test_case="accept optional release setting: $change"
    jq "$change" "$work/settings.json" > "$work/valid.json"
    check "$work/valid.json"
done
test_case="accept PHP module names and literal command arguments"
jq '.phpVersions[.states.stable.php].extensions.check = ["Zend OPcache", "xdebug"]
    | .phpVersions[.states.stable.php].checks = [["php", "-r", "echo \"a quoted argument\";"]]' \
    "$work/settings.json" > "$work/valid.json"
check "$work/valid.json"
test_case="states retain their own default PHP and archive type"
jq '.states.beta.php = (.phpVersions | keys[-1])
    | .states.beta.packageType = "tar.gz"
    | .states.rc.packageType = "tar.bz2"' "$work/settings.json" > "$work/state-settings.json"
check "$work/state-settings.json"
jq '{"100.0": .}' "$work/state-settings.json" \
    | jq --arg mode resolved -f "$repo/src/build/lib/validate-config.jq" \
    | jq -e '.["100.0"] | .states.beta.php == (.phpVersions | keys[-1])
        and .states.beta.packageType == "tar.gz" and .states.rc.packageType == "tar.bz2"
        and .states.stable.packageType == "tar.zst"' >/dev/null
echo 'Configuration validation tests passed.'
