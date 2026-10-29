#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "FAIL: Dockerfile generation at line $LINENO" >&2' ERR
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src/build" "$work/src/runtime" "$work/conf"
cp "$repo/src/build/build.sh" "$work/src/build/"
cp -r "$repo/src/build/lib" "$work/src/build/"
cp "$repo/src/runtime/"docker-entrypoint*.sh "$repo/src/runtime/makedb.php" "$work/src/runtime/"
cp "$repo/conf/maintainers.json" "$work/conf/"
jq --arg fixture current -f "$repo/tests/fixtures.jq" "${TEST_VERSIONS_FILE:-$repo/conf/versions.json}" >"$work/conf/versions.json"
printf 'must not read helper\n' >"$work/conf/versions-helper.json"
cd "$work"
mkdir retired
printf 'preserve\n' >retired/Dockerfile
# Execute from outside the repository to exercise script-relative root discovery.
(cd /; "$work/src/build/build.sh") >/dev/null

contains() {
    if ! grep -Fq -- "$2" "$1"; then
        printf 'Missing %s in %s\n' "$2" "$1" >&2
        return 1
    fi
}
excludes() {
    if grep -Fq -- "$2" "$1"; then
        printf 'Unexpected %s in %s\n' "$2" "$1" >&2
        return 1
    fi
}
count() {
    awk -v token="$2" 'index($0, token) { total++ } END { print total + 0 }' "$1"
}
uses_variable() {
    grep -Fq -- "\$$2" "$1" || grep -Fq -- "\${$2}" "$1"
}
contains_entry() {
    awk -v expected="$2" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[;]?[[:space:]]*\\$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == expected) found = 1
        }
        END { exit !found }
    ' "$1"
}
run_block() {
    sed ':join; /\\$/ { N; s/\\\n//; b join; }' "$1" \
        | awk -v wanted="$2" '/^RUN / { number++; if (number == wanted) { sub(/^RUN /, ""); print } }'
}
run_commands() {
    # A complete generated step ends with a semicolon or the end of its RUN.
    # Package/config entries can span several continued physical lines.
    awk '
        /^RUN / { active = 1; sub(/^RUN /, "") }
        active {
            line = $0
            continued = sub(/[[:space:]]*\\$/, "", line)
            complete = sub(/;[[:space:]]*$/, "", line)
            command = command (command == "" ? "" : " ") line
            if (complete || !continued) { print command; command = "" }
            if (!continued) active = 0
        }
    ' "$1"
}

