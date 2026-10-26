#!/usr/bin/env bash
# Runs on a host with PHP or inside any generated image; never changes system INI.
# Usage: tests/test-hardening.sh [ENTRYPOINT PROFILE]
set -Eeuo pipefail
test_case='hardening test setup'
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
entrypoint=${1:-$tests_dir/../src/runtime/docker-entrypoint.sh}
profile=${2:-}
command -v php >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PHP_INI_DIR="$work/php" PHPRC="$work/php/php.ini"
export PHP_INI_SCAN_DIR="$PHP_INI_DIR/conf.d"
mkdir -p "$PHP_INI_SCAN_DIR" "$work/bin" "$work/site/libraries/src"
touch "$PHPRC"
source_profile="$PHP_INI_DIR/joomla-hardening.ini"
if [[ -n $profile ]]; then
    cp "$profile" "$source_profile"
else
    # Use a maintained PHP profile; image tests use the INI built into the image.
    profiles=("$tests_dir/../conf/php/"*.json)
    jq -er '.config["/usr/local/etc/php/joomla-hardening.ini"][]' "${profiles[0]}" >"$source_profile"
fi
cp "$source_profile" "$work/profile.ini"
source_identity=$(stat -c '%i:%Y' "$source_profile")
managed="$PHP_INI_SCAN_DIR/zz-joomla-hardening.ini"
checker="$tests_dir/hardening-check.php"
unset JOOMLA_SECURITY_HARDENED

entry() { bash "$entrypoint" "$@"; }
snapshot() { php "$checker" snapshot; }
assert_hardened() { php "$checker"; }
assert_custom_policy() {
    # shellcheck disable=SC2016 # PHP expands its own argument array.
    php -r '
        exit(ini_get("disable_functions") === "unlink" && !function_exists("unlink")
            && filter_var(ini_get("allow_url_fopen"), FILTER_VALIDATE_BOOLEAN) === ($argv[1] === "On") ? 0 : 1);
    ' "$1"
}
expect_failure() {
    local message=$1
    shift
    if "$@" >"$work/failure.log" 2>&1; then
        echo 'Expected command to fail' >&2
        return 1
    fi
    grep -Fq -- "$message" "$work/failure.log"
}

test_case='unset and false preserve the complete PHP configuration'
snapshot >"$work/baseline"
entry php "$checker" snapshot >"$work/default"
cmp "$work/baseline" "$work/default"
[[ ! -e $managed && -f $source_profile ]]
JOOMLA_SECURITY_HARDENED=false entry php "$checker" snapshot >"$work/false"
cmp "$work/baseline" "$work/false"

test_case='activation applies all directives and restrictions before direct PHP'
for value in true 1 TRUE TrUe; do
    (umask 077; JOOMLA_SECURITY_HARDENED="$value" entry php "$checker")
    [[ -f $managed && -f $source_profile ]]
    [[ $(stat -c '%a' "$managed") == 644 ]]
    cmp "$work/profile.ini" "$managed"
    cmp "$work/profile.ini" "$source_profile"
done
assert_hardened # A subsequent PHP process also sees the active profile.

test_case='repeated activation is idempotent and does not replace the file'
cp "$managed" "$work/enabled.ini"
identity=$(stat -c '%i:%Y' "$managed")
JOOMLA_SECURITY_HARDENED=true entry true
cmp "$work/enabled.ini" "$managed"
[[ $(stat -c '%i:%Y' "$managed") == "$identity" ]]

test_case='a stale active profile is replaced by the unchanged source'
printf '; stale active profile\n' >"$managed"
JOOMLA_SECURITY_HARDENED=true entry php "$checker"
cmp "$work/profile.ini" "$managed"
cmp "$work/profile.ini" "$source_profile"

test_case='disabled values remove only the active copy'
printf '; user-owned configuration\n' >"$PHP_INI_SCAN_DIR/custom.ini"
for value in false 0 FALSE ''; do
    JOOMLA_SECURITY_HARDENED="$value" entry php "$checker" snapshot >"$work/disabled"
    [[ ! -e $managed && -f $source_profile && -f $PHP_INI_SCAN_DIR/custom.ini ]]
    cmp "$work/profile.ini" "$source_profile"
    cmp "$work/baseline" "$work/disabled"
    JOOMLA_SECURITY_HARDENED=true entry true
done
entry php "$checker" snapshot >"$work/disabled"
[[ ! -e $managed && -f $source_profile ]]
cmp "$work/baseline" "$work/disabled"

