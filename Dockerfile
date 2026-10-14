FROM alpine:3.21 AS source-code
RUN apk add --no-cache unzip
WORKDIR /src
COPY kharcha-source.zip ./
RUN unzip -q kharcha-source.zip -d /src && rm kharcha-source.zip

FROM node:22-alpine AS frontend-build
WORKDIR /build/frontend
COPY --from=source-code /src/frontend/package.json /src/frontend/package-lock.json ./
RUN npm ci
COPY --from=source-code /src/frontend/ ./
ARG VITE_API_URL=/api
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build

FROM composer:2 AS php-dependencies
WORKDIR /build/backend
COPY --from=source-code /src/backend/ ./
RUN rm -f bootstrap/cache/packages.php bootstrap/cache/services.php bootstrap/cache/config.php \
    && composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader

FROM php:8.4-apache
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev libzip-dev \
    && docker-php-ext-install pdo_mysql pdo_pgsql zip opcache \
    && a2enmod rewrite headers \
    && sed -ri 's!/var/www/html!/var/www/html/public!g' /etc/apache2/sites-available/000-default.conf \
    && sed -ri 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
    && sed -ri 's/Listen 80/Listen 10000/' /etc/apache2/ports.conf \
    && sed -ri 's/\*:80/\*:10000/' /etc/apache2/sites-available/000-default.conf \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
COPY --from=source-code /src/backend/ ./
COPY --from=php-dependencies /build/backend/vendor ./vendor
COPY --from=php-dependencies /build/backend/bootstrap/cache/packages.php ./bootstrap/cache/packages.php
COPY --from=php-dependencies /build/backend/bootstrap/cache/services.php ./bootstrap/cache/services.php
COPY --from=frontend-build /build/frontend/dist/ ./public/
RUN rm -f bootstrap/cache/config.php \
    && mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache

ENV PORT=10000
EXPOSE 10000
CMD ["sh", "-c", "php artisan migrate --force && php artisan config:cache && exec apache2-foreground"]
