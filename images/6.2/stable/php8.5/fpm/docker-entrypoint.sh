#!/bin/bash
set -euo pipefail

# Fixed image source; runtime site files are kept in the webroot.
joomla_source=/usr/src/joomla

joomla_log() {
    printf ' %s\n' "$1" >&2
}

joomla_log_info() {
    printf '[INFO] %s\n' "$1" >&2
}

joomla_log_warning() {
    printf '[WARNING] %s\n' "$1" >&2
}

joomla_log_error() {
    printf '[ERROR] %s\n' "$1" >&2
}

joomla_die() {
    joomla_log_error "$1"
    exit 1
}

joomla_echo_line() {
    printf '%s\n' '========================================================================' >&2
}

joomla_echo_line_start() {
    joomla_echo_line
    printf '\n' >&2
}

joomla_echo_line_end() {
    printf '\n' >&2
    joomla_echo_line
}

joomla_log_configured_success_message() {
    joomla_log 'This server is now configured to run Joomla!'
}

joomla_log_success_and_need_db_message() {
    joomla_log 'Joomla files are ready. Complete installation in the browser.'
    joomla_log 'You will need your database server address, database name and credentials.'
}

# Docker-style secret files. Bash command substitution removes trailing newlines.
joomla_file_env() {
    local name="$1" file_name="${1}_FILE" value
    if [[ ${!name+x} && ${!file_name+x} ]]; then
        joomla_die "Set either $name or $file_name, not both."
    fi
    if [[ ${!file_name+x} ]]; then
        [[ -n ${!file_name} && -f ${!file_name} && -r ${!file_name} ]] ||
            joomla_die "$file_name must name a readable regular file."
        value="$(< "${!file_name}")"
        printf -v "$name" '%s' "$value"
        export "${name?}"
    fi
    unset "$file_name"
}

