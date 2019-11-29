#!/bin/bash
set -eu

# Latest available version based on https://downloads.joomla.org/technical-requirements
defaultPhpVersion='php7.3'
defaultVariant='apache'

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

phpVersions=( php*.*/ )
phpVersions=( "${phpVersions[@]%/}" )

# get the most recent commit which modified any of "$@"
fileCommit() {
	git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
	local dir="$1"; shift
	(
		cd "$dir"
		fileCommit \
			Dockerfile \
			$(git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						print $i
					}
				}
			')
	)
}

getArches() {
	local repo="$1"; shift
	local officialImagesUrl='https://github.com/docker-library/official-images/raw/master/library/'

	eval "declare -g -A parentRepoToArches=( $(
		find -name 'Dockerfile' -exec awk '
				toupper($1) == "FROM" && $2 !~ /^('"$repo"'|scratch|microsoft\/[^:]+)(:|$)/ {
					print "'"$officialImagesUrl"'" $2
				}
			' '{}' + \
			| sort -u \
			| xargs bashbrew cat --format '[{{ .RepoName }}:{{ .TagName }}]="{{ join " " .TagEntry.Architectures }}"'
	) )"
}
getArches 'joomla'

cat <<-EOH
# this file is generated via https://github.com/joomla/docker-joomla/blob/$(fileCommit "$self")/$self

Maintainers: Michael Babker <michael.babker@joomla.org> (@mbabker)
GitRepo: https://github.com/joomla/docker-joomla.git
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for phpVersion in "${phpVersions[@]}"; do
	for variant in apache fpm fpm-alpine; do
		dir="$phpVersion/$variant"
		[ -f "$dir/Dockerfile" ] || continue

		commit="$(dirCommit "$dir")"

		fullVersion="$(git show "$commit":"$dir/Dockerfile" | awk '$1 == "ENV" && $2 == "JOOMLA_VERSION" { print $3; exit }')"
		if [[ "$fullVersion" != *.*.* && "$fullVersion" == *.* ]]; then
			fullVersion+='.0'
		fi

		versionAliases=()
		while [ "${fullVersion%[.-]*}" != "$fullVersion" ]; do
			versionAliases+=( $fullVersion )
			fullVersion="${fullVersion%[.-]*}"
		done
		versionAliases+=(
			$fullVersion
			latest
		)

		phpVersionAliases=( "${versionAliases[@]/%/-$phpVersion}" )
		phpVersionAliases=( "${phpVersionAliases[@]//latest-/}" )

		variantAliases=( "${versionAliases[@]/%/-$variant}" )
		variantAliases=( "${variantAliases[@]//latest-/}" )

		phpVersionVariantAliases=( "${versionAliases[@]/%/-$phpVersion-$variant}" )
		phpVersionVariantAliases=( "${phpVersionVariantAliases[@]//latest-/}" )

		fullAliases=()

		if [ "$phpVersion" = "$defaultPhpVersion" ]; then
			fullAliases+=( "${variantAliases[@]}" )

			if [ "$variant" = "$defaultVariant" ]; then
				fullAliases+=( "${versionAliases[@]}" )
			fi
		fi

		fullAliases+=(
			"${phpVersionVariantAliases[@]}"
		)

		if [ "$variant" = "$defaultVariant" ]; then
			fullAliases+=( "${phpVersionAliases[@]}" )
		fi

		variantParent="$(awk 'toupper($1) == "FROM" { print $2 }' "$dir/Dockerfile")"
		variantArches="${parentRepoToArches[$variantParent]}"

		echo
		cat <<-EOE
			Tags: $(join ', ' "${fullAliases[@]}")
			Architectures: $(join ', ' $variantArches)
			GitCommit: $commit
			Directory: $dir
		EOE
	done
done
