#!/usr/bin/env bash
# Exercise a built image. Usage: tests/test-images.sh IMAGE VARIANT DEVELOPMENT
set -Eeuo pipefail
test_case='runtime test setup'
trap 'echo "FAIL: $test_case (${BASH_SOURCE[0]}:$LINENO)" >&2' ERR

image=${1:?image is required}
variant=${2:?base variant is required}
development=${3:?development must be true or false}
case "$variant" in apache|fpm|fpm-alpine) ;; *) exit 2 ;; esac
case "$development" in true|false) ;; *) exit 2 ;; esac

tmp=$(mktemp -d)
network="joomla-test-$$-$RANDOM"
listener="$network-debugger"
web="$network-web"
cleanup() {
  local status=$?
  if (( status != 0 )); then
    docker logs "$listener" >&2 2>/dev/null || true
    docker logs "$web" >&2 2>/dev/null || true
  fi
  docker rm -f "$listener" "$web" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

test_case="opt-in hardening in $image"
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker run --rm -e JOOMLA_SECURITY_HARDENED=true \
  --mount "type=bind,src=$tests_dir,dst=/hardening-tests,readonly" \
  "$image" php /hardening-tests/hardening-check.php
docker run --rm --mount "type=bind,src=$tests_dir,dst=/hardening-tests,readonly" \
  "$image" bash /hardening-tests/test-hardening.sh \
  /entrypoint.sh /usr/local/etc/php/joomla-hardening.ini

test_case="hardening on/off restores the image PHP configuration in $image"
docker run --rm --mount "type=bind,src=$tests_dir,dst=/hardening-tests,readonly" \
  "$image" sh -ec '
  profile="$PHP_INI_DIR/joomla-hardening.ini"
  active="$PHP_INI_DIR/conf.d/zz-joomla-hardening.ini"
  checker=/hardening-tests/hardening-check.php
  test -s "$profile"
  test ! -e "$active"
  cp "$profile" /tmp/hardening-source.ini
  php "$checker" snapshot >/tmp/hardening-baseline.json
  for attempt in 1 2; do
    JOOMLA_SECURITY_HARDENED=true /entrypoint.sh php "$checker"
    cmp "$profile" "$active"
    cmp "$profile" /tmp/hardening-source.ini
    JOOMLA_SECURITY_HARDENED=false /entrypoint.sh php "$checker" snapshot >/tmp/hardening-disabled.json
    test ! -e "$active"
    cmp /tmp/hardening-baseline.json /tmp/hardening-disabled.json
    cmp "$profile" /tmp/hardening-source.ini
  done
'

test_case="already configured hardening works without write permissions in $image"
docker run --rm "$image" cat /usr/local/etc/php/joomla-hardening.ini >"$tmp/hardening.ini"
chmod 0644 "$tmp/hardening.ini"
docker run --rm --read-only --user www-data "$image" php --version >/dev/null
docker run --rm --read-only --user www-data -e JOOMLA_SECURITY_HARDENED=true \
  --mount "type=bind,src=$tmp/hardening.ini,dst=/usr/local/etc/php/conf.d/zz-joomla-hardening.ini,readonly" \
  --mount "type=bind,src=$tests_dir,dst=/hardening-tests,readonly" \
  "$image" php /hardening-tests/hardening-check.php

test_case="PHP and Joomla files in $image"
docker run --rm "$image" php --version 2>"$tmp/php-stderr"
test ! -s "$tmp/php-stderr"
docker run --rm "$image" php -r '
if (filter_var(ini_get("expose_php"), FILTER_VALIDATE_BOOLEAN)) {
    fwrite(STDERR, "PHP exposure must be disabled by default\n"); exit(1);
}
foreach (["mysqli", "pdo_mysql", "pdo_pgsql", "intl", "gd", "zip", "imagick", "redis", "memcached", "apcu"] as $extension) {
    if (!extension_loaded($extension)) { fwrite(STDERR, "Missing extension: $extension\n"); exit(1); }
}
if (!is_file("/usr/src/joomla/cli/joomla.php")) { exit(1); }
'

if [[ "$development" == false ]]; then
  test_case="normal image excludes development tools: $image"
  docker run --rm "$image" php -r 'exit(extension_loaded("xdebug") ? 1 : 0);'
  docker run --rm "$image" sh -ec '! command -v composer && ! command -v pie'
  exit 0
fi

test_case="Xdebug defaults and mode overrides in $image"
docker run --rm "$image" php -r '
if (!extension_loaded("xdebug") || ini_get("xdebug.start_with_request") !== "trigger"
    || ini_get("xdebug.discover_client_host") || getenv("XDEBUG_CONFIG") !== false
    || !in_array("debug", xdebug_info("mode"), true)) { exit(1); }
'
docker run --rm -e XDEBUG_MODE=off "$image" php -r 'exit(xdebug_info("mode") === [] ? 0 : 1);'
docker run --rm -e XDEBUG_MODE=coverage "$image" php -r '
if (!in_array("coverage", xdebug_info("mode"), true)) { exit(1); }
xdebug_start_code_coverage(); xdebug_stop_code_coverage();
'
test_case="Composer runs as the web user; temporary PIE has been removed in $image"
docker run --rm --user www-data -e COMPOSER_HOME=/tmp/composer-home "$image" sh -ec '
  composer --version
  ! command -v pie
  test ! -e /tmp/pie
  test ! -d /tmp/joomla-pie
  test ! -d /tmp/joomla-npm
  cache=$(composer config --global cache-dir)
  mkdir -p "$cache"
  touch "$cache/write-test"
  rm "$cache/write-test"
'
# Run a local npm project as the web user, with no registry or host tools needed.
test_case="development tools and offline npm build in $image"
docker run --rm --user www-data -e npm_config_cache=/tmp/npm-cache "$image" sh -ec '
  for tool in git ssh patch zip unzip node npm npx python3 make g++ jq rsync less nano; do
    command -v "$tool" >/dev/null
  done
  test "$(npx --version)" = "$(npm --version)"
  test "$(command -v npm)" = /usr/local/bin/npm
  test "$(command -v npx)" = /usr/local/bin/npx
  test ! -e /usr/bin/npm
  project=$(mktemp -d)
  mkdir -p "$npm_config_cache"
  cd "$project"
  node -e '\''require("node:fs").writeFileSync("package.json", JSON.stringify({name:"joomla-dev-check",version:"1.0.0",private:true,scripts:{build:"node build.js"}}))'\''
  printf "%s\n" '\''require("node:fs").writeFileSync("built.js", "console.log(123)")'\'' >build.js
  npm install --package-lock-only --ignore-scripts --offline --no-audit --no-fund
  npm ci --offline --no-audit --no-fund
  npm run build
  test "$(node built.js)" = 123
  test -w "$npm_config_cache"
'

# A real DBGp exchange verifies connectivity, rather than only extension loading.
cat >"$tmp/debug-client.php" <<'PHP'
<?php
function packet($socket): string
{
    $length = '';
    while (($byte = fread($socket, 1)) !== "\0") {
        if ($byte === false || $byte === '' || strlen($length) > 8 || !ctype_digit($byte)) {
            throw new RuntimeException('Invalid DBGp frame length');
        }
        $length .= $byte;
    }
    $remaining = (int) $length;
    $payload = '';
    while ($remaining > 0) {
        $chunk = fread($socket, $remaining);
        if ($chunk === false || $chunk === '') { throw new RuntimeException('Incomplete DBGp frame'); }
        $payload .= $chunk;
        $remaining -= strlen($chunk);
    }
    if (fread($socket, 1) !== "\0") { throw new RuntimeException('Invalid DBGp terminator'); }
    return $payload;
}
$port = getenv('DEBUGGER_PORT') ?: '9003';
$server = stream_socket_server('tcp://0.0.0.0:' . $port, $errno, $error);
if (!$server) { throw new RuntimeException($error); }
echo "READY\n";
$socket = stream_socket_accept($server, 60);
if (!$socket) { throw new RuntimeException('Xdebug did not connect'); }
stream_set_timeout($socket, 10);
$init = packet($socket);
if (!str_contains($init, '<init ') || !str_contains($init, 'language="PHP"')) {
    throw new RuntimeException('Expected a PHP DBGp init packet');
}
fwrite($socket, "run -i 1\0");
$response = packet($socket);
if (!str_contains($response, 'status="stopping"')) { throw new RuntimeException($response); }
fwrite($socket, "stop -i 2\0");
packet($socket);
fclose($socket);
fclose($server);
echo "DBGP_OK\n";
PHP
printf '%s\n' '<?php echo "joomla-runtime-ok";' >"$tmp/debug.php"
chmod 755 "$tmp"
chmod 644 "$tmp"/*.php
docker network create "$network" >/dev/null

start_listener() {
  local port=${1:-9003}
  docker rm -f "$listener" >/dev/null 2>&1 || true
  docker run -d --name "$listener" --network "$network" -e XDEBUG_MODE=off \
    -e "DEBUGGER_PORT=$port" \
    --mount "type=bind,src=$tmp/debug-client.php,dst=/debug-client.php,readonly" \
    --entrypoint php "$image" /debug-client.php >/dev/null
  for ((i = 0; i < 30; i++)); do
    if docker logs "$listener" 2>&1 | grep -q '^READY$'; then return; fi
    sleep 1
  done
  echo >&2 'DBGp listener did not start'
  return 1
}

assert_listener_waiting() {
  [[ $(docker inspect --format '{{.State.Running}}' "$listener") == true ]]
  ! docker logs "$listener" 2>&1 | grep -q '^DBGP_OK$'
}

assert_debug_session() {
  [[ $(timeout 30 docker wait "$listener") == 0 ]]
  docker logs "$listener" | grep -q '^DBGP_OK$'
}

test_case="CLI debug connection and trigger in $image"
start_listener 19003
# Without a trigger the script must finish while the listener is still waiting.
docker run --rm --network "$network" -e "JOOMLA_XDEBUG_CLIENT_HOST=$listener" \
  -e JOOMLA_XDEBUG_CLIENT_PORT=19003 \
  "$image" php -r 'echo "cli-without-trigger\n";'
assert_listener_waiting
docker run --rm --network "$network" -e "JOOMLA_XDEBUG_CLIENT_HOST=$listener" \
  -e JOOMLA_XDEBUG_CLIENT_PORT=19003 -e XDEBUG_TRIGGER=1 \
  "$image" php -r 'echo "cli-with-trigger\n";'
assert_debug_session

test_case="web debug connection and trigger in $image ($variant)"
start_listener
if [[ "$variant" == apache ]]; then
  server=apache2-foreground
  container_port=80
else
  command -v cgi-fcgi >/dev/null
  server=php-fpm
  container_port=9000
fi
docker run -d --name "$web" --network "$network" \
  -e "JOOMLA_XDEBUG_CLIENT_HOST=$listener" \
  --publish "127.0.0.1::$container_port" \
  --mount "type=bind,src=$tmp,dst=/var/www/html,readonly" \
  --entrypoint "$server" "$image" >/dev/null
port=$(docker port "$web" "$container_port/tcp")
port=${port##*:}

web_request() {
  local query=${1:-}
  if [[ "$variant" == apache ]]; then
    curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$port/debug.php$query"
  else
    SCRIPT_FILENAME=/var/www/html/debug.php SCRIPT_NAME=/debug.php REQUEST_METHOD=GET \
      QUERY_STRING="${query#?}" SERVER_PROTOCOL=HTTP/1.1 SERVER_NAME=localhost \
      SERVER_PORT=80 GATEWAY_INTERFACE=CGI/1.1 REDIRECT_STATUS=200 \
      timeout 10 cgi-fcgi -bind -connect "127.0.0.1:$port"
  fi
}
ready=false
for ((i = 0; i < 20; i++)); do
  if response=$(web_request 2>/dev/null) && [[ "$response" == *joomla-runtime-ok* ]]; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]]
assert_listener_waiting
response=$(web_request '?XDEBUG_TRIGGER=1')
[[ "$response" == *joomla-runtime-ok* ]]
assert_debug_session
echo "Development runtime checks passed: $image ($variant)"
