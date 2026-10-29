# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/build/build.sh". DO NOT EDIT.
FROM joomla:6.2.0-php8.3-fpm

ENV JOOMLA_XDEBUG_CLIENT_HOST="host.docker.internal"
ENV JOOMLA_XDEBUG_CLIENT_PORT="9003"
ENV XDEBUG_MODE="develop,debug"

ARG COMPOSER_URL="https://getcomposer.org/download/2.10.3/composer.phar"
ARG COMPOSER_SHA256=7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6
ARG PIE_URL="https://github.com/php/pie/releases/download/1.5.2/pie.phar"
ARG PIE_SHA256=fe70c59738cf56ec00a818cf9cb9593da171aac86f5f1f859995b8839dfd2cc7

# Install PHP extensions and tools; remove temporary dependencies in this layer.
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		git \
		openssh-client \
		patch \
		unzip \
		zip \
		nodejs \
		python3 \
		make \
		g++ \
		jq \
		rsync \
		less \
		nano; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get install -y --no-install-recommends $PHPIZE_DEPS \
		npm; \
	DEB_BUILD_MULTIARCH="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
	docker-php-ext-install -j "$(nproc)" \
		pcntl \
		sockets; \
	curl --fail --show-error --silent --location \
		--retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
		--proto '=https' --proto-redir '=https' \
		"$COMPOSER_URL" --output /usr/local/bin/composer; \
	printf '%s *%s\n' "$COMPOSER_SHA256" /usr/local/bin/composer | sha256sum -c -; \
	chmod 0755 /usr/local/bin/composer; \
	curl --fail --show-error --silent --location \
		--retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
		--proto '=https' --proto-redir '=https' \
		"$PIE_URL" --output /tmp/pie; \
	printf '%s *%s\n' "$PIE_SHA256" /tmp/pie | sha256sum -c -; \
	chmod 0755 /tmp/pie; \
	PIE_WORKING_DIRECTORY=/tmp/joomla-pie /tmp/pie install --no-interaction --no-cache --make-parallel-jobs="$(nproc)" xdebug/xdebug:3.5.3; \
	npm_config_cache=/tmp/joomla-npm npm install --global --prefix /usr/local --no-audit --no-fund --engine-strict npm@11.21.1; \
	hash -r; \
	rm -rf /tmp/pie /tmp/joomla-pie /tmp/joomla-npm /tmp/pear /root/.cache; \
	extDir="$(php-config --extension-dir)"; \
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark; \
	ldd "$extDir"/*.so \
		| awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print "*" so }' \
		| sort -u \
		| xargs -r dpkg-query --search \
		| awk 'sub(":$", "", $1) { print $1 }' \
		| sort -u \
		| xargs -rt apt-mark manual; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*

# Configure and check the added development tools and PHP extensions.
RUN set -eux; \
	mkdir -p \
		/usr/local/etc/php/conf.d; \
	printf '%s\n' \
		'error_reporting = E_ALL' \
		'display_errors = On' \
		'display_startup_errors = On' \
		'ignore_repeated_errors = Off' \
		'opcache.validate_timestamps = 1' \
		'opcache.revalidate_freq = 0' \
		'opcache.jit = off' \
		'opcache.jit_buffer_size = 0' \
		> /usr/local/etc/php/conf.d/zz-joomla-development.ini; \
	printf '%s\n' \
		'xdebug.mode = develop,debug' \
		'xdebug.start_with_request = trigger' \
		'xdebug.start_upon_error = no' \
		'xdebug.discover_client_host = 0' \
		'xdebug.client_host = ${JOOMLA_XDEBUG_CLIENT_HOST}' \
		'xdebug.client_port = ${JOOMLA_XDEBUG_CLIENT_PORT}' \
		'xdebug.output_dir = /tmp' \
		> /usr/local/etc/php/conf.d/zz-xdebug-settings.ini; \
	if ! php --version 2> /tmp/php-startup-errors.txt; then cat /tmp/php-startup-errors.txt >&2; exit 1; fi; \
	if [ -s /tmp/php-startup-errors.txt ]; then cat /tmp/php-startup-errors.txt >&2; exit 1; fi; \
	php --ri pcntl > /dev/null; \
	php --ri sockets > /dev/null; \
	php --ri xdebug > /dev/null; \
	rm -f /tmp/php-startup-errors.txt; \
	composer --version; \
	npm --version; \
	npx --version
