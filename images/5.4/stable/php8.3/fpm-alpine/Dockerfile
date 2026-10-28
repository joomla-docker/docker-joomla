# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/build/build.sh". DO NOT EDIT.
FROM php:8.3-fpm-alpine3.24

LABEL org.opencontainers.image.authors="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Harald Leithner <harald.leithner@community.joomla.org> (@HLeithner)"

ENV JOOMLA_INSTALLATION_DISABLE_LOCALHOST_CHECK="1"

ARG PIE_URL="https://github.com/php/pie/releases/download/1.5.2/pie.phar"
ARG PIE_SHA256=fe70c59738cf56ec00a818cf9cb9593da171aac86f5f1f859995b8839dfd2cc7

# Install PHP extensions and tools; remove temporary dependencies in this layer.
RUN set -eux; \
	apk add --no-cache \
		bash \
		ghostscript \
		imagemagick; \
	apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
		autoconf \
		bzip2-dev \
		gmp-dev \
		icu-dev \
		freetype-dev \
		imagemagick-dev \
		libjpeg-turbo-dev \
		libmemcached-dev \
		libpng-dev \
		libwebp-dev \
		libzip-dev \
		openldap-dev \
		pcre-dev \
		postgresql-dev \
		automake \
		libtool \
		linux-headers \
		zlib-dev \
		unzip; \
	docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
	docker-php-ext-configure ldap; \
	docker-php-ext-install -j "$(nproc)" \
		bz2 \
		bcmath \
		exif \
		gd \
		gmp \
		intl \
		ldap \
		mysqli \
		pdo_mysql \
		pdo_pgsql \
		pgsql \
		zip; \
	curl --fail --show-error --silent --location \
		--retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
		--proto '=https' --proto-redir '=https' \
		"$PIE_URL" --output /tmp/pie; \
	printf '%s *%s\n' "$PIE_SHA256" /tmp/pie | sha256sum -c -; \
	chmod 0755 /tmp/pie; \
	PIE_WORKING_DIRECTORY=/tmp/joomla-pie /tmp/pie install --no-interaction --no-cache --make-parallel-jobs="$(nproc)" apcu/apcu:5.1.27; \
	PIE_WORKING_DIRECTORY=/tmp/joomla-pie /tmp/pie install --no-interaction --no-cache --make-parallel-jobs="$(nproc)" imagick/imagick:3.8.0; \
	PIE_WORKING_DIRECTORY=/tmp/joomla-pie /tmp/pie install --no-interaction --no-cache --make-parallel-jobs="$(nproc)" php-memcached/php-memcached:3.4.0; \
	PIE_WORKING_DIRECTORY=/tmp/joomla-pie /tmp/pie install --no-interaction --no-cache --make-parallel-jobs="$(nproc)" phpredis/phpredis:6.3.0; \
	docker-php-ext-enable \
		opcache; \
	rm -rf /tmp/pie /tmp/joomla-pie /tmp/joomla-npm /tmp/pear /root/.cache; \
	extDir="$(php-config --extension-dir)"; \
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive "$extDir" \
		| tr ',' '\n' \
		| sort -u \
		| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
		)"; \
	apk add --no-network --virtual .joomla-phpexts-rundeps $runDeps; \
	apk del --no-network .build-deps

# Configure and check PHP, extensions, tools and the web server after cleanup.
RUN set -eux; \
	mkdir -p \
		/usr/local/etc/php \
		/usr/local/etc/php/conf.d; \
	printf '%s\n' \
		'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR' \
		'display_errors = Off' \
		'display_startup_errors = Off' \
		'log_errors = On' \
		'error_log = /dev/stderr' \
		'ignore_repeated_errors = On' \
		'ignore_repeated_source = Off' \
		'html_errors = Off' \
		> /usr/local/etc/php/conf.d/error-logging.ini; \
	printf '%s\n' \
		'expose_php = Off' \
		> /usr/local/etc/php/conf.d/expose-php.ini; \
	printf '%s\n' \
		opcache.memory_consumption=128 \
		opcache.interned_strings_buffer=8 \
		opcache.max_accelerated_files=4000 \
		opcache.revalidate_freq=2 \
		> /usr/local/etc/php/conf.d/opcache-recommended.ini; \
	printf '%s\n' \
		'; Opt-in PHP hardening.' \
		'; Retained outside conf.d; the entrypoint copies it when JOOMLA_SECURITY_HARDENED=true.' \
		'expose_php = Off' \
		'session.cookie_httponly = On' \
		'session.cookie_secure = On' \
		'session.use_strict_mode = On' \
		'session.use_cookies = On' \
		'session.use_only_cookies = On' \
		'session.cookie_samesite = Lax' \
		'allow_url_include = Off' \
		'zend.exception_ignore_args = On' \
		'session.upload_progress.enabled = Off' \
		> /usr/local/etc/php/joomla-hardening.ini; \
	if ! php --version 2> /tmp/php-startup-errors.txt; then cat /tmp/php-startup-errors.txt >&2; exit 1; fi; \
	if [ -s /tmp/php-startup-errors.txt ]; then cat /tmp/php-startup-errors.txt >&2; exit 1; fi; \
	php --ri 'Zend OPcache' > /dev/null; \
	php --ri apcu > /dev/null; \
	php --ri bcmath > /dev/null; \
	php --ri bz2 > /dev/null; \
	php --ri exif > /dev/null; \
	php --ri gd > /dev/null; \
	php --ri gmp > /dev/null; \
	php --ri imagick > /dev/null; \
	php --ri intl > /dev/null; \
	php --ri ldap > /dev/null; \
	php --ri memcached > /dev/null; \
	php --ri mysqli > /dev/null; \
	php --ri pdo_mysql > /dev/null; \
	php --ri pdo_pgsql > /dev/null; \
	php --ri pgsql > /dev/null; \
	php --ri redis > /dev/null; \
	php --ri zip > /dev/null; \
	rm -f /tmp/php-startup-errors.txt; \
	php-fpm -t

# Joomla release changes reuse the PHP extension and configuration layers.
ENV JOOMLA_VERSION=5.4.10
ARG JOOMLA_URL="https://github.com/joomla/joomla-cms/releases/download/5.4.10/Joomla_5.4.10-Stable-Full_Package.tar.zst"
ENV JOOMLA_SHA512=31a29996d6234aa8d73384abd9ad91a1b7865cef79a17e747c389164ecf5f7c47deefcb38cd18ebf57eb409d10f531152c390caf7da50e6ad403acc32c791832

RUN set -eux; \
	apk add --no-cache --virtual .joomla-extract-deps \
		zstd; \
	curl --fail --show-error --silent --location \
		--retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
		--proto '=https' --proto-redir '=https' \
		"$JOOMLA_URL" --output /tmp/joomla.tar.zst; \
	printf '%s *%s\n' "$JOOMLA_SHA512" /tmp/joomla.tar.zst | sha512sum -c -; \
	mkdir -p /usr/src/joomla; \
	tar --zstd -xf /tmp/joomla.tar.zst -C /usr/src/joomla --no-same-owner; \
	test -s /usr/src/joomla/index.php; \
	test -s /usr/src/joomla/cli/joomla.php; \
	chown -R www-data:www-data /usr/src/joomla; \
	rm -f /tmp/joomla.tar.zst; \
	apk del --no-network .joomla-extract-deps

VOLUME ["/var/www/html"]
WORKDIR /var/www/html

COPY docker-entrypoint.sh /entrypoint.sh
COPY makedb.php /makedb.php

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
