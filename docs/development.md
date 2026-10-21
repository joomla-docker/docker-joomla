# Joomla development images

Use a published Joomla development tag from the
[Docker Hub Official Image](https://hub.docker.com/_/joomla). Development tags
become available through the Official Images release process; choose a tag
listed there before using this guide. A tag proposed in this repository may
still be awaiting publication. No repository checkout is needed to use a
published image.

The `-dev` variants contain the same Joomla release and PHP/runtime as their
normal counterparts, plus backend and frontend development tools. Xdebug is
**enabled by default** with `develop,debug`. PHP reports development errors,
checks changed files immediately, and disables JIT.

The PHP and Xdebug configuration is baked into the image during its build.
No external INI file or configuration mount is needed to start debugging.

| Work | Included tools |
| --- | --- |
| PHP development and debugging | Composer, Xdebug, PCNTL, sockets and the normal Joomla PHP extensions |
| Frontend development | Node.js, npm, npx, Python 3, make and g++ for native npm modules |
| Repository and file work | Git, OpenSSH client, patch, zip, unzip, rsync, jq, less and nano |

Node.js follows the distribution used by the matching PHP base image. Database
command-line clients are not bundled. Use normal images for production and
development images for debugging, project builds and tests.

## Pull a development image

Choose a published Apache development tag matching the Joomla and PHP versions
you want to use. Follow the complete Compose example in
[Using the images](usage.md) and set `JOOMLA_IMAGE` in `.env` to `joomla:` followed
by that published tag. Pull it and start the services:

```bash
docker compose pull
docker compose up -d
```

Existing Compose projects can put the published `joomla:` reference directly
in their Joomla service's `image:` field. Use the matching FPM development
variant only with a separate web server.

## Switch between normal and development images

Development tags follow the normal tag with a `-dev` suffix. The
exception is `joomla:latest`, whose development counterpart is `joomla:dev`.
Select the matching tag from Docker Hub before changing your Compose image.
Use the matching exact Joomla version, PHP version and runtime tag when you
want to keep those versions fixed. `joomla:dev` follows the stable release
selected by `joomla:latest`; it is not a nightly Joomla source build.

Set `JOOMLA_IMAGE` in `.env` to the selected reference when using this guide's
Compose example, or edit your service's `image:` field. Keep the same `/var/www/html`
volume or bind mount, database connection, environment, network and application
ports. After changing the tag, recreate
only the Joomla service; the examples below use a service named `joomla`:

```bash
docker compose up -d --no-deps --pull always --force-recreate joomla
```

To switch back, restore the original tag and run the same command. The normal
image does not include Xdebug or the additional development tools. Image
switching does not upgrade Joomla files already stored in the mounted volume.

Composer dependencies, PHPUnit, static analysis tools, and coding standards
belong in the project's `composer.json` and lock file. Frontend dependencies
and build scripts belong in `package.json` and its lock file. Dependency
installation and project builds are explicit commands, never startup actions.

## Connect your IDE

Xdebug initiates an outbound connection to the IDE on TCP port **9003**. Do not
publish `9003:9003` on the Joomla service. Apache still serves HTTP and FPM still
uses its usual FastCGI port. Enable the PHP debugger listener in your IDE.

The image uses these environment defaults:

| Variable | Default | Purpose |
| --- | --- | --- |
| `JOOMLA_XDEBUG_CLIENT_HOST` | `host.docker.internal` | Host running the IDE/debug adapter |
| `JOOMLA_XDEBUG_CLIENT_PORT` | `9003` | Port the IDE/debug adapter listens on |
| `XDEBUG_MODE` | `develop,debug` | Enabled Xdebug capabilities |

Docker Desktop provides `host.docker.internal`. On Linux Docker Engine, add
`--add-host=host.docker.internal:host-gateway` to `docker run`, or add the
following to the existing Joomla Compose service:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

For a remote Docker host, set `JOOMLA_XDEBUG_CLIENT_HOST` to an IDE address
reachable from that host/container, or use an SSH tunnel. If the debug adapter
runs inside the same development container, use `127.0.0.1`.

Map the container's `/var/www/html` directory to the local Joomla project. In
VS Code, install the PHP Debug extension and use this `.vscode/launch.json`
when the workspace root is the Joomla web root:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Listen for Joomla Xdebug",
      "type": "php",
      "request": "launch",
      "port": 9003,
      "hostname": "0.0.0.0",
      "pathMappings": {
        "/var/www/html": "${workspaceFolder}"
      }
    }
  ]
}
```

For PhpStorm, create a PHP server named `joomla`, enable path mappings, and map
the local project to `/var/www/html`. Set `PHP_IDE_CONFIG=serverName=joomla` on
the Joomla service if needed for CLI sessions, and enable **Start Listening for
PHP Debug Connections**. Configure its debugger port as 9003.

Use a browser Xdebug extension or append `?XDEBUG_TRIGGER=1` to a request to
start debugging. For CLI debugging, with a Compose service named `joomla`:

```bash
docker compose exec -e XDEBUG_TRIGGER=1 joomla php cli/joomla.php list
```

Xdebug is already enabled; a trigger selects which request opens an IDE
session. Do not set `XDEBUG_CONFIG` globally: Xdebug also treats its presence as
a legacy debugging trigger. The native ini settings read the
`JOOMLA_XDEBUG_CLIENT_*` variables without that side effect. Official PHP FPM
images preserve environment variables; a custom pool configuration must also
preserve the required variables (normally `clear_env = no`).

## Select Xdebug modes

For a single CLI command, pass `XDEBUG_MODE` through `docker compose exec`:

```bash
docker compose exec -e XDEBUG_MODE=off joomla php cli/joomla.php list
docker compose exec -e XDEBUG_MODE=coverage joomla vendor/bin/phpunit
docker compose exec -e XDEBUG_MODE=profile -e XDEBUG_TRIGGER=1 \
  joomla php cli/joomla.php list
