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
