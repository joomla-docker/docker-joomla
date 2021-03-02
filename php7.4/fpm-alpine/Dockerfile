FROM php:7.4-fpm-alpine
LABEL maintainer="Harald Leithner <harald.leithner@community.joomla.org> (@HLeithner)"

# Disable remote database security requirements.
ENV JOOMLA_INSTALLATION_DISABLE_LOCALHOST_CHECK=1

# entrypoint.sh dependencies
RUN apk add --no-cache \
	bash

# Install PHP extensions
RUN set -ex; \
	\
	apk add --no-cache --virtual .build-deps \
		$PHPIZE_DEPS \
		autoconf \
		bzip2-dev \
		gmp-dev \
		libjpeg-turbo-dev \
		libmcrypt-dev \
		libmemcached-dev \
		libpng-dev \
		libzip-dev \
		openldap-dev \
		pcre-dev \
		postgresql-dev \
	; \
	\
	docker-php-ext-configure gd --with-jpeg; \
	docker-php-ext-configure ldap; \
	docker-php-ext-install -j "$(nproc)" \
		bz2 \
		gd \
		gmp \
		ldap \
		mysqli \
		pdo_mysql \
		pdo_pgsql \
		pgsql \
		zip \
	; \
	\
# pecl will claim success even if one install fails, so we need to perform each install separately
	pecl install APCu-5.1.19; \
	pecl install mcrypt-1.0.3; \
	pecl install memcached-3.1.5; \
	pecl install redis-4.3.0; \
	\
	docker-php-ext-enable \
		apcu \
		mcrypt \
		memcached \
		redis \
	; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
		| tr ',' '\n' \
		| sort -u \
		| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
		)"; \
	apk add --virtual .joomla-phpext-rundeps $runDeps; \
	apk del .build-deps

VOLUME /var/www/html

# Define Joomla version and expected SHA1 signature
ENV JOOMLA_VERSION 3.9.25
ENV JOOMLA_SHA512 83fc90cb09d710e30dc8e8f50c4e6074ab74fb6a431a851b2567e30273e2a27686d9702cc0cdbae7dc2db09efa0081f8418064b691de43fee1af15f7a195fa25

# Download package and extract to web volume
RUN set -ex; \
	curl -o joomla.tar.bz2 -SL https://github.com/joomla/joomla-cms/releases/download/${JOOMLA_VERSION}/Joomla_${JOOMLA_VERSION}-Stable-Full_Package.tar.bz2; \
	echo "$JOOMLA_SHA512 *joomla.tar.bz2" | sha512sum -c -; \
	mkdir /usr/src/joomla; \
	tar -xf joomla.tar.bz2 -C /usr/src/joomla; \
	rm joomla.tar.bz2; \
	chown -R www-data:www-data /usr/src/joomla

# Copy init scripts and custom .htaccess
COPY docker-entrypoint.sh /entrypoint.sh
COPY makedb.php /makedb.php

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
