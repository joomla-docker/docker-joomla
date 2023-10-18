#!/bin/bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

# you can pass the versions (of Joomla) to this file for the initial/re-build
versions=("$@")
if [ ${#versions[@]} -eq 0 ]; then
  # get the folders from the current root directory of the project as the versions
  # if no versions where passed to the file
  # this is the standard (2021) way fo doing this
  # see (https://github.com/docker-library/php/blob/master/versions.sh#L38)
  versions=(*/)
  # was assume the folders to be correct
  # and will serve as the rule
  # so the json is build from that
  json='{}'
else
  # with the initial/re-build the versions.json is manually set
  json="$(<versions.json)"
fi
# always make sure the folder / slash is removed
versions=("${versions[@]%/}")

# we use the versions help until the API is improved (with local overriding options)
if [ -f .versions-helper.json ]; then
   versionsHelper="$(<.versions-helper.json)"
elif [ -f versions-helper.json ]; then
   versionsHelper="$(<versions-helper.json)"
else
  echo "versions-helper.json file not found!"
  exit 1
fi
# now we loop over the (Joomla) versions
for version in "${versions[@]}"; do
  export version
  doc='{}'

  # lets get the full version
  fullVersion=$(echo $versionsHelper | jq -r '.[env.version].version')
  export fullVersion

  # lets see if we have a source URL
  package=$(echo $versionsHelper | jq -r '.[env.version].package')
  packageType=$(echo $versionsHelper | jq -r '.[env.version].packageType')
  if [ -z "$packageType" ] || [ "$packageType" = "null" ]; then
    packageType="tar.bz2"
  fi

  # when not found we load sha512 from API
  if [ -z "${package}" ] || [ "${package}" = 'null' ]; then
    # get the url version
    urlVersion=$(echo $fullVersion | sed -e 's/\./-/g')
    # get the hash
    sha512="$(curl -fsSL "https://downloads.joomla.org/api/v1/signatures/cms/$urlVersion" | jq -r --arg file "Joomla_${fullVersion}-Stable-Full_Package.${packageType}" '.[] | .[] | select(.filename == $file).sha512')"
    # set the full URL for the IMAGES
    package="https://github.com/joomla/joomla-cms/releases/download/${fullVersion}/Joomla_${fullVersion}-Stable-Full_Package.${packageType}"
  else
    # we get the sha from the package
    curl -o "joomla.${packageType}" -SL "${package}" &>/dev/null
    # get the hash
    sha512=$(sha512sum "joomla.${packageType}" | cut -d " " -f 1)
    # remove the file
    rm "joomla.${packageType}"
  fi

  # set the hash to the JSON
  if [ -n "$sha512" ] && [ -n "$package" ] && [ -n "$packageType" ]; then
    export sha512
    export package
    export packageType
    doc="$(jq <<<"$doc" -c '.sha512 = env.sha512')"
    doc="$(jq <<<"$doc" -c '.package = env.package')"
    doc="$(jq <<<"$doc" -c '.packageType = env.packageType')"
  fi

  # get the default php version
  defaultPHP=$(echo $versionsHelper | jq -r '.[env.version].php')
  # get the PHP versions
  phpVersions=$(echo $versionsHelper | jq -r '.[env.version].phpVersions | keys[]' | jq -R -s -c '. / "\n" - [""]')
  # get the default variant
  defaultVariant=$(echo $versionsHelper | jq -r '.[env.version].variant')
  # get the variants
  variants=$(echo $versionsHelper | jq -r '.[env.version].variants')
  # get the aliases
  aliases=$(echo $versionsHelper | jq -r '.[env.version].aliases')

  # echo some version details
  echo "### Joomla $version.x details"
  echo "# Version => $fullVersion"
  echo "# PHP     => $phpVersions"
  echo "# sha512  => $sha512"

  # build this fullVersion matrix
  # and add it to the JSON
  json="$(
    jq <<<"$json" -c \
      --argjson doc "$doc" \
      --argjson phpVersions "$phpVersions" \
      --argjson aliases "$aliases" \
      --argjson variants "$variants" \
      --arg defaultPHP "$defaultPHP" \
      --arg defaultVariant "$defaultVariant" '
			.[env.version] = {
				version: env.fullVersion,
				php: $defaultPHP,
				phpVersions: $phpVersions,
				variant: $defaultVariant,
				variants: $variants,
				aliases: $aliases,
			} + $doc
		'
  )"
done

# store the JSON to the file system
jq <<<"$json" -S . >versions.json

