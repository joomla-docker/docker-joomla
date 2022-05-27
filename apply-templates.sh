#!/usr/bin/env bash
set -Eeuo pipefail

[ -f versions.json ] # run "versions.sh" first

jqt='.jq-template.awk'
if [ -n "${BASHBREW_SCRIPTS:-}" ]; then
  jqt="$BASHBREW_SCRIPTS/jq-template.awk"
elif [ "$BASH_SOURCE" -nt "$jqt" ]; then
  wget -qO "$jqt" 'https://github.com/docker-library/bashbrew/raw/5f0c26381fb7cc78b2d217d58007800bdcfbcfa1/scripts/jq-template.awk'
fi

# if no versions passed we load from versions.json
if [ "$#" -eq 0 ]; then
  versions="$(jq -r 'keys | map(@sh) | join(" ")' versions.json)"
  eval "set -- $versions"
fi

# the warning message to not update the docker files directly
generated_warning() {
  cat <<-EOH
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "apply-templates.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#

	EOH
}

# set the Joomla maintainers of these docker images
joomlaMaintainers="$( jq -cr '. | map(.firstname + " " + .lastname + " <" + .email + "> (@" + .github + ")") | join(", ")' maintainers.json)"
export joomlaMaintainers

# loop over the version set above
for version; do
  export version
  # get this Joomla version details
  joomlaVersionDetails="$(jq -r '.[env.version]' versions.json)"
  # get this Joomla version
  joomlaVersion="$(echo "${joomlaVersionDetails}" | jq -r '.version')"
  export joomlaVersion
  # get the PHP version
  phpVersions="$(echo "${joomlaVersionDetails}" | jq -r '.phpVersions | map(@sh) | join(" ")')"
  eval "phpVersions=( $phpVersions )"
  # get the variants
  variants="$(echo "${joomlaVersionDetails}" | jq -r '.variants | map(@sh) | join(" ")')"
  eval "variants=( $variants )"
  # get this version Joomla Sha512
  joomlaSha512="$(echo "${joomlaVersionDetails}" | jq -r '.sha512')"
  export joomlaSha512
  # get this version Joomla Package URL
  joomlaPackage="$(echo "${joomlaVersionDetails}" | jq -r '.package')"
  export joomlaPackage

  for phpVersion in "${phpVersions[@]}"; do
    export phpVersion

    # get the pecl values (we may want to move this to versions.json)
    peclValues="$(jq -r '.[env.version].phpVersions[env.phpVersion].pecl' versions-helper.json)"
    # get the APCu values
    pecl_APCu="$(echo "${peclValues}" | jq -r '.APCu')"
    export pecl_APCu
    # get the memcached values
    pecl_memcached="$(echo "${peclValues}" | jq -r '.memcached')"
    export pecl_memcached
    # get the redis values
    pecl_redis="$(echo "${peclValues}" | jq -r '.redis')"
    export pecl_redis
    # get the mcrypt values
    pecl_mcrypt="$(echo "${peclValues}" | jq -r '.mcrypt')"
    export pecl_mcrypt

    for variant in "${variants[@]}"; do
      export variant

      # the path to this variant folder
      dir="$version/php$phpVersion/$variant"
      mkdir -p "$dir"

      echo "processing $dir ..."

      # move the entrypoint file into place
      cp -a "docker-entrypoint.sh" "$dir/docker-entrypoint.sh"
      # move the make database file into place
			cp -a "makedb.php" "$dir/makedb.php"

      {
        generated_warning
        gawk -f "$jqt" Dockerfile.template
      } >"$dir/Dockerfile"
    done
  done
done

