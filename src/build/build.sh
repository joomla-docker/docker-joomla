#!/usr/bin/env bash
set -Eeuo pipefail

# Emit one Dockerfile directly from resolved JSON; no template engine is needed.
# Shell expressions below are deliberately emitted for the image build to run.
# shellcheck disable=SC2016
render_dockerfile() (
  set -Eeuo pipefail
  if (( $# != 6 )); then
    echo 'render_dockerfile requires CONFIG SERIES STATE PHP VARIANT DEVELOPMENT' >&2
    exit 1
  fi
  configuration=$1 series=$2 state=$3 php=$4 variant=$5 development=$6
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  selected="$(jq -ce --arg series "$series" --arg state "$state" --arg php "$php" \
    --arg variant "$variant" --arg development "$development" '
    # Append unique package entries, but replace each configured file as a unit.
    def merge($other):
      reduce ($other | to_entries[]) as $entry (.;
        $entry.key as $key | $entry.value as $value
        | .[$key] = (
            if $key == "config" then (.[$key] // {}) + $value
            elif (.[$key] | type) == "object" and ($value | type) == "object" then
              .[$key] | merge($value)
            elif (.[$key] | type) == "array" and ($value | type) == "array" then
              reduce (.[$key] + $value)[] as $item
                ([]; if index($item) == null then . + [$item] else . end)
            else $value end));
    .[$series] as $settings
    | $settings.phpVersions[$php]
    | if $development == "1" then merge(.dev) else . end
    | merge(.variants[$variant])
    | {image: ., release: $settings.states[$state], archives: $settings.archives}
  ' "$configuration")"
  image="$(jq -c '.image' <<<"$selected")"
  release="$(jq -c '.release' <<<"$selected")"

  quote() {
    if [[ $1 =~ ^[a-zA-Z0-9_@%+=:,./-]+$ ]]; then
      printf '%s' "$1"
    else
      printf "'%s'" "${1//\'/\'\"\'\"\'}"
    fi
  }
  words() {
    local separator='' value
    for value; do
      printf '%s' "$separator"
      quote "$value"
      separator=' '
    done
  }
  quote_configure() {
    local value=$1 prefix result=''
    # Only this exact placeholder may expand during the image build.
    while [[ $value == *'${DEB_BUILD_MULTIARCH}'* ]]; do
      prefix="${value%%'${DEB_BUILD_MULTIARCH}'*}"
      if [[ -n $prefix ]]; then result+="$(quote "$prefix")"; fi
      result+='"${DEB_BUILD_MULTIARCH}"'
      value="${value#*'${DEB_BUILD_MULTIARCH}'}"
    done
    if [[ -n $value ]]; then result+="$(quote "$value")"; fi
    printf '%s' "$result"
  }
  json_words() {
    jq -r "$1 | map(tostring | if test(\"^[a-zA-Z0-9_@%+=:,./-]+$\") then . else @sh end) | join(\" \")" <<<"$image"
  }
  steps=()
  step() { steps+=("$1"); }
  # Continue arguments on separate lines without introducing extra image layers.
  list_step() {
    local command=$1 value
    shift
    for value; do command+=$' \\\n\t\t'"$(quote "$value")"; done
    step "$command"
  }
  json_step() {
    local command=$1 expression=$2
    local -a values=()
    mapfile -t values < <(jq -r "$expression | .[]" <<<"$image")
    if (( ${#values[@]} )) || [[ ${3:-} == always ]]; then list_step "$command" "${values[@]}"; fi
  }
  emit_run() {
    local line
    printf 'RUN set -eux'
    for line in "${steps[@]}"; do printf '; \\\n\t%s' "$line"; done
    printf '\n\n'
    steps=()
  }
  append_cleanup() {
    local line command='' ending='; '
    ending+="\\"
    # A semicolon ending a continued line separates commands, while other
    # continuations belong to the same readable pipeline or substitution.
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -n $line && $line != \#* && $line != "\\" ]] || continue
      if [[ $line == *"$ending" ]]; then
        command+="${line%"$ending"}"
        step "$command"
        command=''
      else
        command+="$line"$'\n\t\t'
      fi
    done < "$script_dir/lib/cleanup-$manager.inc"
    if [[ -n $command ]]; then step "${command%$'\n\t\t'}"; fi
  }

  manager=apt
  if [[ $variant == *alpine* ]]; then manager=apk; fi
  if [[ $manager == apt ]]; then
    step 'apt-get update'
    json_step 'apt-get install -y --no-install-recommends' '.apt // []'
    step 'savedAptMark="$(apt-mark showmanual)"'
    json_step 'apt-get install -y --no-install-recommends $PHPIZE_DEPS' '.build.apt' always
    step 'DEB_BUILD_MULTIARCH="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"'
  else
    json_step 'apk add --no-cache' '.apk // []'
    json_step 'apk add --no-cache --virtual .build-deps $PHPIZE_DEPS' '.build.apk' always
  fi
  while IFS= read -r extension; do
    name="$(jq -r '.key' <<<"$extension")"
    args=()
    while IFS= read -r value; do
      value="$(jq -r '.' <<<"$value")"
      if [[ $value == *'${DEB_BUILD_MULTIARCH}'* ]]; then
        # Resolve this build fact inside the target image, not on the host.
        args+=("$(quote_configure "$value")")
      else
        args+=("$(quote "$value")")
      fi
    done < <(jq -c '.value[]' <<<"$extension")
    command="docker-php-ext-configure $(quote "$name")"
    if (( ${#args[@]} )); then command+=" ${args[*]}"; fi
    step "$command"
  done < <(jq -c '.extensions.configure // {} | to_entries[]' <<<"$image")
  json_step 'docker-php-ext-install -j "$(nproc)"' '.extensions.install // []'

  fetch=$'curl --fail --show-error --silent --location \\\n\t\t--retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \\\n\t\t--proto \'=https\' --proto-redir \'=https\' \\\n\t\t'
  temporary=()
  declarations=()
  while IFS= read -r download; do
    name="$(jq -r '.key' <<<"$download")"
    item="$(jq -c '.value' <<<"$download")"
    variable="${name^^}"
    declarations+=("ARG ${variable}_URL=$(jq -c '.package' <<<"$item")")
    declarations+=("ARG ${variable}_SHA256=$(jq -r '.sha256' <<<"$item")")
    destination="$(jq -r '.destination' <<<"$item")"
    type="$(jq -r '.type' <<<"$item")"
    target="/tmp/download-$name"
    if [[ $type == binary ]]; then target=$destination; fi
    step "$fetch\"\$${variable}_URL\" --output $(quote "$target")"
    step "printf '%s *%s\\n' \"\$${variable}_SHA256\" $(quote "$target") | sha256sum -c -"
    if [[ $type == binary ]]; then
      step "chmod 0755 $(quote "$target")"
    else
      step "mkdir -p $(quote "$destination")"
      step "tar -xzf $(quote "$target") -C $(quote "$destination") --strip-components=1 --no-same-owner"
      step "rm -f $(quote "$target")"
    fi
    while IFS= read -r link; do
      step "ln -s $(quote "$(jq -r '.value' <<<"$link")") $(quote "$(jq -r '.key' <<<"$link")")"
    done < <(jq -c '.links // {} | to_entries[]' <<<"$item")
    if jq -e '.temporary == true' <<<"$item" >/dev/null; then temporary+=("$destination"); fi
  done < <(jq -c '.download // {} | to_entries[]' <<<"$image")
  for installer in pie pecl; do
    while IFS= read -r package; do
      name="$(jq -r '.key' <<<"$package")"
      version="$(jq -r '.value' <<<"$package")"
      if [[ $installer == pie ]]; then
        # PIE uses docker-php-ext-enable in the official PHP image.
        step "PIE_WORKING_DIRECTORY=/tmp/joomla-pie $(quote "$(jq -r '.download.pie.destination' <<<"$image")")"' install --no-interaction --no-cache --make-parallel-jobs="$(nproc)" '"$(quote "$name:$version")"
      else
        step "printf '\\n' | pecl install $(quote "$name-$version")"
      fi
    done < <(jq -c --arg installer "$installer" '.[$installer] // {} | to_entries[]' <<<"$image")
  done
  json_step 'docker-php-ext-enable' '.extensions.enable // []'
  packages="$(json_words '.npm // {} | to_entries | map(.key + "@" + .value)')"
  if [[ -n $packages ]]; then
    step "npm_config_cache=/tmp/joomla-npm npm install --global --prefix /usr/local --no-audit --no-fund --engine-strict $packages"
    step 'hash -r'
  fi
  step "rm -rf $(words "${temporary[@]}" /tmp/joomla-pie /tmp/joomla-npm /tmp/pear /root/.cache)"
  step 'extDir="$(php-config --extension-dir)"'
  append_cleanup

  printf '# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/build/build.sh". DO NOT EDIT.\n'
  printf 'FROM %s\n\n' "$(jq -r '.base' <<<"$image")"
  printf 'LABEL org.opencontainers.image.authors="%s"\n\n' "$(jq -r 'map("\(.firstname) \(.lastname) <\(.email)> (@\(.github))") | join(", ")' "$script_dir/../../conf/maintainers.json")"
  jq -r '.environment | to_entries[] | "ENV \(.key)=\(.value | tojson)"' <<<"$image"
  printf '\n'
  if (( ${#declarations[@]} )); then printf '%s\n' "${declarations[@]}"; fi
  printf '\n'
  printf '# Install PHP extensions and tools; remove temporary dependencies in this layer.\n'
  emit_run

  # Configure the final runtime before checking startup and every expected module.
  mapfile -t directories < <(jq -r '.config // {} | keys | map(sub("/[^/]*$"; "") | if . == "" then "/" else . end) | unique[]' <<<"$image")
  if (( ${#directories[@]} )); then list_step 'mkdir -p' "${directories[@]}"; fi
  while IFS= read -r config; do
    path="$(jq -r '.key' <<<"$config")"
    mapfile -t lines < <(jq -c '.value[]' <<<"$config")
    values=()
    for line in "${lines[@]}"; do values+=("$(jq -r '.' <<<"$line")"); done
    list_step "printf '%s\\n'" "${values[@]}"
    steps[${#steps[@]}-1]+=$' \\\n\t\t> '"$(quote "$path")"
  done < <(jq -c '.config // {} | to_entries[]' <<<"$image")
  if jq -e '.apache != null' <<<"$image" >/dev/null; then
    step "a2enmod $(json_words '.apache.modules')"
    step "a2enconf $(json_words '.apache.enable')"
    if jq -e '.apache.remoteAddress == true' <<<"$image" >/dev/null; then
      step "find /etc/apache2 -type f -name '*.conf' -exec sed -ri 's/([[:space:]]*LogFormat[[:space:]]+\"[^\"]*)%h([^\"]*\")/\\1%a\\2/g' '{}' +"
    fi
  fi
  step 'if ! php --version 2> /tmp/php-startup-errors.txt; then cat /tmp/php-startup-errors.txt >&2; exit 1; fi'
  step 'if [ -s /tmp/php-startup-errors.txt ]; then cat /tmp/php-startup-errors.txt >&2; exit 1; fi'
  while IFS= read -r name; do step "php --ri $(quote "$name") > /dev/null"; done < <(
    jq -r '((.extensions.install // []) + (.extensions.check // [])) | unique[]' <<<"$image"
  )
  step 'rm -f /tmp/php-startup-errors.txt'
  while IFS= read -r check; do
    mapfile -t args < <(jq -r '.[]' <<<"$check")
    step "$(words "${args[@]}")"
  done < <(jq -c '.checks // [] | .[]' <<<"$image")
  printf '# Configure and check PHP, extensions, tools and the web server after cleanup.\n'
  emit_run

  package_type="$(jq -r '.packageType' <<<"$release")"
  archive="/tmp/joomla.$package_type"
  mapfile -t packages < <(jq -r --arg type "$package_type" --arg manager "$manager" '.archives[$type][$manager][]' <<<"$selected")
  if [[ $manager == apt ]]; then
    step 'savedAptMark="$(apt-mark showmanual)"'
    if (( ${#packages[@]} )); then
      step 'apt-get update'
      list_step 'apt-get install -y --no-install-recommends' "${packages[@]}"
    fi
  elif (( ${#packages[@]} )); then
    list_step 'apk add --no-cache --virtual .joomla-extract-deps' "${packages[@]}"
  fi
  step "$fetch\"\$JOOMLA_URL\" --output $(quote "$archive")"
  step "printf '%s *%s\\n' \"\$JOOMLA_SHA512\" $(quote "$archive") | sha512sum -c -"
  step 'mkdir -p /usr/src/joomla'
  tar_option=''
  if [[ $package_type == tar.zst ]]; then tar_option='--zstd '; fi
  step "tar ${tar_option}-xf $(quote "$archive") -C /usr/src/joomla --no-same-owner"
  step 'test -s /usr/src/joomla/index.php'
  step 'test -s /usr/src/joomla/cli/joomla.php'
  step 'chown -R www-data:www-data /usr/src/joomla'
  step "rm -f $(quote "$archive")"
  if [[ $manager == apt ]]; then
    step "apt-mark auto '.*' > /dev/null"
    step '[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark'
    step 'apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false'
    step 'rm -rf /var/lib/apt/lists/*'
  elif (( ${#packages[@]} )); then
    step 'apk del --no-network .joomla-extract-deps'
  fi
  printf '# Joomla release changes reuse the PHP extension and configuration layers.\n'
  printf 'ENV JOOMLA_VERSION=%s\n' "$(jq -r '.version' <<<"$release")"
  printf 'ARG JOOMLA_URL=%s\n' "$(jq -c '.package' <<<"$release")"
  printf 'ENV JOOMLA_SHA512=%s\n\n' "$(jq -r '.sha512' <<<"$release")"
  emit_run

  printf 'VOLUME %s\n' "$(jq -r '.volume | map(tojson) | "[" + join(", ") + "]"' <<<"$image")"
  printf 'WORKDIR %s\n' "$(jq -r '.workdir' <<<"$image")"
  printf '\nCOPY docker-entrypoint.sh /entrypoint.sh\nCOPY makedb.php /makedb.php\n\n'
  printf 'ENTRYPOINT %s\n' "$(jq -r '.entrypoint | map(tojson) | "[" + join(", ") + "]"' <<<"$image")"
  printf 'CMD %s\n' "$(jq -r '.command | map(tojson) | "[" + join(", ") + "]"' <<<"$image")"
)

main() (
  cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.."

  if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: ./src/build/build.sh [SERIES | SERIES/STATE ...]'
    exit 0
  fi
  if [[ ! -f conf/versions.json ]]; then
    echo 'conf/versions.json not found; run ./src/build/versions.sh first.' >&2
    exit 1
  fi
  # Generation, CI and publication share one matrix, directory and tag plan.
  # Validate the whole namespace and every selector before writing any context.
  jq -e --arg mode resolved -f src/build/lib/validate-config.jq conf/versions.json >/dev/null
  plan="$(jq -c -f src/build/lib/tags.jq conf/versions.json)"
  selectors="$(jq -cn --args '$ARGS.positional' -- "$@")"
  plan="$(jq -ce --argjson selectors "$selectors" '
    . as $contexts
    | ($selectors | map(rtrimstr("/")) | unique) as $selected
    | reduce $selected[] as $selector (.;
        if any($contexts[]; .series == $selector or (.series + "/" + .state) == $selector)
        then . else error("Unknown release selector: " + $selector) end)
    | if $selected == [] then . else
        map(select(.series as $series | (.series + "/" + .state) as $track
          | any($selected[]; . == $series or . == $track)))
      end
  ' <<<"$plan")"
  staging="$(mktemp -d .build-staging.XXXXXXXX)"
  trap 'rm -rf "$staging"' EXIT
  directories=()
  while IFS=$'\t' read -r version state phpVersion variant development dir; do
    docker_entrypoint='src/runtime/docker-entrypoint.sh'
    if [[ -f "src/runtime/docker-entrypoint-$version.sh" ]]; then
      docker_entrypoint="src/runtime/docker-entrypoint-$version.sh"
    fi
    mkdir -p "$staging/$dir"
    cp -p "$docker_entrypoint" "$staging/$dir/docker-entrypoint.sh"
    cp -p src/runtime/makedb.php "$staging/$dir/makedb.php"
    render_dockerfile conf/versions.json "$version" "$state" "$phpVersion" "$variant" "$development" >"$staging/$dir/Dockerfile"
    directories+=("$dir")
  done < <(jq -r '.[] | [.series, .state, .php, .variant, (if .development then 1 else 0 end), .directory] | @tsv' <<<"$plan")

  # Publish only after every selected Dockerfile renders successfully.
  # Old contexts and unrelated files are deliberately left alone.
  for dir in "${directories[@]}"; do
    mkdir -p "$dir"
    for file in "$staging/$dir/"*; do mv -f "$file" "$dir/${file##*/}"; done
    echo "processed $dir"
  done
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
