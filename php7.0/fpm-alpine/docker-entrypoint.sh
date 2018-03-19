#!/bin/bash

set -e

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
        if [ -n "$MYSQL_PORT_3306_TCP" ]; then
                if [ -z "$JOOMLA_DB_HOST" ]; then
                        JOOMLA_DB_HOST='mysql'
                else
                        echo >&2 "warning: both JOOMLA_DB_HOST and MYSQL_PORT_3306_TCP found"
                        echo >&2 "  Connecting to JOOMLA_DB_HOST ($JOOMLA_DB_HOST)"
                        echo >&2 "  instead of the linked mysql container"
                fi
        fi

        if [ -z "$JOOMLA_DB_HOST" ]; then
                echo >&2 "error: missing JOOMLA_DB_HOST and MYSQL_PORT_3306_TCP environment variables"
                echo >&2 "  Did you forget to --link some_mysql_container:mysql or set an external db"
                echo >&2 "  with -e JOOMLA_DB_HOST=hostname:port?"
                exit 1
        fi

        # If the DB user is 'root' then use the MySQL root password env var
        : ${JOOMLA_DB_USER:=root}
        if [ "$JOOMLA_DB_USER" = 'root' ]; then
                : ${JOOMLA_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}
        fi
        : ${JOOMLA_DB_NAME:=joomla}

        if [ -z "$JOOMLA_DB_PASSWORD" ] && [ "$JOOMLA_DB_PASSWORD_ALLOW_EMPTY" != 'yes' ]; then
                echo >&2 "error: missing required JOOMLA_DB_PASSWORD environment variable"
                echo >&2 "  Did you forget to -e JOOMLA_DB_PASSWORD=... ?"
                echo >&2
                echo >&2 "  (Also of interest might be JOOMLA_DB_USER and JOOMLA_DB_NAME.)"
                exit 1
        fi

        if ! [ -e index.php -a \( -e libraries/cms/version/version.php -o -e libraries/src/Version.php \) ]; then
                echo >&2 "Joomla not found in $(pwd) - copying now..."

                if [ "$(ls -A)" ]; then
                        echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
                        ( set -x; ls -A; sleep 10 )
                fi

                tar cf - --one-file-system -C /usr/src/joomla . | tar xf -

                if [ ! -e .htaccess ]; then
                        # NOTE: The "Indexes" option is disabled in the php:apache base image so remove it as we enable .htaccess
                        sed -r 's/^(Options -Indexes.*)$/#\1/' htaccess.txt > .htaccess
                        chown www-data:www-data .htaccess
                fi

                echo >&2 "Complete! Joomla has been successfully copied to $(pwd)"
        else
            # check if the extracted Joomla version from the Dockerfile
            # is newer than the one currently installed in /var/www/ volume
            # (e.g. if the Dockerfile was updated after the first install and no web-update was used)

            # only implemented here for Joomla >= 3.8.x
            # see https://docs.joomla.org/How_to_check_the_Joomla_version%3F#Other_Ways_6
            INSTALLED_VERSION_FILE='libraries/src/Version.php'
            NEW_VERSION_FILE='/usr/src/joomla/libraries/src/Version.php'

            if [ -e $INSTALLED_VERSION_FILE ] && [ -e $NEW_VERSION_FILE ]; then
                INSTALLED_MAJOR_VERSION=`grep -oP 'MAJOR_VERSION = \K(\d)' $INSTALLED_VERSION_FILE`
                INSTALLED_MINOR_VERSION=`grep -oP 'MINOR_VERSION = \K(\d)' $INSTALLED_VERSION_FILE`
                INSTALLED_PATCH_VERSION=`grep -oP 'PATCH_VERSION = \K(\d)' $INSTALLED_VERSION_FILE`
                INSTALLED_VERSION="${INSTALLED_MAJOR_VERSION}.${INSTALLED_MINOR_VERSION}.${INSTALLED_PATCH_VERSION}"

                NEW_MAJOR_VERSION=`grep -oP 'MAJOR_VERSION = \K(\d)' $NEW_VERSION_FILE`
                NEW_MINOR_VERSION=`grep -oP 'MINOR_VERSION = \K(\d)' $NEW_VERSION_FILE`
                NEW_PATCH_VERSION=`grep -oP 'PATCH_VERSION = \K(\d)' $NEW_VERSION_FILE`
                NEW_VERSION="${NEW_MAJOR_VERSION}.${NEW_MINOR_VERSION}.${NEW_PATCH_VERSION}"

                if [ $NEW_MAJOR_VERSION -ne $INSTALLED_MAJOR_VERSION ]; then
                    echo >&2 "Incompatible major versions: $INSTALLED_VERSION --> $NEW_VERSION - please consider a manual update!"
                elif [ $NEW_MINOR_VERSION -lt $INSTALLED_MINOR_VERSION ] || [ $NEW_PATCH_VERSION -lt $INSTALLED_PATCH_VERSION ]; then
                    echo >&2 "You are trying to downgrade: $INSTALLED_VERSION --> $NEW_VERSION - please consider updating your Dockerfile!"
                elif [ $NEW_MINOR_VERSION -gt $INSTALLED_MINOR_VERSION ] || [ $NEW_PATCH_VERSION -gt $INSTALLED_PATCH_VERSION ]; then
                    echo >&2 "Newer version of Joomla detected! Upgrading $INSTALLED_VERSION --> $NEW_VERSION ..."
                    echo >&2 "Press Ctrl+C now if this is an error!"
                    ( set -x; sleep 10 )

                    # OK, let's go!
                    echo >&2 "Copying new Joomla core files..."
                    tar cf - --one-file-system -C /usr/src/joomla . | tar xf - --overwrite
                    echo >&2 "Running Post-Manual Update Script..."
                    cp /postupdate.php administrator/
                    php administrator/postupdate.php
                    echo >&2 "Cleaning up..."
                    rm administrator/postupdate.php
                    rm -r installation
                else
                    # same versions - do nothing
                    true
                fi
            fi
        fi

        # Ensure the MySQL Database is created
        php /makedb.php "$JOOMLA_DB_HOST" "$JOOMLA_DB_USER" "$JOOMLA_DB_PASSWORD" "$JOOMLA_DB_NAME"

        echo >&2 "========================================================================"
        echo >&2
        echo >&2 "This server is now configured to run Joomla!"
        echo >&2 "You will need the following database information to install Joomla:"
        echo >&2 "Host Name: $JOOMLA_DB_HOST"
        echo >&2 "Database Name: $JOOMLA_DB_NAME"
        echo >&2 "Database Username: $JOOMLA_DB_USER"
        echo >&2 "Database Password: $JOOMLA_DB_PASSWORD"
        echo >&2
        echo >&2 "========================================================================"
fi

exec "$@"
