#!/usr/bin/env bash
# Install a real site once: CI runs this only for the context owning "latest".
# Usage: tests/test-joomla.sh IMAGE VARIANT [HARDENING]
set -Eeuo pipefail

image=${1:?image is required}
variant=${2:?base variant is required}
hardening=${3:-false}
case "$hardening" in true|false) ;; *) echo >&2 'HARDENING must be true or false'; exit 2 ;; esac
case "$variant" in
  apache) container_port=80 ;;
  fpm|fpm-alpine) container_port=9000; command -v cgi-fcgi >/dev/null ;;
  *) echo >&2 "Unsupported variant: $variant"; exit 2 ;;
esac

tmp=$(mktemp -d)
network="joomla-site-$$-$RANDOM"
database="$network-db"
web="$network-web"
site_name='Joomla image smoke test'
phase='starting the database'
trap 'echo >&2 "Joomla smoke test failed while $phase (line $LINENO): $BASH_COMMAND"' ERR
cleanup() {
  local status=$?
  if (( status != 0 )); then
    docker logs "$database" >&2 2>/dev/null || true
    docker logs "$web" >&2 2>/dev/null || true
    if [[ -s "$tmp/response" ]]; then cat "$tmp/response" >&2; fi
  fi
  docker rm -fv "$web" "$database" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

docker network create "$network" >/dev/null
# One supported database baseline, with disposable test-only credentials.
docker run -d --name "$database" --network "$network" --network-alias db \
  -e MARIADB_RANDOM_ROOT_PASSWORD=1 -e MARIADB_DATABASE=joomla \
  -e MARIADB_USER=joomla -e MARIADB_PASSWORD=joomla-test-password \
  mariadb:lts >/dev/null
deadline=$((SECONDS + 120))
until timeout 5 docker exec "$database" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; do
  [[ $(docker inspect --format '{{.State.Running}}' "$database") == true ]]
  if (( SECONDS >= deadline )); then echo >&2 'MariaDB did not become ready'; exit 1; fi
  sleep 2
done

phase='installing Joomla through its default entrypoint'
docker run -d --name "$web" --network "$network" --publish "127.0.0.1::$container_port" \
  -e "JOOMLA_SECURITY_HARDENED=$hardening" \
  -e JOOMLA_DB_HOST=db -e JOOMLA_DB_NAME=joomla -e JOOMLA_DB_USER=joomla \
  -e JOOMLA_DB_PASSWORD=joomla-test-password -e "JOOMLA_SITE_NAME=$site_name" \
  -e JOOMLA_ADMIN_USER='Image Test Administrator' -e JOOMLA_ADMIN_USERNAME=imageadmin \
  -e JOOMLA_ADMIN_PASSWORD=joomla-test-admin-password -e JOOMLA_ADMIN_EMAIL=admin@example.test \
  "$image" >/dev/null
port=$(docker port "$web" "$container_port/tcp")
port=${port##*:}

request_page() {
  if [[ "$variant" == apache ]]; then
    local status
    status=$(curl --fail --silent --show-error --max-time 5 \
      --output "$tmp/response" --write-out '%{http_code}' "http://127.0.0.1:$port/") || return 1
    [[ "$status" == 200 ]] || return 1
  else
    SCRIPT_FILENAME=/var/www/html/index.php SCRIPT_NAME=/index.php REQUEST_URI=/ \
      REQUEST_METHOD=GET QUERY_STRING='' DOCUMENT_ROOT=/var/www/html \
      SERVER_PROTOCOL=HTTP/1.1 SERVER_NAME=localhost HTTP_HOST=localhost SERVER_PORT=80 \
      GATEWAY_INTERFACE=CGI/1.1 REDIRECT_STATUS=200 \
      timeout 5 cgi-fcgi -bind -connect "127.0.0.1:$port" >"$tmp/response" || return 1
    # FastCGI omits Status for a successful response; redirects/errors supply it.
    if grep -q '^Status:' "$tmp/response"; then
      grep -q '^Status: 200 ' "$tmp/response" || return 1
    fi
  fi
  grep -Fq "$site_name" "$tmp/response"
}

deadline=$((SECONDS + 120))
until docker exec "$web" sh -ec 'test -s configuration.php && test ! -d installation' \
  >/dev/null 2>&1 && request_page 2>/dev/null; do
  [[ $(docker inspect --format '{{.State.Running}}' "$web") == true ]]
  if (( SECONDS >= deadline )); then echo >&2 'Joomla did not serve the installed site'; exit 1; fi
  sleep 2
done

phase='booting the installed Joomla CLI as the web user'
docker exec --user www-data "$web" php cli/joomla.php --no-interaction list >/dev/null
echo "Joomla installation and page checks passed: $image ($variant, hardening=$hardening)"