```

Coverage requires the project's PHPUnit installation. Profiling writes to
`/tmp` by default; mount a writable output directory and override
`xdebug.output_dir` in a PHP ini file to retain profiles after container removal.
These overrides affect only the new CLI process, not running Apache/FPM workers.

For all web requests and subsequent CLI processes, set `XDEBUG_MODE` in the
Joomla service's `environment` section and recreate the service:

```yaml
environment:
  XDEBUG_MODE: "off"
```

```bash
docker compose up -d --no-deps --force-recreate joomla
```

Use `develop,debug` to restore the default, or remove the environment override.
Then recreate again. `docker compose restart` does not apply changed environment
variables. The image's `XDEBUG_MODE` environment variable takes precedence over
`xdebug.mode` in ini files, including when selecting `profile` or `coverage`.

## Check an IDE connection

First confirm the extension, effective modes and destination:

```bash
docker compose exec joomla php --ri xdebug
docker compose exec joomla php -r '
echo "Modes: ", implode(",", xdebug_info("mode")), PHP_EOL;
echo "IDE: ", ini_get("xdebug.client_host"), ":", ini_get("xdebug.client_port"), PHP_EOL;
'
```

With the IDE listener running, check whether the container can reach its port:

```bash
docker compose exec joomla php -r '
$host = ini_get("xdebug.client_host");
$port = (int) ini_get("xdebug.client_port");
echo "Resolved host: ", gethostbyname($host), PHP_EOL;
$socket = @fsockopen($host, $port, $code, $message, 3);
if (!$socket) {
    fwrite(STDERR, "Cannot reach $host:$port: $message ($code)\n");
    exit(1);
}
fclose($socket);
echo "IDE port reachable", PHP_EOL;
'
```

A successful TCP check confirms connectivity, not IDE path mappings. If the
hostname does not resolve on Linux, check `extra_hosts`. If the connection is
refused or times out, check the IDE listener, its bind address, the configured
host/port and host firewall. With VS Code running inside WSL, install and run
the PHP Debug extension in that same WSL environment and use an address
reachable from the Joomla container.

If the IDE connects but a breakpoint is missed, check that `XDEBUG_TRIGGER` is
present and that the breakpoint is in a file executed by the request. Map the
whole `/var/www/html` directory, including `vendor` and `cli`, to the same code
in the IDE. The CLI checks above describe CLI PHP; custom Apache/FPM settings
can still differ.

For connection details from an actual web request, temporarily enable logging
inside the running container and restart its PHP server:

```bash
docker compose exec --user root joomla sh -c '
printf "%s\n" "xdebug.log = /tmp/joomla-xdebug.log" "xdebug.log_level = 7" \
  > "$PHP_INI_DIR/conf.d/zzz-xdebug-diagnostics.ini"
'
docker compose restart joomla
```

Make a triggered browser request, then read the log:

```bash
docker compose exec joomla cat /tmp/joomla-xdebug.log
```

Remove the temporary settings and restart when finished:

```bash
docker compose exec --user root joomla sh -c \
  'rm -f "$PHP_INI_DIR/conf.d/zzz-xdebug-diagnostics.ini" /tmp/joomla-xdebug.log'
docker compose restart joomla
```

These temporary settings require no host configuration file and disappear if
the container is recreated. They leave trigger-based debugging unchanged.

## Project tools and permissions

Open a development shell as the user that owns the Joomla files. For a volume
owned by the image's default `www-data` account:

```bash
docker compose exec --user www-data joomla bash -c '
dev_cache="/tmp/joomla-dev-$(id -u)"
export COMPOSER_HOME="$dev_cache/composer" npm_config_cache="$dev_cache/npm"
mkdir -p "$COMPOSER_HOME" "$npm_config_cache"
exec bash
'
```

The shell starts in `/var/www/html` with writable Composer and npm directories.
Inspect the available Joomla commands and PHP extensions with:

```bash
php cli/joomla.php list
php -m
```

For development projects with Composer and npm lock files, install the project's
dependencies and list its scripts from that same shell:

```bash
composer install
npm ci
composer run-script --list
npm run
```

An installed Joomla site's release package may not contain the source project's
frontend build files. Work in the extension or Joomla source directory containing
the relevant manifests when building or testing that project.

For bind mounts owned by your workstation user, use
`--user "$(id -u):$(id -g)"` instead of `--user www-data`, and keep the web-server
permissions aligned. Mount writable home/cache directories if they should
survive container recreation. Do not enable Composer plugins globally as root
or disable Git ownership checks globally.

Git and the SSH client use the executing user's configuration. Provide access
through your deployment's SSH-agent or credential mounts; an SSH user also
needs an account in the container's `/etc/passwd`, not only a numeric UID.
Keep private keys out of the image.

Email capture belongs to the deployment. Point Joomla's SMTP host and port at
your own mail service. For initial automatic installation, the entrypoint
accepts `JOOMLA_SMTP_HOST` and `JOOMLA_SMTP_HOST_PORT`; for an existing site,
change its Joomla mail settings.

## Contribute changes to the images

Install project-specific dependencies through the project's lock files. For
changes to the tools included in the official development images, follow
[Maintenance](maintenance.md). The maintainer [testing guide](testing.md)
covers validating image changes before publication.