joomla_validate_url() {
    # Allow local registries, IP addresses and ports. Joomla handles the URL.
    [[ $1 == https://?* || $1 == http://?* ]] && [[ $1 != *[[:space:]]* ]]
}

joomla_validate_path() {
    [[ -f $1 && -r $1 ]]
}

joomla_get_array_by_semicolon() {
    local input="$1"
    local -n result_array="$2"
    [[ $input != *$'\n'* && $input != *$'\r'* ]] ||
        joomla_die 'Post-install lists must be single-line, semicolon-separated values.'
    # The assignment applies to read only; the caller's IFS is unchanged.
    # shellcheck disable=SC2034 # The nameref writes the caller's array.
    IFS=';' read -r -a result_array <<< "$input"
}

joomla_run_cli() {
    local status
    (($#)) || joomla_die 'No Joomla CLI command was provided.'
    # Native command output remains visible; arguments may contain secrets.
    if php "$JOOMLA_WEBROOT/cli/joomla.php" --no-interaction "$@"; then
        joomla_log_info 'Joomla CLI command completed successfully.'
    else
        status=$?
        joomla_log_error "Joomla CLI command failed (exit $status)."
        return "$status"
    fi
}

joomla_run_cli_string() {
    local command="$1"
    local -a arguments=()
    IFS=$' \t' read -r -a arguments <<< "$command"
    ((${#arguments[@]})) || return 0
    # Whitespace-separated arguments; no shell quoting, substitutions or eval.
    joomla_run_cli "${arguments[@]}"
}

joomla_install_extension_via_url() {
    joomla_validate_url "$1" || joomla_die 'An extension URL must use HTTP or HTTPS and contain no whitespace.'
    joomla_run_cli extension:install --url "$1"
}

joomla_install_extension_via_path() {
    joomla_validate_path "$1" || joomla_die 'An extension package must be a readable regular file.'
    joomla_run_cli extension:install --path "$1"
}

# Let Joomla validate account names, password policy and email addresses.
# The entrypoint only checks whether automatic installation was fully requested.
joomla_validate_vars() {
    local name
    for name in JOOMLA_SITE_NAME JOOMLA_ADMIN_USER JOOMLA_ADMIN_USERNAME JOOMLA_ADMIN_PASSWORD JOOMLA_ADMIN_EMAIL; do
        [[ -n ${!name:-} ]] || joomla_die "Automatic installation requires a nonempty $name."
    done
}

joomla_can_auto_deploy() {
    local name supplied=false
    for name in JOOMLA_SITE_NAME JOOMLA_ADMIN_USER JOOMLA_ADMIN_USERNAME JOOMLA_ADMIN_PASSWORD JOOMLA_ADMIN_EMAIL; do
        if [[ ${!name+x} ]]; then
            supplied=true
        fi
    done
    [[ $supplied == true ]] || return 1
    joomla_validate_vars
}

# Resolve identities without changing accounts or assuming UID equals GID.
joomla_resolve_uid() {
    local identity="${1#\#}"
    if [[ $identity =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$identity"
    else
        id -u "$identity" || return 1
    fi
}

joomla_resolve_gid() {
    local identity="${1#\#}" entry=''
    if [[ $identity =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$identity"
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        entry="$(getent group "$identity" || true)"
        if [[ -n $entry ]]; then
            IFS=: read -r _ _ identity _ <<< "$entry"
            printf '%s\n' "$identity"
            return 0
        fi
    fi
    entry="$(awk -F: -v name="$identity" '$1 == name { print $3; exit }' /etc/group)"
    [[ -n $entry ]] || return 1
    printf '%s\n' "$entry"
}

joomla_resolve_runtime_identity() {
    local raw_user=www-data raw_group=www-data
    uid="$(id -u)"
    gid="$(id -g)"
    user="$uid"
    group="$gid"
    [[ $uid == 0 ]] || return 0
    if [[ $1 == apache2* ]]; then
        raw_user="${APACHE_RUN_USER:-www-data}"
        raw_group="${APACHE_RUN_GROUP:-www-data}"
    fi
    user="$(joomla_resolve_uid "$raw_user")" || joomla_die 'Cannot resolve the runtime user.'
    group="$(joomla_resolve_gid "$raw_group")" || joomla_die 'Cannot resolve the runtime group.'
    [[ $user =~ ^[0-9]+$ && $group =~ ^[0-9]+$ ]] || joomla_die 'Runtime UID and GID must be numeric.'
    [[ ! $user =~ ^0+$ ]] || joomla_die 'The Joomla worker user must not be root.'
    if [[ $1 == apache2* ]]; then
        # Apache requires a leading hash for numeric User/Group directives.
        export APACHE_RUN_USER="#$user" APACHE_RUN_GROUP="#$group"
    fi
}

joomla_prepare_environment() {
    joomla_file_env JOOMLA_DB_PASSWORD
    joomla_file_env JOOMLA_ADMIN_PASSWORD
    if [[ -n ${MYSQL_PORT_3306_TCP:-} ]]; then
        if [[ -z ${JOOMLA_DB_HOST:-} ]]; then
            JOOMLA_DB_HOST=mysql
        else
            joomla_log_warning 'Both database host and legacy MySQL link settings were found; using JOOMLA_DB_HOST.'
        fi
    fi
    : "${JOOMLA_DB_USER:=root}"
    : "${JOOMLA_DB_NAME:=joomla}"
    : "${JOOMLA_DB_TYPE:=mysqli}"
    if [[ $JOOMLA_DB_USER == root && ! ${JOOMLA_DB_PASSWORD+x} ]]; then
        JOOMLA_DB_PASSWORD="${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}"
    fi
    : "${JOOMLA_DB_PASSWORD:=}"
    [[ -n ${JOOMLA_DB_HOST:-} ]] || joomla_die 'Initialization requires JOOMLA_DB_HOST or a legacy MySQL link.'
    [[ -n $JOOMLA_DB_PASSWORD || ${JOOMLA_DB_PASSWORD_ALLOW_EMPTY:-} == yes ]] ||
        joomla_die 'Set JOOMLA_DB_PASSWORD[_FILE], or explicitly set JOOMLA_DB_PASSWORD_ALLOW_EMPTY=yes.'
    [[ $JOOMLA_DB_TYPE == mysqli || $JOOMLA_DB_TYPE == pgsql ]] ||
        joomla_die 'JOOMLA_DB_TYPE must be mysqli or pgsql.'
}

joomla_copy_files() {
    local -a source_args=(--create --file - --directory "$joomla_source" --one-file-system)
    local -a target_args=(--extract --file - --no-overwrite-dir)
    if [[ $uid == 0 ]]; then
        source_args+=(--owner "$user" --group "$group")
        if [[ $(stat -c '%u:%g' .) == 0:0 ]]; then
            chown "$user:$group" .
        fi
    else
        target_args+=(--no-same-owner)
    fi
    joomla_log_info "Copying Joomla into $JOOMLA_WEBROOT."
    tar "${source_args[@]}" . | tar "${target_args[@]}"
    if [[ ! -e .htaccess && ! -L .htaccess && -f htaccess.txt ]]; then
        # The PHP Apache image disables Indexes, so preserve the existing adjustment.
        sed -E 's/^(Options -Indexes.*)$/#\1/' htaccess.txt > .htaccess
    fi
}

# Build validated native config:set arguments before mutating the installation.
joomla_prepare_smtp() {
    local host="${JOOMLA_SMTP_HOST:-}" port="${JOOMLA_SMTP_HOST_PORT:-}" embedded_port=''
    joomla_smtp_args=()
    if [[ -n $host ]]; then
        if [[ $host =~ ^(\[[0-9A-Fa-f:.%[:alnum:]_-]+\]):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            embedded_port="${BASH_REMATCH[2]}"
        elif [[ $host =~ ^([^:]+):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            embedded_port="${BASH_REMATCH[2]}"
        fi
        # '=' is excluded because Joomla splits configuration arguments at it.
        [[ $host =~ ^[[:alnum:]_.-]+$ || $host =~ ^\[[0-9A-Fa-f:.%[:alnum:]_-]+\]$ ]] ||
            joomla_die 'Invalid SMTP host; use a hostname, IPv4 or bracketed IPv6 address.'
        joomla_smtp_args+=('mailer=smtp' "smtphost=$host")
    fi
    if [[ -n $port && -n $embedded_port && $port != "$embedded_port" ]]; then
        joomla_die 'SMTP port settings conflict.'
    fi
    port="${port:-$embedded_port}"
    if [[ -n $port ]]; then
        if [[ ! $port =~ ^[0-9]{1,5}$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
            joomla_die 'SMTP port must be between 1 and 65535.'
        fi
        joomla_smtp_args+=("smtpport=$((10#$port))")
    fi
}

joomla_post_install() {
    local entry
    local -a entries=()
    joomla_get_array_by_semicolon "${JOOMLA_EXTENSIONS_URLS:-}" entries
    for entry in "${entries[@]}"; do
        [[ -n $entry ]] || continue
        joomla_install_extension_via_url "$entry"
    done
    joomla_get_array_by_semicolon "${JOOMLA_EXTENSIONS_PATHS:-}" entries
    for entry in "${entries[@]}"; do
        [[ -n $entry ]] || continue
        joomla_install_extension_via_path "$entry"
    done
    if ((${#joomla_smtp_args[@]})); then
        joomla_run_cli config:set "${joomla_smtp_args[@]}"
    fi
    joomla_get_array_by_semicolon "${JOOMLA_CLI_COMMANDS:-}" entries
    for entry in "${entries[@]}"; do
        joomla_run_cli_string "$entry"
    done
}

joomla_install() {
    local status
    local -a install_args=(
        --no-interaction
        "--site-name=$JOOMLA_SITE_NAME"
        "--admin-email=$JOOMLA_ADMIN_EMAIL"
        "--admin-username=$JOOMLA_ADMIN_USERNAME"
        "--admin-user=$JOOMLA_ADMIN_USER"
        "--admin-password=$JOOMLA_ADMIN_PASSWORD"
        "--db-type=$JOOMLA_DB_TYPE"
        "--db-host=$JOOMLA_DB_HOST"
        "--db-name=$JOOMLA_DB_NAME"
        "--db-pass=$JOOMLA_DB_PASSWORD"
        "--db-user=$JOOMLA_DB_USER"
        "--db-prefix=${JOOMLA_DB_PREFIX:-joom_}"
        --db-encryption=0
    )
    if php "$JOOMLA_WEBROOT/installation/joomla.php" install "${install_args[@]}"; then
        [[ -s configuration.php && ! -L configuration.php ]] ||
            joomla_die 'The installer returned success without a nonempty configuration.php.'
        rm -rf -- installation
    else
        status=$?
        joomla_log_error "Automatic Joomla installation failed (exit $status)."
        return "$status"
    fi
    joomla_post_install
}

# Bootstrap keeps the current image's PHP execution user. Repair its output
# once, including on failure, without walking a persisted site on every restart.
joomla_finalize_webroot() {
    [[ ${joomla_needs_finalization:-false} == true ]] || return 0
    joomla_needs_finalization=false
    if [[ $uid == 0 ]] && ! chown -R -h "$user:$group" "$JOOMLA_WEBROOT"; then
        joomla_log_error 'Failed to correct ownership after initialization.'
        return 1
    fi
    if [[ -L configuration.php ]]; then
        joomla_log_error 'Refusing to change permissions through a configuration.php symlink.'
        return 1
    fi
    if [[ -f configuration.php ]] && ! chmod 0444 configuration.php; then
        joomla_log_error 'Failed to restore configuration.php permissions.'
        return 1
    fi
}

joomla_initialization_exit() {
    local status=$?
    trap - EXIT
    if ! joomla_finalize_webroot; then
        [[ $status != 0 ]] || status=1
    fi
    [[ $status != 0 ]] || status=1
    joomla_log_error "Initialization did not complete (exit $status); server startup is blocked."
    joomla_log_error "Inspect the logs and repair or restore the site and database before removing $joomla_marker."
    exit "$status"
}

joomla_initialize() {
    local auto_install=false copy_source=false name value status
    # shellcheck disable=SC2034 # Receives validated values through a nameref.
    local -a checked_entries=()
    joomla_prepare_environment
    if joomla_can_auto_deploy; then
        auto_install=true
    fi
    for name in JOOMLA_EXTENSIONS_URLS JOOMLA_EXTENSIONS_PATHS JOOMLA_CLI_COMMANDS; do
        value="${!name:-}"
        joomla_get_array_by_semicolon "$value" checked_entries
        if [[ -n $value && $auto_install == false ]]; then
            joomla_die 'Post-install commands require complete automatic-installation credentials.'
        fi
    done
    joomla_prepare_smtp
    if ((${#joomla_smtp_args[@]})) && [[ $auto_install == false ]]; then
        joomla_die 'SMTP setup requires complete automatic-installation credentials.'
    fi
    if [[ -f index.php && -f libraries/src/Version.php && -f installation/joomla.php ]]; then
        : # An existing uninstalled package can be initialized without recopying it.
    elif [[ -n $(find . -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        joomla_die 'The webroot is nonempty but is not a complete Joomla installation package; refusing to overwrite it.'
    else
        [[ -f $joomla_source/index.php && -f $joomla_source/libraries/src/Version.php && -f $joomla_source/installation/joomla.php ]] ||
            joomla_die 'The image does not contain a complete Joomla source package.'
        copy_source=true
    fi

    # Database readiness is retryable and does not modify the Joomla tree.
    # Do this before arming the marker so a temporary DB outage can recover.
    if php /makedb.php "$JOOMLA_DB_HOST" "$JOOMLA_DB_USER" "$JOOMLA_DB_PASSWORD" "$JOOMLA_DB_NAME" "$JOOMLA_DB_TYPE"; then
        :
    else
        status=$?
        joomla_log_error "Database initialization failed (exit $status)."
        return "$status"
    fi

    # One persistent marker prevents a failed installer that created configuration
    # from being mistaken for a completed site. It is not rollback or hook replay.
    mkdir -- "$joomla_marker" || joomla_die 'Another initializer is active or initialization is incomplete.'
    joomla_needs_finalization=true
    trap joomla_initialization_exit EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    if [[ $copy_source == true ]]; then
        joomla_copy_files
    fi
    if [[ $auto_install == true ]]; then
        joomla_install
    fi
    joomla_finalize_webroot
    rmdir -- "$joomla_marker"
    trap - EXIT TERM INT
    if [[ $auto_install == true ]]; then
        joomla_log_configured_success_message
    else
        joomla_log_success_and_need_db_message
    fi
}

joomla_main() {
    local argument
    (($#)) || joomla_die 'No startup command was provided.'
    case "$1" in
        apache2* | php-fpm) ;;
        *) exec "$@" ;;
    esac
    for argument in "${@:2}"; do
        case "$argument" in
            -h | --help | -v | -V | --version | -t | -T) exec "$@" ;;
        esac
    done
    # Preserve the official image WORKDIR and Docker --workdir behavior.
    : "${JOOMLA_WEBROOT:=$PWD}"
    cd -- "$JOOMLA_WEBROOT"
    JOOMLA_WEBROOT="$(pwd -P)"
    export JOOMLA_WEBROOT
    joomla_marker="$JOOMLA_WEBROOT/.joomla-initializing"
    [[ ! -e $joomla_marker && ! -L $joomla_marker ]] ||
        joomla_die "Initialization is incomplete or another initializer is active. Inspect the logs and repair the site before removing $joomla_marker."
    joomla_resolve_runtime_identity "$1"
    joomla_echo_line_start
    if [[ -s configuration.php ]]; then
        [[ -f index.php && -f libraries/src/Version.php ]] || joomla_die 'The configured Joomla tree is incomplete.'
        joomla_log_info 'Existing Joomla installation found; skipping initialization.'
        # Future opt-in update handling belongs here, before server startup.
    else
        [[ ! -e configuration.php && ! -L configuration.php ]] ||
            joomla_die 'An empty or invalid configuration.php exists; inspect it before installation.'
        joomla_initialize
    fi
    joomla_echo_line_end
    exec "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    joomla_main "$@"
fi
