#!/bin/bash
set -e

# Detect "docker compose" or "docker-compose"
dc="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  if ! command -v docker-compose >/dev/null 2>&1; then
    echo "Please first install docker compose."
    exit 1
  else
    dc="docker-compose"
  fi
fi

# Copy env.example to .env if it doesn't exist
if [ ! -f .env ]; then
    cp env.example .env
    echo ".env created from env.example"
fi

# Set UID to the current user's value
sed -i "s/^USER_ID=.*/USER_ID=$(id -u)/" .env
echo "USER_ID=$(id -u) set in .env"

# Load .env if exists
test -f .env && source .env

# Config with defaults
DB_HOST="${DB_HOST:-db}"
MYSQL_DATABASE="${MYSQL_DATABASE:-maho}"
MYSQL_USER="${MYSQL_USER:-maho_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-maho_password}"
BASE_URL="https://${FRONTEND_HOST}/"
ADMIN_URL="https://${ADMIN_HOST}/"
PHPMYADMIN_URL="https://${PHPMYADMIN_HOST}/"
PHPMYADMIN_ENABLE="${PHPMYADMIN_ENABLE:-1}"
LOCALE="${LOCALE:-en_US}"
TIMEZONE="${TIMEZONE:-America/New_York}"
CURRENCY="${CURRENCY:-USD}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-veryl0ngpassw0rd}"
ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME:-Maho}"
ADMIN_LASTNAME="${ADMIN_LASTNAME:-User}"

