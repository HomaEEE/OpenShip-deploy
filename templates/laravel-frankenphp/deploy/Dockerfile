FROM dunglas/frankenphp:1-php8.4-bookworm AS base

# Install system dependencies & PHP extensions
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    unzip \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    && rm -rf /var/lib/apt/lists/*

RUN install-php-extensions \
    bcmath \
    ctype \
    curl \
    dom \
    fileinfo \
    filter \
    gd \
    hash \
    intl \
    mbstring \
    opcache \
    openssl \
    pcntl \
    pcre \
    pdo \
    pdo_mysql \
    redis \
    session \
    tokenizer \
    xml \
    xmlwriter \
    zip

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app

# Copy configuration
COPY deploy/Caddyfile /etc/caddy/Caddyfile
COPY deploy/php.ini $PHP_INI_DIR/conf.d/99-custom.ini
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Application files
COPY . .

# Composer install
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader

# Permissions
RUN chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
