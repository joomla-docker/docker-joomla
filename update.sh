#!/bin/bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

phpVersions=( "$@" )
if [ ${#phpVersions[@]} -eq 0 ]; then
	phpVersions=( php*.*/ )
fi
phpVersions=( "${phpVersions[@]%/}" )

current="$(curl -fsSL 'https://downloads.joomla.org/api/v1/latest/cms' | jq -r '.branches[3].version')"
urlVersion=$(echo $current | sed -e 's/\./-/g')
sha512="$(curl -fsSL "https://downloads.joomla.org/api/v1/signatures/cms/$urlVersion"  | jq -r --arg file "Joomla_${current}-Stable-Full_Package.tar.bz2" '.[] | .[] | select(.filename == $file).sha512')"

declare -A variantExtras=(
	[apache]='\n# Enable Apache Rewrite Module\nRUN a2enmod rewrite\n'
	[fpm]=''
	[fpm-alpine]=''
)
declare -A variantCmds=(
	[apache]='apache2-foreground'
	[fpm]='php-fpm'
	[fpm-alpine]='php-fpm'
)
declare -A variantBases=(
	[apache]='debian'
	[fpm]='debian'
	[fpm-alpine]='alpine'
)
declare -A pecl_versions=(
	[php7-APCu]='5.1.18'
	[php7-memcached]='3.1.5'
	[php7-redis]='4.3.0'
)

travisEnv=
for phpVersion in "${phpVersions[@]}"; do
	phpVersionDir="$phpVersion"
	phpVersion="${phpVersion#php}"
	phpMajorVersion=$(echo $phpVersionDir | cut -d. -f1)

	for variant in apache fpm fpm-alpine; do
		dir="$phpVersionDir/$variant"
		mkdir -p "$dir"

		extras="${variantExtras[$variant]}"
		cmd="${variantCmds[$variant]}"
		base="${variantBases[$variant]}"

		entrypoint='docker-entrypoint.sh'

		(
			set -x

			sed -r \
				-e 's!%%VERSION%%!'"$current"'!g' \
				-e 's!%%SHA512%%!'"$sha512"'!g' \
				-e 's!%%PHP_VERSION%%!'"$phpVersion"'!g' \
				-e 's!%%VARIANT%%!'"$variant"'!g' \
				-e 's!%%VARIANT_EXTRAS%%!'"$extras"'!g' \
				-e 's!%%APCU_VERSION%%!'"${pecl_versions[$phpMajorVersion-APCu]}"'!g' \
				-e 's!%%MEMCACHED_VERSION%%!'"${pecl_versions[$phpMajorVersion-memcached]}"'!g' \
				-e 's!%%REDIS_VERSION%%!'"${pecl_versions[$phpMajorVersion-redis]}"'!g' \
				-e 's!%%CMD%%!'"$cmd"'!g' \
				"Dockerfile-${base}.template" > "$dir/Dockerfile"

			cp -a "$entrypoint" "$dir/docker-entrypoint.sh"
			cp -a "makedb.php" "$dir/makedb.php"

			if [ "$phpVersion" = 7.2 ]; then
				sed -ri \
					-e '/libzip-dev/d' \
					"$dir/Dockerfile"
			fi
			case "$phpVersion" in
				7.2 | 7.3 )
					sed -ri \
						-e 's!gd --with-jpeg!gd --with-jpeg-dir=/usr --with-png-dir=/usr!g' \
						"$dir/Dockerfile"
					;;
			esac

		)

		travisEnv+='\n  - VARIANT='"$dir"
	done
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
