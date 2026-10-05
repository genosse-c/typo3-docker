# syntax=docker/dockerfile:1
ARG PHP_VERSION=8.3

FROM composer:2 AS composer

FROM php:${PHP_VERSION}-fpm-bookworm

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git unzip graphicsmagick ghostscript libfcgi-bin \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libzip-dev libicu-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" gd intl mysqli pdo_mysql zip opcache exif; \
    rm -rf /var/lib/apt/lists/*

# Run PHP as the host user's UID/GID so files in the ./app bind mount stay editable on the host
RUN set -eux; \
    groupmod -o -g "${HOST_GID}" www-data; \
    usermod -o -u "${HOST_UID}" -g "${HOST_GID}" www-data; \
    mkdir -p /var/www/.composer; \
    chown -R www-data:www-data /var/www

COPY --from=composer /usr/bin/composer /usr/bin/composer

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY php.ini "$PHP_INI_DIR/conf.d/zz-typo3.ini"
COPY php-fpm.conf /usr/local/etc/php-fpm.d/zz-typo3.conf
COPY additional.php /usr/local/share/typo3-docker/additional.php
COPY entrypoint.sh /usr/local/bin/typo3-entrypoint
RUN chmod 0755 /usr/local/bin/typo3-entrypoint

ENV COMPOSER_HOME=/var/www/.composer
WORKDIR /var/www/html

ENTRYPOINT ["typo3-entrypoint"]
CMD ["php-fpm"]
