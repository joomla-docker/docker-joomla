#!/bin/bash
set -e

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

url='git://github.com/joomla/docker-joomla'

echo '# maintainer: Michael Babker <michael.babker@joomla.org> (@mbabker)'

defaultVariant='apache'

for variant in apache apache-php7 fpm fpm-php7; do
	commit="$(git log -1 --format='format:%H' -- "$variant")"
	fullVersion="$(grep -m1 'ENV JOOMLA_VERSION ' "$variant/Dockerfile" | cut -d' ' -f3)"

	versionAliases=()
	while [ "${fullVersion%.*}" != "$fullVersion" ]; do
		versionAliases+=( $fullVersion-$variant )
		if [ "$variant" = "$defaultVariant" ]; then
			versionAliases+=( $fullVersion )
		fi
		fullVersion="${fullVersion%.*}"
	done
	versionAliases+=( $fullVersion-$variant $variant )
	if [ "$variant" = "$defaultVariant" ]; then
		versionAliases+=( $fullVersion latest )
	fi

	echo
	for va in "${versionAliases[@]}"; do
		echo "$va: ${url}@${commit} $variant"
	done
done
