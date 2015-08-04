#!/bin/bash
set -e

# TODO - We (Joomla) need to expose an alternate API to checking the latest version other than our XML files
current="$(curl -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/44.0.2403.89 Safari/537.36' -sSL 'http://developer.joomla.org/latest_version.json' | sed -r 's/^.*"current":"([^"]+)".*$/\1/')"

upstream="$current"
if [[ "$current" != *.*.* ]]; then
	# turn "3.4" into "3.4.0"
	current+='.0'
fi

# We're putting a lot of trust in this process, once Joomla has an exposed API to query the SHA1 use that instead
wget -O joomla.zip https://github.com/joomla/joomla-cms/releases/download/$upstream/Joomla_$upstream-Stable-Full_Package.zip
sha1="$(sha1sum joomla.zip | sed -r 's/ .*//')"

for variant in apache fpm; do
	(
		set -x

		sed -ri '
			s/^(ENV JOOMLA_VERSION) .*/\1 '"$current"'/;
			s/^(ENV JOOMLA_UPSTREAM_VERSION) .*/\1 '"$upstream"'/;
			s/^(ENV JOOMLA_SHA1) .*/\1 '"$sha1"'/;
		' "$variant/Dockerfile"

        # To make management easier, we use these files for all variants
		cp docker-entrypoint.sh "$variant/docker-entrypoint.sh"
		cp makedb.php "$variant/makedb.php"
	)
done

rm joomla.zip
