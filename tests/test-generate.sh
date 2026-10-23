#!/usr/bin/env bash
set -Eeuo pipefail
test_case='generation entrypoint setup'
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixture="$work/repository with spaces"
mkdir -p "$fixture/src/build" "$work/outside"
cp "$repo/generate.sh" "$fixture/"
export GENERATE_TEST_LOG="$work/calls"

# Record the public boundary: resolution completes before context generation,
# --force reaches only the resolver, and failed resolution never starts a build.
cat >"$fixture/src/build/versions.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -nc --arg stage versions --arg cwd "$PWD" --args \
    '{stage:$stage, cwd:$cwd, arguments:$ARGS.positional}' -- "$@" >>"$GENERATE_TEST_LOG"
exit "${GENERATE_TEST_FAILURE:-0}"
SH
cat >"$fixture/src/build/build.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -nc --arg stage build --arg cwd "$PWD" --args \
    '{stage:$stage, cwd:$cwd, arguments:$ARGS.positional}' -- "$@" >>"$GENERATE_TEST_LOG"
SH
chmod +x "$fixture/src/build/"*.sh
cd "$work/outside"

test_case='entrypoint runs the complete pipeline from another directory'
"$fixture/generate.sh"
jq -se --arg root "$fixture" '
    map(.stage) == ["versions", "build"]
    and all(.[]; .cwd == $root and .arguments == [])
' "$GENERATE_TEST_LOG" >/dev/null

for flag in --force -f; do
    test_case="selectors and $flag reach the correct stages"
    : >"$GENERATE_TEST_LOG"
    "$fixture/generate.sh" "$flag" 100.0/beta 101.0
    jq -se --arg root "$fixture" --arg flag "$flag" '
        map(.stage) == ["versions", "build"] and all(.[]; .cwd == $root)
        and .[0].arguments == [$flag, "100.0/beta", "101.0"]
        and .[1].arguments == ["100.0/beta", "101.0"]
    ' "$GENERATE_TEST_LOG" >/dev/null
done

test_case='failed resolution stops generation and preserves its exit status'
: >"$GENERATE_TEST_LOG"
status=0
GENERATE_TEST_FAILURE=37 "$fixture/generate.sh" --force 100.0/beta || status=$?
[[ "$status" == 37 ]]
jq -se 'map(.stage) == ["versions"]' "$GENERATE_TEST_LOG" >/dev/null

test_case='help performs no resolution or generation'
: >"$GENERATE_TEST_LOG"
"$fixture/generate.sh" --help >"$work/help"
grep -Fq generate.sh "$work/help"
[[ ! -s "$GENERATE_TEST_LOG" ]]
printf 'Generation entrypoint tests passed.\n'
