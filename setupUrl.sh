#!/bin/bash
set -e

# Load .env
test -f .env && source .env

dc="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  dc="docker-compose"
fi

DB_HOST="${DB_HOST:-db}"
MYSQL_DATABASE="${MYSQL_DATABASE:-maho}"
MYSQL_USER="${MYSQL_USER:-maho_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-maho_password}"

# --- Show current values ---
echo ""
echo "Current URLs:"
$dc run --rm app mariadb -h"$DB_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --skip-ssl "$MYSQL_DATABASE" -e "
SELECT scope, scope_id, path, value
FROM core_config_data
WHERE path IN ('web/unsecure/base_url', 'web/secure/base_url')
ORDER BY scope, scope_id;" 2>/dev/null
echo ""

# --- Ask for new values ---
read -p "New FRONTEND URL (e.g. https://myshop.com/) [leave empty to keep current]: " NEW_FRONTEND
read -p "New ADMIN URL   (e.g. https://admin.myshop.com/) [leave empty to keep current]: " NEW_ADMIN

if [[ -z "$NEW_FRONTEND" && -z "$NEW_ADMIN" ]]; then
  echo "Nothing to change. Exiting."
  exit 0
fi

# --- Build SQL ---
SQL=""

if [[ -n "$NEW_FRONTEND" ]]; then
  # Ensure trailing slash
  [[ "$NEW_FRONTEND" != */ ]] && NEW_FRONTEND="${NEW_FRONTEND}/"
  SQL+="
  INSERT INTO core_config_data (scope, scope_id, path, value) VALUES
    ('default', 0, 'web/unsecure/base_url', '$NEW_FRONTEND'),
    ('default', 0, 'web/secure/base_url',   '$NEW_FRONTEND')
  ON DUPLICATE KEY UPDATE value = VALUES(value);"
fi

if [[ -n "$NEW_ADMIN" ]]; then
  [[ "$NEW_ADMIN" != */ ]] && NEW_ADMIN="${NEW_ADMIN}/"
  SQL+="
  INSERT INTO core_config_data (scope, scope_id, path, value) VALUES
    ('stores', 0, 'web/unsecure/base_url', '$NEW_ADMIN'),
    ('stores', 0, 'web/secure/base_url',   '$NEW_ADMIN')
  ON DUPLICATE KEY UPDATE value = VALUES(value);"
fi

# --- Apply ---
echo "Applying changes..."
$dc run --rm app mariadb -h"$DB_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --skip-ssl "$MYSQL_DATABASE" -e "$SQL" 2>/dev/null

# --- Flush cache ---
echo "Flushing Maho cache..."
$dc run --rm app ./maho cache:flush

# --- Show updated values ---
echo ""
echo "Updated URLs:"
$dc run --rm app mariadb -h"$DB_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --skip-ssl "$MYSQL_DATABASE" -e "
SELECT scope, scope_id, path, value
FROM core_config_data
WHERE path IN ('web/unsecure/base_url', 'web/secure/base_url')
ORDER BY scope, scope_id;" 2>/dev/null
echo ""
echo "✅ Done!"