PROFILES=""
[[ "${MAHO_APP_ENABLE:-1}"       == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}maho"
[[ "${DATABASE_ENABLE:-1}"       == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}database"
[[ "${REDIS_ENABLE:-1}"          == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}redis"
[[ "${PHPMYADMIN_ENABLE:-0}"     == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}phpmyadmin"
export COMPOSE_PROFILES="$PROFILES"

# Reset flag
if [[ "$1" = "--reset" ]]; then
  echo "⚠️  WARNING: This will destroy all containers, volumes, and the src/ directory."
  echo "All data including the database and Maho files will be permanently deleted."
  read -p "Are you sure you want to continue? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
  echo "Wiping src/ & containers & volumes..."
  rm -rf ./src
  $dc --profile '*' down --volumes --remove-orphans
fi

# Check if already installed
# Maho stores local.xml in app/etc/ inside the project root (not public/)
if test -f ./src/app/etc/local.xml; then
  echo "Already installed!"
  if [[ "$1" != "--reset" ]]; then
    echo ""
    echo "Frontend URL: ${BASE_URL}"
    echo "Admin URL: ${ADMIN_URL}admin"
    echo "Admin login: $ADMIN_USERNAME : $ADMIN_PASSWORD"
    echo ""
    echo "To start a clean installation run: $0 --reset"
    exit 1
  fi
fi

# Validate admin password length
if [[ ${#ADMIN_PASSWORD} -lt 14 ]]; then
  echo "Admin password must be at least 14 characters."
  exit 1
fi

# Create src directory if it doesn't exist
mkdir -p src

echo "Building containers..."
$dc build
echo ""
echo ""     

echo "Starting containers..."
$dc up -d
echo ""
echo ""

if [[ "$MAHO_APP_ENABLE" = "1" ]]; then

    echo "Installing Maho via Composer..."
    # maho-starter puts its files in the project root; the document root will be /app/public
    $dc run --rm app composer create-project mahocommerce/maho-starter /app
    echo ""
    echo ""

    echo "Waiting for MySQL to be ready..."
    for i in $(seq 1 30); do
      if mariadb -h "$DB_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" 2>/dev/null; then
        echo "MySQL ready!"
        break
      fi
      echo "  waiting... ($i/30)"
      sleep 2
      if [[ $i -eq 30 ]]; then
        echo "❌ MySQL did not become ready in time."
        exit 1
      fi
    done

    # Build the install command
    INSTALL_CMD=(
      ./maho install
      --license_agreement_accepted yes
      --locale "$LOCALE"
      --timezone "$TIMEZONE"
      --default_currency "$CURRENCY"
      --db_host "$DB_HOST"
      --db_name "$MYSQL_DATABASE"
      --db_user "$MYSQL_USER"
      --db_pass "$MYSQL_PASSWORD"
      --url "$BASE_URL"
      --use_secure "$([[ $BASE_URL == https* ]] && echo 1 || echo 0)"
      --secure_base_url "$BASE_URL"
      --use_secure_admin "$([[ $ADMIN_URL == https* ]] && echo 1 || echo 0)"
      --admin_firstname "$ADMIN_FIRSTNAME"
      --admin_lastname "$ADMIN_LASTNAME"
      --admin_email "$ADMIN_EMAIL"
      --admin_username "$ADMIN_USERNAME"
      --admin_password "$ADMIN_PASSWORD"
    )

    # Sample data (optional) - Maho handles download automatically via --sample_data 1
    if [[ -n "${SAMPLE_DATA:-}" ]]; then
      INSTALL_CMD+=(--sample_data 1)
    fi

    echo "Installing Maho LTS..."
    $dc run --rm app "${INSTALL_CMD[@]}"

    # Maho stores the base_url at the 'default' scope, which is used by the frontend.
    # To make the admin panel work on a separate domain, we set the base_url at the
    # 'stores' scope for store_id=0 (the admin store). Maho's config inheritance
    # gives 'stores' scope priority over 'default', so the admin will use ADMIN_URL
    # for redirects while the frontend continues to use BASE_URL.
    echo "Configuring separate admin URL..."
    $dc exec app mariadb -h"$DB_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "
    DELETE FROM core_config_data WHERE path IN ('admin/url/use_custom', 'web/unsecure/base_url', 'web/secure/base_url');
    INSERT INTO core_config_data (scope, scope_id, path, value) VALUES
    ('default', 0, 'admin/url/use_custom',  '1'),
    ('default', 0, 'web/unsecure/base_url', '$BASE_URL'),
    ('default', 0, 'web/secure/base_url',   '$BASE_URL'),
    ('stores',  0, 'web/unsecure/base_url', '$ADMIN_URL'),
    ('stores',  0, 'web/secure/base_url',   '$ADMIN_URL');
    "

    echo "Reindexing..."
    $dc run --rm app ./maho index:reindex:all

    echo "Flushing cache..."
    $dc run --rm app ./maho cache:flush

    echo ""
    echo "✅ Setup complete!"
    echo ""
    echo "Frontend URL: ${BASE_URL}"
    echo "Admin URL:    ${ADMIN_URL}admin"
    echo "Admin login:  $ADMIN_USERNAME : $ADMIN_PASSWORD"
    echo ""

    if [[ "${PHPMYADMIN_ENABLE}" == "1" ]]; then
      echo "phpMyAdmin URL: ${PHPMYADMIN_URL}"
      echo "phpMyAdmin login:  $MYSQL_USER : $MYSQL_PASSWORD"
      echo ""
      echo ""
    fi
    
    echo "Copying caddy-root.crt to the current directory..."
    docker cp maho_app:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
    read -p "Would you like to add the Caddy CA certificate to Chrome via certutil? [y/N] " add_cert
    if [[ "$add_cert" == "y" || "$add_cert" == "Y" ]]; then
      certutil -d sql:$HOME/.pki/nssdb -A -t "CT,," -n "Caddy Local CA" -i ./caddy-root.crt
      echo "✅ Certificate added to Chrome."
    fi
    echo ""
    echo ""

if [[ "${DATABASE_ENABLE}" == "1" ]]; then
  echo "Database login:  $MYSQL_USER : $MYSQL_PASSWORD"
  echo ""
  echo ""
fi

if [[ "${REDIS_ENABLE}" == "1" ]]; then
  echo "Redis login:   : "
  echo ""
  echo ""
fi

echo ""
echo ""