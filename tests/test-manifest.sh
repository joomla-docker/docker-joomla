#!/usr/bin/env bash
set -Eeuo pipefail
test_case="manifest test setup"
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/repository/src/build/lib" "$temporary/repository/conf" "$temporary/bin"
cp "$repository/release.sh" "$temporary/repository/"
cp "$repository/conf/maintainers.json" "$temporary/repository/conf/"
cp "$repository/src/build/lib/"*.jq "$temporary/repository/src/build/lib/"
jq --arg fixture current \
  -f "$repository/tests/fixtures.jq" "${TEST_VERSIONS_FILE:-$repository/conf/versions.json}" >"$temporary/repository/conf/versions.json"

# Stub only the metadata download; architecture parsing uses real shell code.
cat >"$temporary/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$PHP_METADATA_TEST_LOG"
if [[ ${PHP_METADATA_TEST_FAIL:-0} == 1 ]]; then exit 22; fi
destination=''
source_found=0
while (($#)); do
  case "$1" in
    -o) destination=$2; shift ;;
    https://raw.githubusercontent.com/docker-library/official-images/master/library/php) source_found=1 ;;
  esac
  shift
done
[[ -n $destination && $source_found == 1 ]]
cp "$PHP_METADATA_TEST_FILE" "$destination"
MOCK
chmod +x "$temporary/bin/curl"
export PATH="$temporary/bin:$PATH" PHP_METADATA_TEST_LOG="$temporary/download.log" PHP_METADATA_TEST_FILE="$temporary/php-metadata"
cd "$temporary/repository"
# Parent image names come from JSON, including configured variant overrides.
jq '
  to_entries[0].key as $series
  | (.[$series].states | to_entries[0].value.php) as $php
  | .[$series].variants[0] as $variant
  | .[$series].phpVersions[$php].variants[$variant].base += "-fixture"
' conf/versions.json >"$temporary/configured.json"
mv "$temporary/configured.json" conf/versions.json
jq -f src/build/lib/tags.jq conf/versions.json >"$temporary/plan.json"
while IFS=$'\t' read -r directory version parent; do
  mkdir -p "$directory"
  printf 'FROM %s\nENV JOOMLA_VERSION=%s\nCOPY runtime.ini /usr/local/etc/php/conf.d/runtime.ini\n' \
    "$parent" "$version" >"$directory/Dockerfile"
  printf '; fixture\n' >"$directory/runtime.ini"
  printf '%s\n' "$parent" >>"$temporary/parents"
done < <(jq -r --slurpfile config conf/versions.json '
  .[] as $context
  | $config[0][$context.series].phpVersions[$context.php]
  | if $context.development then . * .dev else . end
  | [$context.directory, $context.version, .variants[$context.variant].base] | @tsv
' "$temporary/plan.json")
while IFS= read -r parent; do
  # Exercise wrapped Tags and Architectures, plus an unrelated tag per stanza.
  printf 'Tags: unrelated-%s,\n      %s\nArchitectures: amd64,\n               arm64v8\n\n' \
    "${parent#php:}" "${parent#php:}"
done < <(sort -u "$temporary/parents") >"$PHP_METADATA_TEST_FILE"
cp "$PHP_METADATA_TEST_FILE" "$temporary/valid-metadata"
mkdir -p obsolete
printf 'FROM unavailable:obsolete\n' >obsolete/Dockerfile
git init -q
git config user.name 'Manifest fixture'
git config user.email 'manifest-fixture@example.test'
git add .
git commit -qm 'Create manifest fixture'

test_case="manifest tags and directories match the publication plan"
(cd /; "$temporary/repository/release.sh") >"$temporary/manifest"
jq -r '.[] | "Tags: " + (.tags | join(", "))' "$temporary/plan.json" >"$temporary/expected-tags"
grep '^Tags:' "$temporary/manifest" >"$temporary/actual-tags"
cmp "$temporary/expected-tags" "$temporary/actual-tags"
jq -r '.[] | "Directory: " + .directory' "$temporary/plan.json" >"$temporary/expected-paths"
grep '^Directory:' "$temporary/manifest" >"$temporary/actual-paths"
cmp "$temporary/expected-paths" "$temporary/actual-paths"
test_case="download metadata once for all parent images"
[[ "$(wc -l <"$PHP_METADATA_TEST_LOG")" == 1 ]]
grep -q '^Architectures: amd64, arm64v8$' "$temporary/manifest"

test_case="selected track honors repository and ref overrides"
# Select a configured track, regardless of whether it is stable or a prerelease.
selector="$(jq -r '.[0] | .series + "/" + .state' "$temporary/plan.json")"
directory="$(jq -r '.[0].directory' "$temporary/plan.json")"
parent="$(awk '$1 == "FROM" { print $2 }' "$directory/Dockerfile")"
version="$(jq -r '.[0].version' "$temporary/plan.json")"
STACKBREW_GIT_REPO=https://example.test/joomla.git STACKBREW_GIT_FETCH=refs/heads/test \
  ./release.sh "$selector/" >"$temporary/selected"
[[ "$(grep -c '^Directory:' "$temporary/selected")" == "$(jq --arg selector "$selector" '[.[] | select((.series + "/" + .state) == $selector)] | length' "$temporary/plan.json")" ]]
grep -q '^GitRepo: https://example.test/joomla.git$' "$temporary/selected"
grep -q '^GitFetch: refs/heads/test$' "$temporary/selected"

reject() {
  local diagnostic="$1"; shift
  test_case="reject invalid manifest input: $diagnostic"
  if ./release.sh "$@" >"$temporary/output" 2>"$temporary/error"; then
    printf 'FAIL: expected manifest error: %s\n' "$diagnostic" >&2; exit 1
  fi
  if [[ -s "$temporary/output" ]]; then
    echo "FAIL: invalid input produced a partial manifest: $diagnostic" >&2; exit 1
  fi
  if ! grep -Fq "$diagnostic" "$temporary/error"; then
    echo "FAIL: expected diagnostic: $diagnostic; actual error follows" >&2
    cat "$temporary/error" >&2; exit 1
  fi
}
reject 'unknown release selector' unconfigured
mv "$directory/Dockerfile" "$temporary/Dockerfile"
reject "missing $directory/Dockerfile"
mv "$temporary/Dockerfile" "$directory/Dockerfile"
printf '; changed\n' >>"$directory/runtime.ini"
reject 'uncommitted changes'
git add "$directory/runtime.ini"
git commit -qm 'Change a copied runtime file'
test_case="a changed copied file updates the context GitCommit"
./release.sh "$selector" >"$temporary/copied-file"
jq -ne --arg text "$(cat "$temporary/copied-file")" --arg commit "$(git rev-parse HEAD)" --arg directory "$directory" \
  '$text | contains("GitCommit: " + $commit + "\nDirectory: " + $directory)' >/dev/null
for architectures in '' '   ' unrecognised; do
  printf 'Tags: %s\nArchitectures: %s\n' "${parent#php:}" "$architectures" >"$PHP_METADATA_TEST_FILE"
  reject 'architecture'
done
printf 'Tags: unknown-tag\nArchitectures: amd64\n' >"$PHP_METADATA_TEST_FILE"
reject 'missing or ambiguous architecture'
cp "$temporary/valid-metadata" "$PHP_METADATA_TEST_FILE"
printf 'Tags: %s\nArchitectures: amd64\n' "${parent#php:}" >>"$PHP_METADATA_TEST_FILE"
reject 'missing or ambiguous architecture'
cp "$temporary/valid-metadata" "$PHP_METADATA_TEST_FILE"
export PHP_METADATA_TEST_FAIL=1
reject 'could not download PHP architecture metadata'
unset PHP_METADATA_TEST_FAIL

for instruction in $'COPY \\\n  --from=external:test /tool /tool' \
    $'RUN \\\n  --mount=type=bind,from=external:test,target=/tools true' 'FROM unknown:test'; do
  printf 'FROM %s\nENV JOOMLA_VERSION=%s\n%s\n' "$parent" "$version" "$instruction" >"$directory/Dockerfile"
  git add "$directory/Dockerfile"
  git commit -qm 'Create an unsupported dependency fixture'
  reject 'unsupported image dependencies'
done
printf 'Manifest generation tests passed.\n'