test_case='custom function restrictions and URL wrappers remain effective in both states'
for value in On Off; do
    printf 'disable_functions = unlink\nallow_url_fopen = %s\n' "$value" >"$PHP_INI_SCAN_DIR/custom.ini"
    cp "$PHP_INI_SCAN_DIR/custom.ini" "$work/custom.ini"
    snapshot >"$work/custom-baseline"
    assert_custom_policy "$value"
    JOOMLA_SECURITY_HARDENED=true entry php "$checker"
    assert_custom_policy "$value"
    cmp "$work/custom.ini" "$PHP_INI_SCAN_DIR/custom.ini"
    JOOMLA_SECURITY_HARDENED=false entry php "$checker" snapshot >"$work/disabled"
    assert_custom_policy "$value"
    cmp "$work/custom-baseline" "$work/disabled"
done
rm "$PHP_INI_SCAN_DIR/custom.ini"

test_case='invalid settings fail before executing the requested command'
for value in yes no tru 2; do
    expect_failure 'JOOMLA_SECURITY_HARDENED must be' env JOOMLA_SECURITY_HARDENED="$value" \
        bash "$entrypoint" touch "$work/executed"
    [[ ! -e $managed && ! -e $work/executed ]]
done

test_case='missing source prevents startup even when an active copy exists'
mv "$source_profile" "$work/missing-profile.ini"
expect_failure 'hardening profile' env JOOMLA_SECURITY_HARDENED=true bash "$entrypoint" touch "$work/executed"
[[ ! -e $work/executed ]]
cp "$work/profile.ini" "$managed"
expect_failure 'hardening profile' env JOOMLA_SECURITY_HARDENED=true bash "$entrypoint" touch "$work/executed"
[[ ! -e $work/executed ]]
JOOMLA_SECURITY_HARDENED=false entry true
[[ ! -e $managed ]]

test_case='empty and nonregular sources prevent startup'
touch "$source_profile"
expect_failure 'hardening profile' env JOOMLA_SECURITY_HARDENED=true bash "$entrypoint" touch "$work/executed"
rm "$source_profile"
mkdir "$source_profile"
expect_failure 'hardening profile' env JOOMLA_SECURITY_HARDENED=true bash "$entrypoint" touch "$work/executed"
rmdir "$source_profile"
ln -s "$work/profile.ini" "$source_profile"
expect_failure 'hardening profile' env JOOMLA_SECURITY_HARDENED=true bash "$entrypoint" touch "$work/executed"
rm "$source_profile"
[[ ! -e $managed && ! -e $work/executed ]]
mv "$work/missing-profile.ini" "$source_profile"

test_case='enabling rejects an active symlink and disabling safely removes it'
cp "$work/profile.ini" "$work/symlink-target.ini"
ln -s "$work/symlink-target.ini" "$managed"
expect_failure 'hardening profile' env JOOMLA_SECURITY_HARDENED=true bash "$entrypoint" touch "$work/executed"
[[ -L $managed && ! -e $work/executed ]]
JOOMLA_SECURITY_HARDENED=false entry true
[[ ! -L $managed && ! -e $managed ]]
cmp "$work/profile.ini" "$work/symlink-target.ini"

test_case='an active directory is never overwritten or removed'
mkdir "$managed"
for value in true false; do
    expect_failure 'hardening profile' env JOOMLA_SECURITY_HARDENED="$value" \
        bash "$entrypoint" touch "$work/executed"
    [[ -d $managed && ! -e $work/executed ]]
done
rmdir "$managed"

test_case='direct PHP and shell commands do not depend on a Joomla installation'
mkdir "$work/site/.joomla-initializing"
touch "$work/site/configuration.php"
JOOMLA_WEBROOT="$work/site" JOOMLA_SECURITY_HARDENED=true entry php "$checker"
# shellcheck disable=SC2016 # The child shell expands its positional argument.
JOOMLA_WEBROOT="$work/site" JOOMLA_SECURITY_HARDENED=false \
    entry sh -c 'php "$1" snapshot' sh "$checker" >"$work/disabled"
cmp "$work/baseline" "$work/disabled"
rmdir "$work/site/.joomla-initializing"

test_case='installed server startup applies hardening before launching the server'
printf '<?php\n' >"$work/site/configuration.php"
touch "$work/site/index.php" "$work/site/libraries/src/Version.php"
cat >"$work/bin/apache2-hardening-test" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec php "$HARDENING_TEST_CHECKER"
SH
chmod 0755 "$work/bin/apache2-hardening-test"
PATH="$work/bin:$PATH" JOOMLA_WEBROOT="$work/site" APACHE_RUN_USER='#12345' \
    APACHE_RUN_GROUP='#12345' HARDENING_TEST_CHECKER="$checker" JOOMLA_SECURITY_HARDENED=true \
    entry apache2-hardening-test
JOOMLA_SECURITY_HARDENED=false entry true
cmp "$work/profile.ini" "$source_profile"
[[ $(stat -c '%i:%Y' "$source_profile") == "$source_identity" ]]
printf 'PHP hardening tests passed (%s).\n' "$(php -r 'echo PHP_VERSION;')"