contexts="$(jq -c -f src/build/lib/tags.jq conf/versions.json)"
jq -c '.[]' <<<"$contexts" >"$work/contexts"
while IFS= read -r context; do
    directory="$(jq -r '.directory' <<<"$context")"
    [[ "$directory" == images/* ]]
    development="$(jq -r '.development' <<<"$context")"
    if [[ "$development" == true ]]; then
        [[ "$(find "$directory" -maxdepth 1 -type f | wc -l)" == 1 ]]
        [[ ! -e "$directory/docker-entrypoint.sh" && ! -e "$directory/makedb.php" ]]
    else
        cmp src/runtime/docker-entrypoint.sh "$directory/docker-entrypoint.sh"
        cmp src/runtime/makedb.php "$directory/makedb.php"
        [[ "$(stat -c '%a' "$directory/docker-entrypoint.sh")" == 755 ]]
        [[ "$(stat -c '%a' "$directory/makedb.php")" == 644 ]]
    fi
    dockerfile="$directory/Dockerfile"
    # Normal images configure the runtime; dev images install only their additions.
    image="$(jq -c --argjson context "$context" '
        .[$context.series].phpVersions[$context.php] as $base
        | if $context.development then
            $base.dev
            | if (.pie // {} | length) > 0 and .download.pie == null then
                .download.pie = $base.download.pie
              else . end
          else $base * $base.variants[$context.variant] end
    ' conf/versions.json)"
    if [[ "$development" == true ]]; then
        parent="$(jq -r '"joomla:\(.version)-php\(.php)-\(.variant)"' <<<"$context")"
        contains "$dockerfile" "FROM $parent"
        jq -e --arg parent "${parent#joomla:}" --arg directory "${directory%-dev}" '
            any(.[]; .directory == $directory and (.tags | index($parent) != null))
        ' <<<"$contexts" >/dev/null
    else
        contains "$dockerfile" "FROM $(jq -r '.base' <<<"$image")"
    fi
    run_block "$dockerfile" 1 >"$work/install-run"
    run_block "$dockerfile" 2 >"$work/config-run"
    run_block "$dockerfile" 3 >"$work/joomla-run"
    expected_runs=3
    release_downloads=1
    if [[ "$development" == true ]]; then expected_runs=2; release_downloads=0; fi
    [[ "$(grep -c '^RUN ' "$dockerfile")" == "$expected_runs" ]]
    while IFS= read -r value; do
        contains "$dockerfile" "$value"
        [[ "$(count "$dockerfile" "$value")" == 1 ]]
    done < <(jq -r '.download[] | .package, .sha256' <<<"$image")
    while IFS= read -r name; do
        [[ "$(count "$dockerfile" "ARG ${name}_URL=")" == 1 ]]
        [[ "$(count "$dockerfile" "ARG ${name}_SHA256=")" == 1 ]]
        uses_variable "$work/install-run" "${name}_URL"
        uses_variable "$work/install-run" "${name}_SHA256"
    done < <(jq -r '.download | keys[] | ascii_upcase' <<<"$image")
    while IFS= read -r package; do
        contains "$dockerfile" "$package"
    done < <(jq -r '(.pie // {} | to_entries[] | .key + ":" + .value),
                    (.npm // {} | to_entries[] | .key + "@" + .value)' <<<"$image")
    excludes "$dockerfile" '--working-dir=/tmp/extension-'
    excludes "$dockerfile" '--skip-enable-extension'
    excludes "$dockerfile" '/tmp/extension-'
    [[ "$(count "$dockerfile" 'curl --fail')" -eq "$(jq --argjson release "$release_downloads" '(.download | length) + $release' <<<"$image")" ]]
    while IFS= read -r value; do
        contains "$work/config-run" "$value"
    done < <(jq -r '.config | to_entries[] | .key, .value[]' <<<"$image")
    while IFS= read -r destination; do
        grep -F 'rm -rf ' "$work/install-run" | grep -Fq -- "$destination"
    done < <(jq -r '.download[] | select(.temporary) | .destination' <<<"$image")
    contains "$work/config-run" 'php --version'
    while IFS= read -r module; do
        run_commands "$dockerfile" | grep -F 'php --ri ' | grep -Fq -- "$module"
    done < <(jq -r --argjson context "$context" '
        .[$context.series].phpVersions[$context.php] as $base
        | if $context.development then [$base.dev] else [$base, $base.variants[$context.variant]] end
        | [ .[] | (.extensions.install // [])[], (.extensions.check // [])[] ] | unique[]
    ' conf/versions.json)
    manager=apt
    if [[ "$(jq -r '.variant' <<<"$context")" == *alpine* ]]; then manager=apk; fi
    while IFS= read -r entry; do
        contains_entry "$dockerfile" "$entry"
    done < <(jq -r --argjson context "$context" --arg manager "$manager" '
        .[$context.series].phpVersions[$context.php] as $base
        | if $context.development then [$base.dev] else [$base, $base.variants[$context.variant]] end
        | [ .[] | (.[$manager] // [])[], (.build[$manager] // [])[], (.extensions.install // [])[] ] | unique[]
    ' conf/versions.json)
    while IFS= read -r check; do
        contains "$work/config-run" "$check"
    done < <(jq -r --argjson context "$context" '
        .[$context.series].phpVersions[$context.php] as $base
        | if $context.development then [$base.dev] else [$base, $base.variants[$context.variant]] end
        | [ .[] | (.checks // [])[] | join(" ") ] | unique[]
    ' conf/versions.json)
    if [[ "$development" == false ]]; then
        while IFS= read -r package; do
            contains "$work/joomla-run" "$package"
        done < <(jq -r --argjson context "$context" --arg manager "$manager" '
            .[$context.series] | .archives[.states[$context.state].packageType][$manager][]
        ' conf/versions.json)
        contains "$dockerfile" 'COPY docker-entrypoint.sh /entrypoint.sh'
        contains "$dockerfile" 'COPY makedb.php /makedb.php'
    else
        for inherited in 'COPY ' 'ENTRYPOINT ' 'CMD ' 'VOLUME ' 'WORKDIR ' \
            'JOOMLA_VERSION' 'JOOMLA_SHA512' 'JOOMLA_URL' 'joomla-hardening.ini' \
            'a2enmod ' 'JOOMLA_INSTALLATION_DISABLE_LOCALHOST_CHECK' \
            'imagick/imagick:' 'phpredis/phpredis:' 'ghostscript'; do
            excludes "$dockerfile" "$inherited"
        done
        if [[ "$manager" == apk ]]; then
            contains "$work/install-run" '.joomla-dev-phpexts-rundeps'
            excludes "$work/install-run" '--virtual .joomla-phpexts-rundeps'
        fi
    fi
    excludes "$dockerfile" 'COPY --chmod='
    excludes "$dockerfile" 'SHELL '
    excludes "$dockerfile" 'DEBIAN_FRONTEND'
    if [[ "$development" == false ]]; then
        contains "$dockerfile" 'LABEL org.opencontainers.image.authors='
    fi
    excludes "$dockerfile" 'LABEL maintainer='
    contains "$dockerfile" "printf '%s *%s\\n'"
    excludes "$dockerfile" "printf '%s  %s\\n'"
    if [[ "$(jq -r '.variant' <<<"$context")" == *alpine* ]]; then
        # shellcheck disable=SC2016
        excludes "$dockerfile" 'ldd "$extDir"/*.so | grep "not found"'
    fi
    if [[ "$development" == false ]]; then
        # Release metadata must not invalidate the extensions or configuration layers.
        awk '
            /^RUN / { runs++ }
            /^ENV JOOMLA_VERSION=/ { if (runs != 2) exit 1; version++ }
            /^ENV JOOMLA_SHA512=/ { if (runs != 2) exit 1; checksum++ }
            /^ARG JOOMLA_URL=/ { if (runs != 2) exit 1; url++ }
            END { if (version != 1 || checksum != 1 || url != 1) exit 1 }
        ' "$dockerfile"
        contains "$work/joomla-run" 'JOOMLA_URL'
        contains "$work/joomla-run" 'JOOMLA_SHA512'
        contains "$work/joomla-run" 'rm -f /tmp/joomla.'
    fi
    excludes "$dockerfile" 'COPY zz-'
    if [[ "$(jq -r '.development' <<<"$context")" == false ]]; then
        excludes "$dockerfile" xdebug
        excludes "$dockerfile" nodejs
    fi
    # Parse every complete generated RUN instruction with the target shell.
    while IFS= read -r line; do
        if [[ "$line" == 'RUN '* ]]; then
            sh -n <<<"${line#RUN }"
        fi
    done < <(sed ':join; /\\$/ { N; s/\\\n//; b join; }' "$dockerfile")
done <"$work/contexts"
printf 'preserve\n' | cmp - retired/Dockerfile

# Exercise selections absent from the maintained matrix without assuming versions.
IFS=$'\t' read -r series state php variant < <(jq -r '
    to_entries[0] | [.key, (.value.states | keys[0]),
                    (.value.phpVersions | keys[0]), .value.variants[0]] | @tsv
' conf/versions.json)
literal="custom.value=can't \$(touch $work/executed)"
configure_literal="--with-example=can't \"quoted\" \$(touch $work/executed-configure) \`touch $work/executed-backtick\`/\${DEB_BUILD_MULTIARCH}/tail"
jq --arg series "$series" --arg php "$php" --arg variant "$variant" \
    --arg path "$work/quoted.ini" --arg value "$literal" --arg configure "$configure_literal" --arg pie "$work/pie" '
    .[$series].phpVersions[$php].dev.apt = ["sentinel-dev-package"]
    | .[$series].phpVersions[$php].dev.apk = ["sentinel-dev-package"]
    | .[$series].phpVersions[$php].dev.config = {"/tmp/custom.ini": ["custom.value=${RUNTIME_VALUE}"]}
    | .[$series].phpVersions[$php].dev.config[$path] = [$value]
    | .[$series].phpVersions[$php].extensions.configure.example = [$configure]
    | .[$series].phpVersions[$php].download.pie.destination = $pie
    | .[$series].phpVersions[$php].variants[$variant].base = "php:100.0-test"
' conf/versions.json >"$work/trial.json"
# Source the generator without invoking its publication entry point.
# shellcheck source=/dev/null
source ./src/build/build.sh
render() {
    render_dockerfile "$1" "$series" "$state" "$2" "$variant" "$3" >"$4"
}
render "$work/trial.json" "$php" 0 "$work/normal"
render "$work/trial.json" "$php" 1 "$work/dev"
excludes "$work/normal" sentinel-dev-package
contains "$work/dev" sentinel-dev-package
contains "$work/dev" /tmp/custom.ini
# The renderer must retain the target container's runtime variable literally.
# shellcheck disable=SC2016
contains "$work/dev" 'custom.value=${RUNTIME_VALUE}'
# Execute only the generated config-file write inside this test's directory.
# Quoting must preserve apostrophes and prevent literal command substitution.
config_step="$(run_commands "$work/dev" | grep -F "> $work/quoted.ini")"
sh -eu -c "$config_step"
[[ ! -e "$work/executed" ]]
printf '%s\n' "$literal" | cmp - "$work/quoted.ini"
contains "$work/normal" 'FROM php:100.0-test'
# Only the documented multiarch variable may expand in configure arguments.
# Intercept the helper so no extension is configured or compiled by this test.
mkdir "$work/bin"
cat >"$work/bin/docker-php-ext-configure" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$TEST_ARGUMENTS_FILE"
SH
chmod +x "$work/bin/docker-php-ext-configure"
configure_step="$(run_commands "$work/normal" | grep -F 'docker-php-ext-configure example ')"
DEB_BUILD_MULTIARCH=test-triplet TEST_ARGUMENTS_FILE="$work/configure-arguments" \
    PATH="$work/bin:$PATH" sh -eu -c "$configure_step"
[[ ! -e "$work/executed-configure" && ! -e "$work/executed-backtick" ]]
# shellcheck disable=SC2016
printf '%s\n' example "${configure_literal//'${DEB_BUILD_MULTIARCH}'/test-triplet}" | cmp - "$work/configure-arguments"

# Verify the emitted checksum command accepts the artifact and rejects tampering.
printf 'verified test artifact\n' >"$work/pie"
checksum_step="$(run_commands "$work/normal" | grep -F sha256sum | grep -F "$work/pie")"
PIE_SHA256="$(sha256sum "$work/pie" | cut -d ' ' -f 1)" sh -eu -c "$checksum_step" >/dev/null
if PIE_SHA256="$(printf '%064d' 0)" sh -eu -c "$checksum_step" >"$work/checksum-log" 2>&1; then
    echo 'Invalid artifact checksum accepted' >&2; exit 1
fi

# A failed required module check must fail the generated verification command.
cat >"$work/bin/php" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$work/bin/php"
module_step="$(run_commands "$work/normal" | awk '/php --ri / && !found { print; found = 1 }')"
[[ -n "$module_step" ]]
if PATH="$work/bin:$PATH" sh -eu -c "$module_step" >"$work/module-log" 2>&1; then
    echo 'Missing required PHP module accepted' >&2; exit 1
fi

# Changing only the Joomla release leaves the preceding image layers identical.
jq --arg series "$series" --arg state "$state" '
    .[$series].states[$state] |= (
        .version |= sub("^[0-9]+\\.[0-9]+\\.[0-9]+"; $series + ".999")
        | .package = ("https://example.invalid/" + .version + "." + .packageType)
        | .sha512 = ("0" * 128))
' "$work/trial.json" >"$work/release-change.json"
render "$work/release-change.json" "$php" 0 "$work/release-change"
awk '/^ENV JOOMLA_VERSION=/ { exit } { print }' "$work/normal" >"$work/prefix-before"
awk '/^ENV JOOMLA_VERSION=/ { exit } { print }' "$work/release-change" >"$work/prefix-after"
cmp "$work/prefix-before" "$work/prefix-after"
if cmp -s "$work/normal" "$work/release-change"; then echo 'Changed release ignored' >&2; exit 1; fi

# Other supported archive formats select their own temporary extraction tools.
check_archive_formats() {
    local archive_type archive_variant manager package
    local -a archive_variants=()
    mapfile -t archive_variants < <(jq -r --arg series "$series" '
        .[$series].variants
        | (map(select(contains("alpine") | not))[0]), (map(select(contains("alpine")))[0])
        | select(. != null)
    ' "$work/trial.json")
    for archive_type in tar.gz tar.bz2; do
        jq --arg series "$series" --arg state "$state" --arg type "$archive_type" '
            .[$series].states[$state] |= (
                .packageType = $type | .package = ("https://example.invalid/joomla." + $type))
        ' "$work/trial.json" >"$work/archive-case.json"
        for archive_variant in "${archive_variants[@]}"; do
            render_dockerfile "$work/archive-case.json" "$series" "$state" "$php" "$archive_variant" 0 >"$work/archive-case"
            run_block "$work/archive-case" 1 >"$work/archive-install"
            run_block "$work/archive-case" 3 >"$work/archive-extract"
            excludes "$work/archive-install" zstd
            excludes "$work/archive-extract" zstd
            contains "$work/archive-extract" "tar -xf /tmp/joomla.$archive_type"
            manager=apt
            if [[ "$archive_variant" == *alpine* ]]; then manager=apk; fi
            while IFS= read -r package; do
                contains "$work/archive-extract" "$package"
            done < <(jq -r --arg series "$series" --arg type "$archive_type" --arg manager "$manager" '
                .[$series].archives[$type][$manager][]
            ' "$work/archive-case.json")
        done
    done
}
check_archive_formats
jq --arg series "$series" --arg php "$php" '
    .[$series].phpVersions["100.0"] = (.[$series].phpVersions[$php] | del(.dev))
' "$work/trial.json" >"$work/without-dev.json"
render "$work/without-dev.json" 100.0 0 "$work/without-dev"
excludes "$work/without-dev" sentinel-dev-package

# Development parents follow exact release versions for every state and runtime.
# A prerelease must never silently inherit the stable release or default PHP.
jq --arg fixture synthetic -f "$repo/tests/fixtures.jq" conf/versions.json \
    | jq --slurpfile maintained conf/versions.json '
        ([$maintained[0][] | .phpVersions | to_entries[] | select(.value.dev != null)][0]) as $profile
        | {"100.0": .["100.0"]}
        | .["100.0"].phpVersions = {($profile.key): $profile.value}
        | .["100.0"].states |= map_values(.php = $profile.key)
    ' >"$work/prereleases.json"
jq -f src/build/lib/tags.jq "$work/prereleases.json" >"$work/prerelease-plan"
while IFS= read -r context; do
    IFS=$'\t' read -r release_series release_state release_php release_variant parent_tag < <(
        jq -r '[.series, .state, .php, .variant, (.version + "-php" + .php + "-" + .variant)] | @tsv' <<<"$context"
    )
    render_dockerfile "$work/prereleases.json" "$release_series" "$release_state" "$release_php" "$release_variant" 1 >"$work/prerelease-dev"
    grep -Fxq "FROM joomla:$parent_tag" "$work/prerelease-dev"
    excludes "$work/prerelease-dev" 'JOOMLA_URL'
    jq -e --arg parent "$parent_tag" --arg directory "$(jq -r '.directory | rtrimstr("-dev")' <<<"$context")" '
        any(.[]; .directory == $directory and .development == false and (.tags | index($parent) != null))
    ' "$work/prerelease-plan" >/dev/null
done < <(jq -c '.[] | select(.development)' "$work/prerelease-plan")

# A package without PIE support can use PECL and the PHP image's enable helper.
jq --arg series "$series" --arg php "$php" '
    .[$series].phpVersions[$php].pecl = {example: "100.0.0"}
    | .[$series].phpVersions[$php].extensions.enable += ["example"]
' "$work/trial.json" >"$work/pecl.json"
render "$work/pecl.json" "$php" 0 "$work/pecl"
contains "$work/pecl" 'pecl install '
contains "$work/pecl" example-100.0.0
awk '
    /pecl install / { installed = NR }
    /docker-php-ext-enable / { enabled = NR }
    END { exit !(installed > 0 && enabled > installed) }
' "$work/pecl"
excludes "$work/pecl" /tmp/extension-

# Regeneration removes stale generated helpers from dev contexts, while keeping
# unrelated files and every normal runtime copy.
while IFS= read -r directory; do
    cp src/runtime/docker-entrypoint.sh "$directory/docker-entrypoint.sh"
    cp src/runtime/makedb.php "$directory/makedb.php"
    printf 'preserve\n' >"$directory/notes.txt"
done < <(jq -r 'select(.development) | .directory' "$work/contexts")
find . -name Dockerfile -print0 | sort -z | xargs -0 sha256sum >"$work/before"
./src/build/build.sh >/dev/null
while IFS= read -r directory; do
    [[ ! -e "$directory/docker-entrypoint.sh" && ! -e "$directory/makedb.php" ]]
    printf 'preserve\n' | cmp - "$directory/notes.txt"
done < <(jq -r 'select(.development) | .directory' "$work/contexts")
find . -name Dockerfile -print0 | sort -z | xargs -0 sha256sum >"$work/after"
cmp "$work/before" "$work/after"
if ./src/build/build.sh unknown/state >"$work/log" 2>&1; then echo 'Unknown selector accepted' >&2; exit 1; fi
# Reject invalid resolved input without changing any existing build contexts.
jq --arg series "$series" --arg php "$php" '
    .[$series].phpVersions[$php].download.pie.sha256 = "invalid"
' conf/versions.json >"$work/invalid.json"
mv "$work/invalid.json" conf/versions.json
if ./src/build/build.sh >"$work/log" 2>&1; then echo 'Invalid configuration accepted' >&2; exit 1; fi
find . -name Dockerfile -print0 | sort -z | xargs -0 sha256sum >"$work/after"
cmp "$work/before" "$work/after"
echo 'Dockerfile generator tests passed.'
