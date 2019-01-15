FROM php:7.1-fpm-alpine
LABEL maintainer="Michael Babker <michael.babker@joomla.org> (@mbabker)"

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
		libjpeg-turbo-dev \
		libmcrypt-dev \
		libmemcached-dev \
		libpng-dev \
		openldap-dev \
		pcre-dev \
		postgresql-dev \
	; \
	\
	docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr; \
	docker-php-ext-configure ldap; \
	docker-php-ext-install \
		bz2 \
		gd \
		ldap \
		mcrypt \
		mysqli \
		pdo_mysql \
		pdo_pgsql \
		pgsql \
		zip \
	; \
	\
# pecl will claim success even if one install fails, so we need to perform each install separately
	pecl install APCu-5.1.16; \
	pecl install memcached-3.1.3; \
	pecl install redis-4.2.0; \
	\
	docker-php-ext-enable \
		apcu \
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
ENV JOOMLA_VERSION 3.9.2
ENV JOOMLA_SHA512 b6b551748a683bbdf7185f99092708257b6b1483e8ef4e762f5341f7479cd698cf2e309d4004a4eabafdf5f388518c426f2f1fb19c0003fa8dff215317102a95

# Download package and extract to web volume
RUN curl -o joomla.tar.bz2 -SL https://github.com/joomla/joomla-cms/releases/download/${JOOMLA_VERSION}/Joomla_${JOOMLA_VERSION}-Stable-Full_Package.tar.bz2 \
	&& echo "$JOOMLA_SHA512 *joomla.tar.bz2" | sha512sum -c - \
	&& mkdir /usr/src/joomla \
	&& tar -xf joomla.tar.bz2 -C /usr/src/joomla \
	&& rm joomla.tar.bz2 \
	&& chown -R www-data:www-data /usr/src/joomla

# Copy init scripts and custom .htaccess
COPY docker-entrypoint.sh /entrypoint.sh
COPY makedb.php /makedb.php

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
