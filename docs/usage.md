# Using the images

Pull the Joomla Docker Official Image from
[Docker Hub](https://hub.docker.com/_/joomla). It contains Joomla, PHP and the
selected server variant. You only need Docker and, for the example below,
Docker Compose. No checkout of this repository is needed.

Normal images provide the application runtime. Published development images
add debugging and project tools; see [Development images](development.md).

## Choose a published tag

Use the supported tags on [Docker Hub](https://hub.docker.com/_/joomla) to choose
the Joomla release, PHP version and server variant for your site. The image
reference is `joomla:` followed by that tag. For the current default stable
Apache image:

```bash
docker pull joomla:latest
```

`latest` follows the default stable release. Choose a published tag containing
the Joomla version, PHP version and variant when you need to control upgrades.
Use alpha, beta or RC tags only for testing, and only when those tags are listed
on Docker Hub. The [release guide](releases.md) explains the naming conventions;
the published tag list determines what can be pulled.

| Variant | How to serve requests |
| --- | --- |
| `apache` | Includes Apache; publish its HTTP port `80` |
| `fpm` | Runs PHP-FPM on FastCGI port `9000`; provide a separate web server |
| `fpm-alpine` | Runs PHP-FPM using the Alpine-based PHP image; provide a separate web server |

FPM does not serve HTTP directly. Its front-end server must route PHP requests
using the same document-root paths and have access to the Joomla files required
to serve static content. The complete Compose example below uses Apache.

## Run with Docker Compose

Create a directory for your site. Save a file named `.env` there with these
settings, replacing the example password with your own strong password:

```dotenv
JOOMLA_IMAGE=joomla:latest
MARIADB_IMAGE=mariadb:lts
JOOMLA_DB_PASSWORD='replace-with-your-own-strong-password'
```

These aliases select the default stable Joomla image and the current
[MariaDB long-term-support image](https://hub.docker.com/_/mariadb). For a
long-lived site, choose published version tags compatible with your Joomla
release so you control when either service changes versions.

Save this `compose.yaml` alongside `.env`:

```yaml
services:
  database:
    image: ${MARIADB_IMAGE:-mariadb:lts}
    environment:
      MARIADB_RANDOM_ROOT_PASSWORD: "1"
      MARIADB_DATABASE: joomla
      MARIADB_USER: joomla
      MARIADB_PASSWORD: ${JOOMLA_DB_PASSWORD:?Set JOOMLA_DB_PASSWORD}
    volumes:
      - database:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 24
    restart: unless-stopped

  joomla:
    image: ${JOOMLA_IMAGE:-joomla:latest}
    ports:
      - "127.0.0.1:8080:80"
    environment:
      JOOMLA_DB_HOST: database
      JOOMLA_DB_NAME: joomla
      JOOMLA_DB_USER: joomla
      JOOMLA_DB_PASSWORD: ${JOOMLA_DB_PASSWORD:?Set JOOMLA_DB_PASSWORD}
    volumes:
      - joomla:/var/www/html
    depends_on:
      database:
        condition: service_healthy
    restart: unless-stopped

volumes:
  database:
  joomla:
```

Start it from the directory containing that file:

```bash
docker compose pull
docker compose up -d
docker compose logs -f joomla
```

Open `http://localhost:8080` to complete the Joomla browser installer. Use the
same database host, name, user and password as the Compose configuration. The
HTTP port is bound to the local machine for this development example.

For a persistent deployment, supply the same values through your normal Compose
environment or secrets mechanism. Changing a database image's password variable
does not change an existing database user's password in an initialized volume.
Keep deployment credentials out of version control.

## What the entrypoint does

The container entrypoint runs the Joomla startup preparation when the command
starts with `apache2` or is exactly `php-fpm`. Commands such as `php --version`
run directly after entrypoint initialization without copying or installing Joomla.
Before either path, it applies the optional [PHP hardening profile](#security-hardening).

For a normal server start, it:

1. Reads database settings and, when configured, the password file.
2. Copies the packaged Joomla files from `/usr/src/joomla` into the working
   directory when neither `index.php` nor `libraries/src/Version.php` exists.
3. Connects to the configured database server and ensures the database exists.
4. If the Joomla installer is present and all automatic-installation settings
   pass validation, runs that installer and removes its installation directory.
5. After successful automatic installation, processes extension installation,
   SMTP settings and the configured Joomla CLI commands.
6. Starts the requested Apache or FPM command with `exec`.

The database server is external to the Joomla container. The database account
must have the permissions required by the database helper and Joomla. The
helper currently supports `mysqli` and `pgsql`; the Compose example uses
`mysqli`, which is also the default.

## Runtime environment

| Variable | Behaviour |
| --- | --- |
| `JOOMLA_SECURITY_HARDENED` | Opt in to the PHP hardening profile with `true` or `1`; disabled by default; see [Security hardening](#security-hardening) |
| `JOOMLA_DB_HOST` | Database hostname, optionally followed by `:port`; required for normal server startup |
| `JOOMLA_DB_NAME` | Database name; defaults to `joomla` |
| `JOOMLA_DB_USER` | Database user; defaults to `root`, but deployments should supply their application user |
| `JOOMLA_DB_PASSWORD` | Database password |
| `JOOMLA_DB_PASSWORD_FILE` | Read the database password from this file when the variable is set and the file exists |
| `JOOMLA_DB_PASSWORD_ALLOW_EMPTY` | Only the value `yes` allows an empty password |
| `JOOMLA_DB_TYPE` | `mysqli` or `pgsql`; defaults to `mysqli` |
| `JOOMLA_DB_PREFIX` | Table prefix for automatic installation; defaults to `joom_` |
| `JOOMLA_SITE_NAME` | Site name for automatic installation; longer than two characters |
| `JOOMLA_ADMIN_USER` | Administrator display name; longer than two characters |
| `JOOMLA_ADMIN_USERNAME` | Administrator login name; nonempty and alphabetic only |
| `JOOMLA_ADMIN_PASSWORD` | Administrator password; longer than twelve characters |
| `JOOMLA_ADMIN_EMAIL` | Administrator email address, validated by the entrypoint |
| `JOOMLA_EXTENSIONS_URLS` | Semicolon-separated extension package URLs, processed after successful automatic installation |
| `JOOMLA_EXTENSIONS_PATHS` | Semicolon-separated extension package paths inside the container, processed after successful automatic installation |
| `JOOMLA_SMTP_HOST` | SMTP hostname, optionally with `:port`, applied after successful automatic installation |
| `JOOMLA_SMTP_HOST_PORT` | SMTP port applied after successful automatic installation |
| `JOOMLA_CLI_COMMANDS` | Single-line, semicolon-separated Joomla CLI commands run after successful automatic installation |

Automatic installation requires all five site/administrator variables. Without
them, Joomla's browser installer remains available. Changing them on an already
installed site does not rename the site, reset the administrator or reinstall
Joomla. The SMTP variables configure host and port only; configure SMTP
credentials and other mail settings through Joomla as needed.

The configured image also supplies `JOOMLA_INSTALLATION_DISABLE_LOCALHOST_CHECK`
as an environment value. This repository's shell entrypoint does not read it;
it is passed through to the Joomla processes in the container. Image metadata
such as `JOOMLA_VERSION` describes the packaged release, not necessarily the
version currently installed in a persistent site volume.

For file-based database credentials, mount a readable secret and set
`JOOMLA_DB_PASSWORD_FILE` to its container path. That variable is supported for
the database password; it is not a general `_FILE` mechanism for every setting.

## Security hardening

All images set `expose_php=Off` to suppress PHP's identifying HTTP header.
This is a small information-disclosure reduction. The additional PHP profile
below remains opt-in and applies equally to Apache, FPM and FPM-Alpine images.

Set `JOOMLA_SECURITY_HARDENED: "true"` in the Joomla service's existing environment
mapping to enable the optional PHP hardening profile:

```yaml
environment:
  JOOMLA_SECURITY_HARDENED: "true"
```

Keep the service's other environment settings. Configure HTTPS for the site
before enabling this profile: its secure session cookies prevent normal browser
installation and login over plain HTTP. The profile does not configure TLS,
redirect HTTP requests or change Joomla's Global Configuration.

After adding or changing the setting, recreate the Joomla container:

```bash
docker compose up -d --no-deps --force-recreate joomla
```

`true` and `1` enable hardening; `false`, `0`, an empty value or an unset variable
disable it. The words `true` and `false` are case-insensitive. Other values stop
startup with an error so a misspelled setting cannot silently disable hardening.
A container restart alone does not apply changes to its Compose environment.

The settings live in the `config` map of the [PHP JSON profiles](../conf/php/).
The normal build writes `/usr/local/etc/php/joomla-hardening.ini` outside
`conf.d`, where PHP does not load it. This is a retained source profile, not an
enabled configuration file. Each new image starts with this source present and
no active copy. On every entrypoint invocation:

- When enabled, the entrypoint copies the source to
  `/usr/local/etc/php/conf.d/zz-joomla-hardening.ini`. An identical active copy is
  left alone; a missing or changed copy is replaced from the source. The copy is
  made readable by PHP workers and installed atomically so PHP cannot load a
  partially copied profile.
- When disabled, the entrypoint removes only that active copy, if present.
  The source profile and all other PHP configuration remain untouched.
- A missing, empty or unreadable source blocks activation. A failed copy or
  removal stops startup before the requested command runs.

The official PHP images use `$PHP_INI_DIR/conf.d` for additional active INI
files and keep their supplied `php.ini-production` and `php.ini-development`
examples in `$PHP_INI_DIR`. They do not define a standard disabled-profile
directory shared by Debian and Alpine. Keeping this source alongside those
examples follows the existing layout; it does not introduce a Debian-specific
`mods-available` or `phpenmod` mechanism. See the
[official PHP image configuration guidance](https://hub.docker.com/_/php#configuration)
and [PHP's configuration loading rules](https://www.php.net/manual/en/configuration.file.php).

This happens before the requested command, including installation and PHP CLI
commands. Subsequent `docker compose exec` PHP processes use the same settings.
The decision uses only the environment setting and PHP configuration files. It
does not depend on a Joomla installation, database, webroot or initialization
marker, and it does not edit site files. Commands such as `php --version` and
`sh` still run without Joomla initialization. `docker compose exec` itself does
not rerun the entrypoint; changing its environment does not reconfigure already
running Apache or FPM workers. Recreate the service as shown above to change
the setting for the whole container.

| Setting | Profile value and effect |
| --- | --- |
| `expose_php` | `Off`; restates the default used by all images |
| `session.cookie_secure` | `On`; restricts session cookies to HTTPS |
| `session.cookie_httponly` | `On`; prevents JavaScript from reading session cookies; Joomla already applies this to its own web sessions |
| `session.use_cookies`, `session.use_only_cookies` | `On`; restates PHP's cookie-based session defaults |
| `session.cookie_samesite` | `Lax`; permits cookies on ordinary cross-site navigation using GET, but not cross-site POST requests |
| `session.use_strict_mode` | `On`; rejects uninitialized session IDs when the configured session handler supports validation |
| `allow_url_include` | `Off`; restates PHP's default prohibition on URL-based includes |
| `zend.exception_ignore_args` | `On`; omits function arguments from exception traces, reducing accidental disclosure of passwords or tokens |
| `session.upload_progress.enabled` | `Off`; disables PHP's session-based upload-progress tracking, not file uploads |

The profile deliberately leaves `disable_functions` and `allow_url_fopen`
unchanged. Process functions can be required by extensions and maintenance
tools; `openlog` and `syslog` are used by Joomla's optional syslog logger.
Disabling resource-inspection or selected socket functions does not create a
container security boundary. PHP itself cautions that
[`disable_functions` is not a sufficient security measure](https://www.php.net/manual/en/ini.core.php#ini.disable-functions).
An image-wide list would also replace an operator's existing restrictions,
potentially re-enabling functions they intentionally disabled. Existing custom
restrictions remain effective both with and without this profile. Sites needing
additional restrictions can supply a tested policy through their own INI file;
the image does not impose one on all web and CLI workloads. Keeping URL-aware
file access available preserves Joomla's stream HTTP transport and extensions
that depend on it.

The configured directives are available in PHP 8.2, 8.3, 8.4 and 8.5. Some
restate existing defaults; they are not separate new protections. Strict mode
requires a session handler implementing `validateId()` or a `validate_sid`
callback. Joomla's bundled database and filesystem handlers do not currently
provide that validation, so the INI value alone does not establish protection
against session-ID adoption. See [PHP session configuration](https://www.php.net/manual/en/session.configuration.php).
SameSite `Lax` can affect payment or SSO flows returning through cross-site POST
requests. Check those flows and any extension using PHP session upload-progress
tracking before enabling the profile.

The upload-progress setting also follows PHP's
[23 October 2026 advisory](https://www.php.net/archive/2026.php): disable this
feature until the next regular bugfix release to mitigate a configuration-dependent
issue. It does not replace the security fixes released on 21 October. Rebuild
production images from updated PHP bases and verify at least PHP 8.2.35, 8.3.36,
8.4.27 or 8.5.12 for the corresponding branch. Recheck the advisory when updating
these bases. Use the normal images for production; enabling this profile does
not remove development tools or Xdebug from a development image.

Disabling the profile restores the settings from the remaining configuration;
it does not weaken protections set independently in Joomla or custom INI files.

Changing state requires write access only to `$PHP_INI_DIR/conf.d`; the source
profile can remain read-only. For non-root or read-only containers, prepare the
desired active copy before startup or provide a writable configuration directory.
An already matching enabled copy or an already absent disabled copy requires no
write. Do not make the configuration directory writable by the web worker just
to enable this feature. A read-only mounted active file can be used when it
already matches the requested enabled state, but cannot be replaced or removed
by the entrypoint. If you set `PHP_INI_SCAN_DIR`, include
`/usr/local/etc/php/conf.d` so PHP loads the active profile, and do not include
`/usr/local/etc/php` itself: scanning the source directly would bypass the switch.
Custom PHP startup options or later configuration can override its settings.
This profile does not replace application updates or container isolation.

## Run Joomla CLI commands

For an installed site:

```bash
docker compose exec --user www-data joomla php cli/joomla.php list
```

The automatic-installation hook can be configured as:

```yaml
environment:
  JOOMLA_CLI_COMMANDS: "list; cache:clean"
```

The entrypoint adds `--no-interaction`. It splits commands at semicolons and
arguments at spaces or tabs. It does not evaluate shell code or interpret shell
quoting, pipes, substitutions or redirections. Commands requiring an argument
containing spaces should be run directly with `docker compose exec`, where
normal shell argument quoting is available. A failed configured CLI command
stops startup. The hook runs after a successful automatic installation, not on
every container restart and not for a site that is already installed.

## Files, permissions and image updates

Persist `/var/www/html` and the database separately. Named volumes are suitable
for running a site; bind mounts are useful when editing source from the host.
With a bind mount, align ownership and permissions with the account used by the
web server. Run project commands as the file owner rather than creating
root-owned source or dependency directories. See
[Development images](development.md#project-tools-and-permissions).

Before a Joomla or PHP upgrade, back up the site files and database and verify
the site's extension compatibility with the selected runtime. Set
`JOOMLA_IMAGE` in `.env` to the required published image reference, or keep the
current tag to receive its latest image update. Pull the image and recreate only the
Joomla service, keeping the existing volumes:

```bash
docker compose pull joomla
docker compose up -d --no-deps --force-recreate joomla
```

Replacing a container updates PHP and the tools in its image. It does not
replace Joomla files already present in `/var/www/html`. Upgrade that installed
site using Joomla's supported update process. Conversely, updating Joomla in
the volume does not rebuild the container's PHP runtime. Do not delete volumes
to perform a routine image update.

Use [Development images](development.md) for debugging and project tools.
Contributors changing the official image definitions should follow
[Maintenance](maintenance.md) and [Testing](testing.md).
