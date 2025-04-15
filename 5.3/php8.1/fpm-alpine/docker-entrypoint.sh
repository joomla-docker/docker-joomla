#!/bin/bash
set -e

# Load database password from file if specified
if [ -n "$JOOMLA_DB_PASSWORD_FILE" ] && [ -f "$JOOMLA_DB_PASSWORD_FILE" ]; then
    JOOMLA_DB_PASSWORD=$(cat "$JOOMLA_DB_PASSWORD_FILE")
fi

# Function to log messages
joomla_log() {
    local msg="$1"
    echo >&2 " $msg"
}

# Function to log info messages
joomla_log_info() {
    local msg="$1"
    echo >&2 "[INFO] $msg"
}

# Function to log warning messages
joomla_log_warning() {
    local msg="$1"
    echo >&2 "[WARNING] $msg"
}

# Function to log error messages
joomla_log_error() {
    local msg="$1"
    echo >&2 "[ERROR] $msg"
}

# Function to set a line
joomla_echo_line() {
    echo >&2 "========================================================================"
}

# Function to set a line at end
joomla_echo_line_start() {
    joomla_echo_line
    echo >&2
}

# Function to set a line at end
joomla_echo_line_end() {
    echo >&2
    joomla_echo_line
}

# Function to give final success message (1)
joomla_log_configured_success_message() {
    joomla_log "This server is now configured to run Joomla!"
}

# Function to give final success message (2)
joomla_log_success_and_need_db_message() {
    joomla_log_configured_success_message
    echo >&2
    joomla_log " NOTE: You will need your database server address, database name,"
    joomla_log "       and database user credentials to install Joomla."
}

