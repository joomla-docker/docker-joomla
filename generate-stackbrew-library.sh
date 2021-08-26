#!/usr/bin/env bash
set -Eeuo pipefail

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

if [ "$#" -eq 0 ]; then
  versions="$(jq -r 'keys | map(@sh) | join(" ")' versions.json)"
  eval "set -- $versions"
fi

# sort version numbers with highest first
IFS=$'\n'
set -- $(sort -rV <<<"$*")
unset IFS

# get the most recent commit which modified any of "$@"
fileCommit() {
  git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
  local dir="$1"
  shift
  (
    cd "$dir"
    fileCommit \
      Dockerfile \
      $(git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						if ($i ~ /^--from=/) {
							next
						}
						print $i
					}
				}
			')
  )
}

gawkParents='
	{ cmd = toupper($1) }
	cmd == "FROM" {
		print $2
		next
	}
	cmd == "COPY" {
		for (i = 2; i < NF; i++) {
			if ($i ~ /^--from=/) {
				gsub(/^--from=/, "", $i)
				print $i
				next
			}
		}
	}
'

getArches() {
  local repo="$1"
  shift

  local parentRepoToArchesStr
  parentRepoToArchesStr="$(
    find -name 'Dockerfile' -exec gawk "$gawkParents" '{}' + |
      sort -u |
      gawk -v officialImagesUrl='https://github.com/docker-library/official-images/raw/master/library/' '
				$1 !~ /^('"$repo"'|scratch|.*\/.*)(:|$)/ {
					printf "%s%s\n", officialImagesUrl, $1
				}
			' |
      xargs -r bashbrew cat --format '["{{ .RepoName }}:{{ .TagName }}"]="{{ join " " .TagEntry.Architectures }}"'
  )"
  eval "declare -g -A parentRepoToArches=( $parentRepoToArchesStr )"
}
getArches 'joomla'

# get the Joomla maintainers of these docker images
joomlaMaintainers="$(jq -cr '. | map(.firstname + " " + .lastname + " <" + .email + "> (@" + .github + ")") | join(",\n             ")' maintainers.json)"

cat <<-EOH
# this file is generated via https://github.com/joomla-docker/docker-joomla/blob/$(fileCommit "$self")/$self

Maintainers: $joomlaMaintainers
GitRepo: https://github.com/joomla-docker/docker-joomla.git
EOH

# prints "$2$1$3$1...$N"
join() {
  local sep="$1"
  shift
  local out
  printf -v out "${sep//%/%%}%s" "$@"
  echo "${out#$sep}"
}

for version; do
  export version
  # get this Joomla versions PHP versions
  phpVersions="$(jq -r '.[env.version].phpVersions | map(@sh) | join(" ")' versions.json)"
  eval "phpVersions=( $phpVersions )"
  # get this Joomla versions default PHP version
  defaultPhpVersion="$(jq -r '.[env.version].php' versions.json)"
  # get this Joomla versions variants
  variants="$(jq -r '.[env.version].variants | map(@sh) | join(" ")' versions.json)"
  eval "variants=( $variants )"
  # get this Joomla versions default variant
  defaultVariant="$(jq -r '.[env.version].variant' versions.json)"
  # get the Joomla versions full version eg: 4.0.0
  fullVersion="$(jq -r '.[env.version].version' versions.json)"
  # check if this Joomla version is a Release Candidate
  rcVersion="${version%-rc}"
  versionAliases=()
  while [ "$fullVersion" != "$rcVersion" -a "${fullVersion%[.]*}" != "$fullVersion" ]; do
    versionAliases+=($fullVersion)
    fullVersion="${fullVersion%[.]*}"
  done
  # get all that aliases of this Joomla version
  aliases="$(jq -r '.[env.version].aliases | map(@sh) | join(" ")' versions.json)"
  eval "aliases=( $aliases )"
  # add the short version an all aliases found
  versionAliases+=(
    $version
    ${aliases[@]:-}
  )

  for phpVersion in "${phpVersions[@]}"; do
    phpVersion="php$phpVersion"
    for variant in "${variants[@]}"; do
      dir="$version/$phpVersion/$variant"
      # check if the docker file exist, else skip
      [ -f "$dir/Dockerfile" ] || continue
      # get the commit hash from this docker file
      commit="$(dirCommit "$dir")"

      phpVersionAliases=("${versionAliases[@]/%/-$phpVersion}")
      phpVersionAliases=("${phpVersionAliases[@]//latest-/}")

      variantSuffixes=("$variant")

      variantAliases=()
      phpVersionVariantAliases=()
      for variantSuffix in "${variantSuffixes[@]}"; do
        variantAliases+=("${versionAliases[@]/%/-$variantSuffix}")
        phpVersionVariantAliases+=("${phpVersionAliases[@]/%/-$variantSuffix}")
      done
      variantAliases=("${variantAliases[@]//latest-/}")
      phpVersionVariantAliases=("${phpVersionVariantAliases[@]//latest-/}")

      fullAliases=()
      if [ "$phpVersion" = "php$defaultPhpVersion" ] && [ "$variant" = "$defaultVariant" ]; then
        fullAliases+=("${versionAliases[@]}")
        fullAliases+=("${variantAliases[@]}")
        fullAliases+=("${phpVersionAliases[@]}")
      fi
      fullAliases+=("${phpVersionVariantAliases[@]}")

      variantParents="$(gawk "$gawkParents" "$dir/Dockerfile")"
      variantArches=
      for variantParent in $variantParents; do
        parentArches="${parentRepoToArches[$variantParent]:-}"
        if [ -z "$parentArches" ]; then
          continue
        elif [ -z "$variantArches" ]; then
          variantArches="$parentArches"
        else
          variantArches="$(
            comm -12 \
              <(xargs -n1 <<<"$variantArches" | sort -u) \
              <(xargs -n1 <<<"$parentArches" | sort -u)
          )"
        fi
      done

      echo
      cat <<-EOE
				Tags: $(join ', ' "${fullAliases[@]}")
				Architectures: $(join ', ' $variantArches)
				GitCommit: $commit
				Directory: $dir
			EOE
    done
  done
done
