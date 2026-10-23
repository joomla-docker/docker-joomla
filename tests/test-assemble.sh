#!/usr/bin/env bash
set -Eeuo pipefail
test_case='source assembly fixture setup'
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
assembler="$repo/src/build/lib/assemble-config.sh"
config="$work/config"
mkdir -p "$config/php" "$config/joomla"

cat >"$config/index.json" <<'JSON'
{
  "archives": "archives.json",
  "phpVersions": "php",
  "joomlaVersions": "joomla"
}
JSON
cat >"$config/archives.json" <<'JSON'
{
  "tar.zst": {"apt": ["zstd"], "apk": ["zstd"]},
  "tar.gz": {"apt": [], "apk": []}
}
JSON
cat >"$config/php/8.3.json" <<'JSON'
{
  "download": {
    "example": {
      "version": "1.2.3",
      "package": "https://example.test/tool/{version}/example.phar",
      "checksum": "https://example.test/tool/{version}/example.sha256",
      "type": "binary",
      "destination": "/usr/local/bin/example"
    }
  },
  "apt": ["base-package", "second-package"],
  "apk": ["base-package"],
  "build": {"apt": [], "apk": []},
  "extensions": {"install": []},
  "environment": {"INHERITED": "base", "OVERRIDDEN": "before"},
  "workdir": "/var/www/html",
  "volume": ["/var/www/html"],
  "entrypoint": ["/entrypoint.sh"],
  "variants": {
    "apache": {
      "base": "php:8.3-apache",
      "command": ["apache2-foreground"],
      "environment": {"VARIANT_VALUE": "preserved"}
    }
  },
  "dev": {
    "apt": ["git"],
    "apk": ["git"],
    "config": {"/tmp/development.ini": ["development=1"]}
  }
}
JSON
cat >"$config/joomla/6.2.json" <<'JSON'
{
  "phpVersions": {"8.3": {"development": false}},
  "variants": ["apache"],
  "states": {
    "stable": {
      "version": "6.2.0",
      "php": "8.3",
      "variant": "apache",
      "packageType": "tar.zst",
      "aliases": ["latest"]
    }
  }
}
JSON
cat >"$config/joomla/6.3.json" <<'JSON'
{
  "phpVersions": {
    "8.3": {
      "development": true,
      "overrides": {
        "apt": ["override-package"],
        "environment": {"OVERRIDDEN": "after"},
        "workdir": "/srv/joomla",
        "variants": {"apache": {"command": ["custom-server", "--foreground"]}}
      }
    }
  },
  "variants": ["apache"],
  "states": {
    "stable": {
      "version": "6.3.0",
      "php": "8.3",
      "variant": "apache",
      "packageType": "tar.gz",
      "aliases": []
    }
  }
}
JSON
cp -r "$config" "$work/pristine"

assemble() {
    bash "$assembler" "$config/index.json"
}
restore() {
    cp -r "$work/pristine/." "$config/"
}
reject() {
    test_case="reject source assembly: $1"
    if assemble >"$work/output" 2>"$work/error"; then
        printf 'Invalid source accepted: %s\n' "$1" >&2
        exit 1
    fi
    if [[ -s "$work/output" || ! -s "$work/error" ]]; then
        printf 'Expected a diagnostic and no partial configuration: %s\n' "$1" >&2
        exit 1
    fi
}

test_case='shared profiles, development selection and recursive object overrides'
assemble >"$work/assembled.json"
jq -e '
    keys == ["6.2", "6.3"]
    and (.["6.2"].phpVersions["8.3"] | has("dev") | not)
    and .["6.3"].phpVersions["8.3"].dev.apt == ["git"]
    and .["6.2"].phpVersions["8.3"].apt == ["base-package", "second-package"]
    and .["6.3"].phpVersions["8.3"].apt == ["override-package"]
    and .["6.3"].phpVersions["8.3"].environment == {"INHERITED":"base","OVERRIDDEN":"after"}
    and .["6.3"].phpVersions["8.3"].workdir == "/srv/joomla"
    and .["6.3"].phpVersions["8.3"].variants.apache.base == "php:8.3-apache"
    and .["6.3"].phpVersions["8.3"].variants.apache.command == ["custom-server","--foreground"]
    and .["6.3"].phpVersions["8.3"].variants.apache.environment.VARIANT_VALUE == "preserved"
    and all(.[]; .archives["tar.zst"] == {"apt":["zstd"],"apk":["zstd"]})
    and all(.[]; (has("php") or has("packageType")) | not)
    and .["6.2"].states.stable.php == "8.3"
    and .["6.3"].states.stable.packageType == "tar.gz"
    and all(.[]; .phpVersions["8.3"].download.example.package == "https://example.test/tool/{version}/example.phar")
    and all(.[]; .phpVersions["8.3"].download.example.checksum == "https://example.test/tool/{version}/example.sha256")
    and all(.. | objects; (has("sha256") or has("sha512")) | not)