# Function to validate URLs
joomla_validate_url() {
    if [[ $1 =~ ^http(s)?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate file path
joomla_validate_path() {
    if [[ -f $1 ]]; then
        return 0
    else
        return 1
    fi
}

# Function to split values by semicolon
joomla_get_array_by_semicolon() {
    local input=$1   # The input string to be split
    local -n arr=$2  # The array to store the split values (passed by reference)
    local old_IFS=$IFS  # Save the original IFS value
    # shellcheck disable=SC2034
    # passed by reference
    IFS=';' read -ra arr <<< "$input"  # Split the input by semicolon and store in array
    IFS=$old_IFS  # Restore the original IFS value
}

# Function to split values by colon to get host and port
joomla_get_host_port_by_colon() {
    local input=$1    # The input string to be split
    local -n hostname=$2  # The variable to store the hostname (passed by reference)
    local -n port=$3  # The variable to store the port (passed by reference)
    local old_IFS=$IFS  # Save the original IFS value
    # shellcheck disable=SC2034
    # passed by reference
    IFS=':' read -r hostname port <<< "$input"  # Split the input by colon and store in hostname and port
    IFS=$old_IFS  # Restore the original IFS value
}

# Function to install extension from URL
joomla_install_extension_via_url() {
    local url=$1
    if joomla_validate_url "$url"; then
        if php cli/joomla.php extension:install --url "$url" --no-interaction; then
            joomla_log_info "Successfully installed $url"
        else
            joomla_log_error "Failed to install $url"
        fi
    else
        joomla_log_error "Invalid URL: $url"
    fi
}

# Function to install extension from path
joomla_install_extension_via_path() {
    local path=$1
    if joomla_validate_path "$path"; then
        if php cli/joomla.php extension:install --path "$path" --no-interaction; then
            joomla_log_info "Successfully installed $path"
        else
            joomla_log_error "Failed to install $path"
        fi
    else
        joomla_log_error "Invalid Path: $path"
    fi
}

# Function to validate necessary environment variables
joomla_validate_vars() {
    # Basic email regex for validation
    local email_regex="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"

    # Check if JOOMLA_SITE_NAME is longer than 2 characters
    if [[ "${#JOOMLA_SITE_NAME}" -le 2 ]]; then
        joomla_log_error "JOOMLA_SITE_NAME must be longer than 2 characters!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_USER is longer than 2 characters
    if [[ "${#JOOMLA_ADMIN_USER}" -le 2 ]]; then
        joomla_log_error "JOOMLA_ADMIN_USER must be longer than 2 characters!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_USERNAME has no spaces, and is only alphabetical
    if [[ "${JOOMLA_ADMIN_USERNAME}" =~ [^a-zA-Z] ]]; then
        joomla_log_error "JOOMLA_ADMIN_USERNAME must contain no spaces and be only alphabetical!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_PASSWORD is longer than 12 characters
    if [[ "${#JOOMLA_ADMIN_PASSWORD}" -le 12 ]]; then
        joomla_log_error "JOOMLA_ADMIN_PASSWORD must be longer than 12 characters!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_EMAIL is a valid email
    if [[ ! "${JOOMLA_ADMIN_EMAIL}" =~ $email_regex ]]; then
        joomla_log_error "JOOMLA_ADMIN_EMAIL must be a valid email address!"
        return 1
    fi

    return 0
}

# Function to check if auto deploy can be done
joomla_can_auto_deploy() {
    if [[ -n "${JOOMLA_SITE_NAME}" && -n "${JOOMLA_ADMIN_USER}" &&
          -n "${JOOMLA_ADMIN_USERNAME}" && -n "${JOOMLA_ADMIN_PASSWORD}" &&
          -n "${JOOMLA_ADMIN_EMAIL}" ]]; then

        if joomla_validate_vars; then
            return 0
        fi
    fi

    return 1
}

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
    uid="$(id -u)"
    gid="$(id -g)"
    if [ "$uid" = '0' ]; then
        case "$1" in
        apache2*)
            user="${APACHE_RUN_USER:-www-data}"
            group="${APACHE_RUN_GROUP:-www-data}"

            # strip off any '#' symbol ('#1000' is valid syntax for Apache)
            pound='#'
            user="${user#"$pound"}"
            group="${group#"$pound"}"

            # set user if not exist
            if ! id "$user" &>/dev/null; then
                # get the user name
                : "${USER_NAME:=www-data}"
                # change the user name
                [[ "$USER_NAME" != "www-data" ]] &&
                    usermod -l "$USER_NAME" www-data &&
                    groupmod -n "$USER_NAME" www-data
                # update the user ID
                groupmod -o -g "$user" "$USER_NAME"
                # update the user-group ID
                usermod -o -u "$group" "$USER_NAME"
            fi
            ;;
        *) # php-fpm
            user='www-data'
            group='www-data'
            ;;
        esac
    else
        user="$uid"
        group="$gid"
    fi

    # start Joomla message block
    joomla_echo_line_start
    if [ -n "$MYSQL_PORT_3306_TCP" ]; then
        if [ -z "$JOOMLA_DB_HOST" ]; then
            JOOMLA_DB_HOST='mysql'
        else
            joomla_log_warning "both JOOMLA_DB_HOST and MYSQL_PORT_3306_TCP found"
            joomla_log "Connecting to JOOMLA_DB_HOST ($JOOMLA_DB_HOST)"
            joomla_log "instead of the linked mysql container"
        fi
    fi

    if [ -z "$JOOMLA_DB_HOST" ]; then
        joomla_log_error "Missing JOOMLA_DB_HOST and MYSQL_PORT_3306_TCP environment variables."
        joomla_log "Did you forget to --link some_mysql_container:mysql or set an external db"
        joomla_log "with -e JOOMLA_DB_HOST=hostname:port?"
        # end Joomla message block
        joomla_echo_line_end
        exit 1
    fi

    # If the DB user is 'root' then use the MySQL root password env var
    : "${JOOMLA_DB_USER:=root}"
    if [ "$JOOMLA_DB_USER" = 'root' ]; then
        : "${JOOMLA_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}"
    fi
    : "${JOOMLA_DB_NAME:=joomla}"

    if [ -z "$JOOMLA_DB_PASSWORD" ] && [ "$JOOMLA_DB_PASSWORD_ALLOW_EMPTY" != 'yes' ]; then
        joomla_log_error "Missing required JOOMLA_DB_PASSWORD environment variable."
        joomla_log "Did you forget to -e JOOMLA_DB_PASSWORD=... ?"
        joomla_log "(Also of interest might be JOOMLA_DB_USER and JOOMLA_DB_NAME.)"
        # end Joomla message block
        joomla_echo_line_end
        exit 1
    fi

    if [ ! -e index.php ] && [ ! -e libraries/src/Version.php ]; then
        # if the directory exists and Joomla doesn't appear to be installed AND the permissions of it are root:root, let's chown it (likely a Docker-created directory)
        if [ "$uid" = '0' ] && [ "$(stat -c '%u:%g' .)" = '0:0' ]; then
            chown "$user:$group" .
        fi

        joomla_log_info "Joomla not found in $PWD - copying now..."
        if [ "$(ls -A)" ]; then
            joomla_log_warning "$PWD is not empty - press Ctrl+C now if this is an error!"
            (
                set -x
                ls -A
                sleep 10
            )
        fi
        # use full commands
        # for clearer intent
        sourceTarArgs=(
            --create
            --file -
            --directory /usr/src/joomla
            --one-file-system
            --owner "$user" --group "$group"
        )
        targetTarArgs=(
            --extract
            --file -
        )
        if [ "$uid" != '0' ]; then
            # avoid "tar: .: Cannot utime: Operation not permitted" and "tar: .: Cannot change mode to rwxr-xr-x: Operation not permitted"
            targetTarArgs+=(--no-overwrite-dir)
        fi

        tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"

        if [ ! -e .htaccess ]; then
            # NOTE: The "Indexes" option is disabled in the php:apache base image so remove it as we enable .htaccess
            sed -r 's/^(Options -Indexes.*)$/#\1/' htaccess.txt > .htaccess
            chown "$user:$group" .htaccess
        fi

        joomla_log "Complete! Joomla has been successfully copied to $PWD"
    fi

    # Ensure the MySQL Database is created
    php /makedb.php "$JOOMLA_DB_HOST" "$JOOMLA_DB_USER" "$JOOMLA_DB_PASSWORD" "$JOOMLA_DB_NAME" "${JOOMLA_DB_TYPE:-mysqli}"

    # if the (installation) directory exists and we can auto deploy
    if [ -d installation ] && [ -e installation/joomla.php ] && joomla_can_auto_deploy; then
        # use full commands
        # for clearer intent
        installJoomlaArgs=(
            --site-name="${JOOMLA_SITE_NAME}"
            --admin-email="${JOOMLA_ADMIN_EMAIL}"
            --admin-username="${JOOMLA_ADMIN_USERNAME}"
            --admin-user="${JOOMLA_ADMIN_USER}"
            --admin-password="${JOOMLA_ADMIN_PASSWORD}"
            --db-type="${JOOMLA_DB_TYPE:-mysqli}"
            --db-host="${JOOMLA_DB_HOST}"
            --db-name="${JOOMLA_DB_NAME}"
            --db-pass="${JOOMLA_DB_PASSWORD}"
            --db-user="${JOOMLA_DB_USER}"
            --db-prefix="${JOOMLA_DB_PREFIX:-joom_}"
            --db-encryption=0
        )

        # Run the auto deploy (install)
        if php installation/joomla.php install "${installJoomlaArgs[@]}"; then
            # The PHP command succeeded (so we remove the installation folder)
            rm -rf installation

            joomla_log_configured_success_message

            # Install any extensions found in the extensions urls env
            if [[ -n "${JOOMLA_EXTENSIONS_URLS}" && "${#JOOMLA_EXTENSIONS_URLS}" -gt 2 ]]; then
                joomla_get_array_by_semicolon "$JOOMLA_EXTENSIONS_URLS" J_E_URLS
                for extension_url in "${J_E_URLS[@]}"; do
                    joomla_install_extension_via_url "$extension_url"
                done
            fi

            # Install any extensions found in the extensions paths env
            if [[ -n "${JOOMLA_EXTENSIONS_PATHS}" && "${#JOOMLA_EXTENSIONS_PATHS}" -gt 2 ]]; then
                joomla_get_array_by_semicolon "$JOOMLA_EXTENSIONS_PATHS" J_E_PATHS
                for extension_path in "${J_E_PATHS[@]}"; do
                    joomla_install_extension_via_path "$extension_path"
                done
            fi

            if [[ -n "${JOOMLA_SMTP_HOST}" && "${JOOMLA_SMTP_HOST}" == *:* ]]; then
                joomla_get_host_port_by_colon "$JOOMLA_SMTP_HOST" JOOMLA_SMTP_HOST JOOMLA_SMTP_HOST_PORT
            fi

            # add the smtp host to configuration file
            if [[ -n "${JOOMLA_SMTP_HOST}" && "${#JOOMLA_SMTP_HOST}" -gt 2 ]]; then
                chmod +w configuration.php
                sed -i "s/public \$mailer = 'mail';/public \$mailer = 'smtp';/g" configuration.php
                sed -i "s/public \$smtphost = 'localhost';/public \$smtphost = '${JOOMLA_SMTP_HOST}';/g" configuration.php
            fi

            # add the smtp port to configuration file
            if [[ -n "${JOOMLA_SMTP_HOST_PORT}" ]]; then
                sed -i "s/public \$smtpport = 25;/public \$smtpport = ${JOOMLA_SMTP_HOST_PORT};/g" configuration.php
            fi

            # fix the configuration.php ownership
            if [ "$uid" = '0' ] && [ "$(stat -c '%u:%g' configuration.php)" != "$user:$group" ]; then
                # Set the correct ownership of all files touched during installation
                if ! chown -R "$user:$group" .; then
                    joomla_log_error "Ownership of all files touched during installation failed to be corrected."
                fi
                # Set configuration to correct permissions
                if ! chmod 444 configuration.php; then
                    joomla_log_error "Permissions of configuration.php failed to be corrected."
                fi
            fi
        else
            joomla_log_success_and_need_db_message
        fi
    else
        joomla_log_success_and_need_db_message
    fi
    # end Joomla message block
    joomla_echo_line_end
fi

exec "$@"
