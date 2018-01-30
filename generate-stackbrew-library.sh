#!/bin/bash
set -eu

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

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

for variant in apache apache-php7.0 apache-php7.1 fpm fpm-php7.0 fpm-php7.1; do
	commit="$(dirCommit "$variant")"

	fullVersion="$(git show "$commit":"$variant/Dockerfile" | awk '$1 == "ENV" && $2 == "JOOMLA_VERSION" { print $3; exit }')"
	if [[ "$fullVersion" != *.*.* && "$fullVersion" == *.* ]]; then
		fullVersion+='.0'
	fi

	versionAliases=()
	while [ "${fullVersion%.*}" != "$fullVersion" ]; do
		versionAliases+=( $fullVersion )
		fullVersion="${fullVersion%.*}"
	done
	versionAliases+=(
		$fullVersion
		latest
	)

	variantAliases=( "${versionAliases[@]/%/-$variant}" )
	variantAliases=( "${variantAliases[@]//latest-/}" )

	if [ "$variant" = 'apache' ]; then
		variantAliases+=( "${versionAliases[@]}" )
	fi

	echo
	cat <<-EOE
		Tags: $(join ', ' "${variantAliases[@]}")
		GitCommit: $commit
		Directory: $variant
	EOE
done