' "$work/assembled.json" >/dev/null

test_case='index paths resolve relative to the index and assembly is deterministic'
(cd / && bash "$assembler" "$config/index.json") >"$work/from-root.json"
(cd "$work" && bash "$assembler" config/index.json) >"$work/from-relative-index.json"
cmp "$work/assembled.json" "$work/from-root.json"
cmp "$work/assembled.json" "$work/from-relative-index.json"

test_case='one shared profile edit reaches every referencing Joomla series'
jq '.download.example.version = "1.2.4"' "$config/php/8.3.json" >"$work/changed.json"
mv "$work/changed.json" "$config/php/8.3.json"
assemble | jq -e 'all(.[]; .phpVersions["8.3"].download.example.version == "1.2.4")' >/dev/null
restore

test_case='new PHP and Joomla files are discovered without editing the index'
jq '.variants.apache.base = "php:8.4-apache"' "$config/php/8.3.json" >"$config/php/8.4.json"
jq '
    .phpVersions = {"8.4": {"development": false}}
    | .states.stable.version = "6.4.0"
    | .states.stable.php = "8.4"
    | .states.stable.aliases = []
' "$config/joomla/6.2.json" >"$config/joomla/6.4.json"
assemble | jq -e '
    keys == ["6.2", "6.3", "6.4"]
    and .["6.4"].phpVersions["8.4"].variants.apache.base == "php:8.4-apache"
    and (.["6.4"].phpVersions["8.4"] | has("dev") | not)
' >/dev/null
rm "$config/php/8.4.json" "$config/joomla/6.4.json"

test_case='development false removes dev settings even when overrides contain them'
jq '.phpVersions["8.3"].overrides.dev = {"apt":["disabled-dev-package"]}' \
    "$config/joomla/6.2.json" >"$work/changed.json"
mv "$work/changed.json" "$config/joomla/6.2.json"
assemble | jq -e '.["6.2"].phpVersions["8.3"] | has("dev") | not' >/dev/null
restore

jq '.phpVersions["9.9"] = {"development": false}' \
    "$config/joomla/6.2.json" >"$work/changed.json"
mv "$work/changed.json" "$config/joomla/6.2.json"
reject 'referenced PHP profile does not exist'
restore

jq 'del(.dev)' "$config/php/8.3.json" >"$work/changed.json"
mv "$work/changed.json" "$config/php/8.3.json"
reject 'development requested without a dev profile'
restore

for selector in '"yes"' 'null' '[]'; do
    jq --argjson selector "$selector" '.phpVersions["8.3"].development = $selector' \
        "$config/joomla/6.2.json" >"$work/changed.json"
    mv "$work/changed.json" "$config/joomla/6.2.json"
    reject "nonboolean development selector $selector"
    restore
done

jq '.phpVersions["8.3"].overrides = []' "$config/joomla/6.2.json" >"$work/changed.json"
mv "$work/changed.json" "$config/joomla/6.2.json"
reject 'nonobject profile overrides'
restore

for directory in php joomla; do
    printf '{}\n' >"$config/$directory/notes.json"
    reject "invalid version filename in $directory"
    rm "$config/$directory/notes.json"
done

for file in index.json archives.json php/8.3.json joomla/6.2.json; do
    for content in '{invalid' '[]' $'{}\n{}'; do
        printf '%s\n' "$content" >"$config/$file"
        reject "malformed, nonobject or multiple JSON documents in $file"
        restore
    done
done

for file in archives.json php/8.3.json joomla/6.2.json; do
    jq '.sha256 = ("a" * 64)' "$config/$file" >"$work/changed.json"
    mv "$work/changed.json" "$config/$file"
    reject "input checksum in $file"
    restore
done
printf '{"sha512":"%0128d"}\n' 0 >"$config/php/9.9.json"
reject 'input checksum in an unused PHP profile'
rm "$config/php/9.9.json"

jq '.phpVersions = "missing-profiles"' "$config/index.json" >"$work/changed.json"
mv "$work/changed.json" "$config/index.json"
reject 'missing profile directory'
restore
jq '.archives = "missing-archives.json"' "$config/index.json" >"$work/changed.json"
mv "$work/changed.json" "$config/index.json"
reject 'missing shared archive file'
restore

echo 'Source assembly tests passed.'
