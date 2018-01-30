FROM php:7.2-fpm
LABEL maintainer="Michael Babker <michael.babker@joomla.org> (@mbabker)"

# Disable remote database security requirements.
ENV JOOMLA_INSTALLATION_DISABLE_LOCALHOST_CHECK=1

# Install PHP extensions
RUN apt-get update && apt-get install -y libpng-dev libjpeg-dev zip unzip && rm -rf /var/lib/apt/lists/* \
	&& docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr \
	&& docker-php-ext-install gd
RUN docker-php-ext-install mysqli
RUN docker-php-ext-install zip

VOLUME /var/www/html

# Define Joomla version and expected SHA1 signature
ENV JOOMLA_VERSION 3.8.4
ENV JOOMLA_SHA1 3d8a321e626cdf3823fc6bd62aee222fd12c19ec

# Download package and extract to web volume
RUN curl -o joomla.zip -SL https://github.com/joomla/joomla-cms/releases/download/${JOOMLA_VERSION}/Joomla_${JOOMLA_VERSION}-Stable-Full_Package.zip \
	&& echo "$JOOMLA_SHA1 *joomla.zip" | sha1sum -c - \
	&& mkdir /usr/src/joomla \
	&& unzip joomla.zip -d /usr/src/joomla \
	&& rm joomla.zip \
	&& chown -R www-data:www-data /usr/src/joomla

# Copy init scripts and custom .htaccess
COPY docker-entrypoint.sh /entrypoint.sh
COPY makedb.php /makedb.php

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
