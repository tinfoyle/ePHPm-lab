# RoadRunner benchmark image — PHP 8.4 + ext-sockets + ext-opcache + RoadRunner 2024
#
# Stage 1: install vendor deps via composer
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json .
# --no-blocking: suppress advisory PKSA-xbp4-qwr2-cbjj (informational, package rename notice, no CVE)
# --ignore-platform-req=ext-sockets: composer image lacks ext-sockets; it is built in stage 3
RUN composer install \
      --no-dev \
      --no-blocking \
      --no-progress \
      --no-interaction \
      --prefer-dist \
      --ignore-platform-req=ext-sockets

# Stage 2: pull the RoadRunner binary
FROM ghcr.io/roadrunner-server/roadrunner:2024 AS rr

# Stage 3: runtime image
FROM php:8.4-cli-alpine
RUN apk add --no-cache --virtual .build-deps linux-headers \
 && docker-php-ext-install sockets opcache \
 && apk del .build-deps \
 && printf 'opcache.enable=1\nopcache.enable_cli=1\nopcache.validate_timestamps=0\nopcache.jit_buffer_size=64M\nopcache.jit=tracing\n' \
    > /usr/local/etc/php/conf.d/opcache-rr.ini

WORKDIR /app
COPY --from=rr    /usr/bin/rr     /usr/local/bin/rr
COPY --from=vendor /app/vendor     ./vendor
COPY worker.php   .rr.yaml        ./

EXPOSE 8080
CMD ["rr", "serve", "-c", "/app/.rr.yaml"]
