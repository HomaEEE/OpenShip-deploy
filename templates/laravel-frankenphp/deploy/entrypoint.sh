#!/bin/sh
set -e

echo "==> Bootstrapping application environment..."

# ------------------------------------------------------------------------------
# 1. Resolve MariaDB Host
# ------------------------------------------------------------------------------
TARGET_DB_PORT="${DB_PORT:-3306}"
INITIAL_DB_HOST="${DB_HOST:-mariadb}"

probe_db() {
    php -r "
        \$fp = @fsockopen('$1', (int)'$2', \$errno, \$errstr, 2);
        if (\$fp) { fclose(\$fp); exit(0); }
        exit(1);
    " 2>/dev/null
}

if probe_db "$INITIAL_DB_HOST" "$TARGET_DB_PORT"; then
    RESOLVED_DB_HOST="$INITIAL_DB_HOST"
else
    echo "==> Notice: '$INITIAL_DB_HOST:$TARGET_DB_PORT' unreachable. Probing fallback hosts..."
    for candidate in mariadb openship-mariadb openship-deploy-mariadb mariadb-redis-mariadb; do
        if probe_db "$candidate" "$TARGET_DB_PORT"; then
            RESOLVED_DB_HOST="$candidate"
            echo "==> Discovered MariaDB at '$RESOLVED_DB_HOST'"
            break
        fi
    done
fi

export DB_HOST="${RESOLVED_DB_HOST:-$INITIAL_DB_HOST}"

# ------------------------------------------------------------------------------
# 2. Resolve Redis Host
# ------------------------------------------------------------------------------
TARGET_REDIS_PORT="${REDIS_PORT:-6379}"
INITIAL_REDIS_HOST="${REDIS_HOST:-redis}"

probe_redis() {
    php -r "
        \$fp = @fsockopen('$1', (int)'$2', \$errno, \$errstr, 2);
        if (\$fp) { fclose(\$fp); exit(0); }
        exit(1);
    " 2>/dev/null
}

if probe_redis "$INITIAL_REDIS_HOST" "$TARGET_REDIS_PORT"; then
    RESOLVED_REDIS_HOST="$INITIAL_REDIS_HOST"
else
    echo "==> Notice: '$INITIAL_REDIS_HOST:$TARGET_REDIS_PORT' unreachable. Probing fallback hosts..."
    for candidate in redis openship-redis openship-deploy-redis mariadb-redis-redis; do
        if probe_redis "$candidate" "$TARGET_REDIS_PORT"; then
            RESOLVED_REDIS_HOST="$candidate"
            echo "==> Discovered Redis at '$RESOLVED_REDIS_HOST'"
            break
        fi
    done
fi

export REDIS_HOST="${RESOLVED_REDIS_HOST:-$INITIAL_REDIS_HOST}"

# ------------------------------------------------------------------------------
# 3. Auto-Provision Database and User via PDO
# ------------------------------------------------------------------------------
export DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-openship_root_secret}"

php -r '
$host = getenv("DB_HOST");
$port = (int)(getenv("DB_PORT") ?: 3306);
$rootPass = getenv("DB_ROOT_PASSWORD");
$dbName = preg_replace("/[^a-zA-Z0-9_]/", "", getenv("DB_DATABASE"));
$dbUser = preg_replace("/[^a-zA-Z0-9_]/", "", getenv("DB_USERNAME"));
$dbPass = getenv("DB_PASSWORD");

if (empty($dbName) || empty($dbUser)) {
    echo "==> DB_DATABASE or DB_USERNAME not set. Skipping auto-provisioning.\n";
    exit(0);
}

try {
    $pdo = new PDO("mysql:host={$host};port={$port}", "root", $rootPass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 3,
    ]);
    
    $quotedPass = $pdo->quote($dbPass);
    $pdo->exec("CREATE DATABASE IF NOT EXISTS `{$dbName}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
    $pdo->exec("CREATE USER IF NOT EXISTS \"{$dbUser}\"@\"%\" IDENTIFIED BY {$quotedPass}");
    $pdo->exec("ALTER USER \"{$dbUser}\"@\"%\" IDENTIFIED BY {$quotedPass}");
    $pdo->exec("GRANT ALL PRIVILEGES ON `{$dbName}`.* TO \"{$dbUser}\"@\"%\"");
    $pdo->exec("FLUSH PRIVILEGES");

    echo "==> MariaDB: Database [{$dbName}] and user [{$dbUser}] ready.\n";
} catch (\Throwable $e) {
    echo "==> MariaDB auto-provision notice: " . $e->getMessage() . "\n";
}
'

# Security: clear root password from memory
unset DB_ROOT_PASSWORD
export DB_ROOT_PASSWORD=""

# ------------------------------------------------------------------------------
# 4. Wait for Database Readiness with Project Credentials
# ------------------------------------------------------------------------------
echo "==> Checking database connection at ${DB_HOST}:${DB_PORT}..."
MAX_TRIES=30
COUNT=0

until php -r '
$host = getenv("DB_HOST");
$port = (int)(getenv("DB_PORT") ?: 3306);
$db = getenv("DB_DATABASE");
$user = getenv("DB_USERNAME");
$pass = getenv("DB_PASSWORD");

try {
    $dsn = "mysql:host={$host};port={$port}" . ($db ? ";dbname={$db}" : "");
    new PDO($dsn, $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 2,
    ]);
    exit(0);
} catch (\Throwable $e) {
    echo $e->getMessage();
    exit(1);
}
' 2>/dev/null; do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge "$MAX_TRIES" ]; then
        echo "==> ERROR: Database connection timed out after ${MAX_TRIES} attempts."
        exit 1
    fi
    echo "==> Waiting for database ($COUNT/$MAX_TRIES)..."
    sleep 2
done

echo "==> Database connected successfully."

# ------------------------------------------------------------------------------
# 5. Application Setup & Migrations
# ------------------------------------------------------------------------------
php artisan storage:link --quiet || true
php artisan optimize:clear

echo "==> Running database migrations..."
php artisan migrate --force

# Run module migrations if present
if [ -d "Modules" ]; then
    for module_mig in Modules/*/database/migrations Modules/*/Database/Migrations; do
        if [ -d "$module_mig" ]; then
            php artisan migrate --path="$module_mig" --force || true
        fi
    done
fi

# ------------------------------------------------------------------------------
# 6. Production Caching
# ------------------------------------------------------------------------------
if [ "${APP_ENV:-production}" = "production" ]; then
    echo "==> Caching configuration for production..."
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan icons:cache 2>/dev/null || true
    php artisan filament:cache-components 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 7. Start FrankenPHP
# ------------------------------------------------------------------------------
echo "==> Starting FrankenPHP on port 80..."
exec frankenphp run --config /etc/caddy/Caddyfile
