#!/usr/bin/env bash
set -Eeuo pipefail
test_case='cleanup fixture setup'
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/dpkg/info" "$work/extensions"
DPKG_QUERY_BIN="$(command -v dpkg-query)"
export DPKG_QUERY_BIN
export TEST_DPKG_DB="$work/dpkg" TEST_LDD_OUTPUT="$work/ldd-output"
export TEST_PACKAGE_MARKS="$work/package-marks" TEST_APK_CALLS="$work/apk-calls"
export extDir="$work/extensions"
touch "$extDir/example.so"

# Use dpkg-query itself, with an isolated database and no host package changes.
printf '1\n' >"$work/dpkg/info/format"
for architecture in amd64 arm64; do
    cat >>"$work/dpkg/status" <<STATUS
Package: runtime-library
Status: install ok installed
Architecture: $architecture
Multi-Arch: same
Version: 1.0
Maintainer: Cleanup test <cleanup@example.test>
Description: runtime library fixture

STATUS
done
cat >>"$work/dpkg/status" <<'STATUS'
Package: development-helpers
Status: install ok installed
Architecture: all
Version: 1.0
Maintainer: Cleanup test <cleanup@example.test>
Description: development helper fixture

STATUS
printf '%s\n' /usr/lib/x86_64-linux-gnu/libexample.so.1 >"$work/dpkg/info/runtime-library:amd64.list"
printf '%s\n' /lib/aarch64-linux-gnu/libexample.so.1 >"$work/dpkg/info/runtime-library:arm64.list"
printf '%s\n' \
    /usr/share/gdb/auto-load/usr/lib/x86_64-linux-gnu/libexample.so.1.2-gdb.py \
    /usr/share/gdb/auto-load/lib/aarch64-linux-gnu/libexample.so.1.2-gdb.py \
    >"$work/dpkg/info/development-helpers.list"
cat >"$work/ldd-output" <<'LDD'
        libexample.so.1 => /usr/lib/x86_64-linux-gnu/libexample.so.1 (0x00000001)
        libexample.so.1 => /lib/aarch64-linux-gnu/libexample.so.1 (0x00000002)
        libprivate.so.1 => /usr/local/lib/libprivate.so.1 (0x00000003)
LDD
cp "$work/ldd-output" "$work/valid-ldd-output"

cat >"$work/bin/ldd" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
cat "$TEST_LDD_OUTPUT"
exit "${TEST_LDD_STATUS:-0}"
MOCK
cat >"$work/bin/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$DPKG_QUERY_BIN" --admindir="$TEST_DPKG_DB" "$@"
MOCK
cat >"$work/bin/apt-mark" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >"$TEST_PACKAGE_MARKS"
MOCK
cat >"$work/bin/scanelf" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' 'libsecond.so.2,libfirst.so.1' libfirst.so.1
exit "${TEST_SCANELF_STATUS:-0}"
MOCK
cat >"$work/bin/apk" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$TEST_APK_CALLS"
MOCK
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

# Run the exact production ownership pipeline, stopping before package removal.
awk '
    /^[[:space:]]*ldd / { copying = 1 }
    copying {
        if (/xargs -rt apt-mark manual/) { sub(/; \\$/, ";"); print; exit }
        print
    }
' "$repo/src/build/lib/cleanup-apt.inc" >"$work/apt-pipeline"
[[ -s "$work/apt-pipeline" ]]

test_case='Debian suffix lookup excludes debug helpers and preserves multiarch names'
bash -euo pipefail "$work/apt-pipeline"
printf '%s\n' manual runtime-library:amd64 runtime-library:arm64 >"$work/expected-marks"
cmp "$work/expected-marks" "$work/package-marks"

test_case='Debian ownership lookup ignores diversion status lines'
printf '%s\n' \
    /usr/lib/x86_64-linux-gnu/libexample.so.1 \
    /usr/lib/x86_64-linux-gnu/libexample.so.1.distrib \
    development-helpers >"$work/dpkg/diversions"
LC_ALL=C dpkg-query --search '*lib/x86_64-linux-gnu/libexample.so.1' >"$work/diversion-output"
grep -q '^diversion by development-helpers ' "$work/diversion-output"
bash -euo pipefail "$work/apt-pipeline"
cmp "$work/expected-marks" "$work/package-marks"

test_case='missing Debian library ownership fails the cleanup'
printf '%s\n' 'libmissing.so.1 => /usr/lib/libmissing.so.1 (0x00000004)' >"$work/ldd-output"
if bash -euo pipefail "$work/apt-pipeline" >"$work/output" 2>"$work/error"; then
    echo 'Unowned shared library accepted' >&2
    exit 1
fi
grep -Fq libmissing.so.1 "$work/error"

test_case='failed Debian dependency discovery fails the cleanup'
cp "$work/valid-ldd-output" "$work/ldd-output"
if TEST_LDD_STATUS=7 bash -euo pipefail "$work/apt-pipeline" >"$work/output" 2>"$work/error"; then
    echo 'Failed dependency discovery accepted' >&2
    exit 1
fi

test_case='Alpine retains unique runtime sonames before removing build dependencies'
bash -euo pipefail "$repo/src/build/lib/cleanup-apk.inc"
printf '%s\n' \
    'add --no-network --virtual .joomla-phpexts-rundeps so:libfirst.so.1 so:libsecond.so.2' \
    'del --no-network .build-deps' >"$work/expected-apk"
cmp "$work/expected-apk" "$work/apk-calls"

test_case='failed Alpine dependency discovery stops before package removal'
if TEST_SCANELF_STATUS=7 bash -euo pipefail "$repo/src/build/lib/cleanup-apk.inc" >"$work/output" 2>"$work/error"; then
    echo 'Failed scanelf discovery accepted' >&2
    exit 1
fi
cmp "$work/expected-apk" "$work/apk-calls"
echo 'Dependency cleanup tests passed.'
