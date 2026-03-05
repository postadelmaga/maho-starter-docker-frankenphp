FROM dunglas/frankenphp:1-php8.3-alpine

RUN apk add --no-cache bash

RUN install-php-extensions \
    gd \
    intl \
    pdo_mysql \
    mysqli \
    zip \
    bcmath \
    soap \
    opcache \
    exif \
    pcntl \
    xdebug \
    ftp \
    sockets \
    @composer

ARG USER_ID=1000

RUN adduser -D -u ${USER_ID} appuser && \
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp && \
    mkdir -p /data/caddy /config/caddy && \
    chown -R appuser:appuser /data/caddy /config/caddy

USER appuser

WORKDIR /app
