#!/bin/bash
set -e

# Copy .env.example to .env if it doesn't exist
if [ ! -f .env ]; then
    cp env.example .env
    echo ".env created from env.example"
fi

# Set UID to the current user's value
sed -i "s/^USER_ID=.*/USER_ID=$(id -u)/" .env
echo "USER_ID=$(id -u) set in .env"

# Create src directory if it doesn't exist
mkdir -p src

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

# Load .env if exists
test -f .env && source .env

# Config with defaults
DB_HOST="${DB_HOST:-db}"
MYSQL_DATABASE="${MYSQL_DATABASE:-openmage}"
MYSQL_USER="${MYSQL_USER:-om_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-om_password}"
BASE_URL="https://${FRONTEND_HOST}/"
ADMIN_URL="https://${ADMIN_HOST}/"
PHPMYADMIN_URL="https://${PHPMYADMIN_HOST}/"
LOCALE="${LOCALE:-en_US}"
TIMEZONE="${TIMEZONE:-America/New_York}"
CURRENCY="${CURRENCY:-USD}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-veryl0ngpassw0rd}"
ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME:-OpenMage}"
ADMIN_LASTNAME="${ADMIN_LASTNAME:-User}"
ENABLE_CHARTS="${ENABLE_CHARTS:-yes}"

# Reset flag
if [[ "$1" = "--reset" ]]; then
  echo "⚠️  WARNING: This will destroy all containers, volumes, and the src/ directory."
  echo "All data including the database and OpenMage files will be permanently deleted."
  read -p "Are you sure you want to continue? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
  echo "Wiping previous installation..."
  $dc down --volumes --remove-orphans
  rm -rf ./src && mkdir ./src
fi

# Check if already installed
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

echo "Building containers..."
$dc build

echo "Starting containers..."
$dc up -d

echo "Installing OpenMage via Composer..."
$dc run --rm app composer create-project openmage/magento-lts /app/public

echo "Waiting for MySQL to be ready..."
for i in $(seq 1 30); do
  sleep 1
  docker exec openmage_db mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" 2>/dev/null && break
  echo "  waiting... ($i/30)"
done

# Sample data (optional)
if [[ -n "${SAMPLE_DATA:-}" ]]; then
  echo "Installing Sample Data..."
  SAMPLE_DATA_URL=https://github.com/Vinai/compressed-magento-sample-data/raw/master/compressed-magento-sample-data-1.9.2.4.tgz
  SAMPLE_DATA_DIR="./src/var/sample_data"
  SAMPLE_DATA_FILE="$SAMPLE_DATA_DIR/sample_data.tgz"

  mkdir -p "$SAMPLE_DATA_DIR"

  if [[ ! -f "$SAMPLE_DATA_FILE" ]]; then
    echo "Downloading Sample Data..."
    wget "$SAMPLE_DATA_URL" -O "$SAMPLE_DATA_FILE"
  fi

  echo "Extracting Sample Data..."
  tar xf "$SAMPLE_DATA_FILE" -C "$SAMPLE_DATA_DIR"
  cp -r "$SAMPLE_DATA_DIR"/magento-sample-data-1.9.2.4/media/* ./src/media/
  cp -r "$SAMPLE_DATA_DIR"/magento-sample-data-1.9.2.4/skin/* ./src/skin/

  echo "Importing Sample Data into database..."
  $dc exec -T db mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" < "$SAMPLE_DATA_DIR"/magento-sample-data-1.9.2.4/magento_sample_data_for_1.9.2.4.sql

  rm -rf "$SAMPLE_DATA_DIR"
fi

echo "Installing OpenMage LTS..."
$dc run --rm app php /app/public/install.php \
  --license_agreement_accepted yes \
  --locale "$LOCALE" \
  --timezone "$TIMEZONE" \
  --default_currency "$CURRENCY" \
  --db_host "$DB_HOST" \
  --db_name "$MYSQL_DATABASE" \
  --db_user "$MYSQL_USER" \
  --db_pass "$MYSQL_PASSWORD" \
  --url "$BASE_URL" \
  --use_rewrites yes \
  --use_secure "$([[ $BASE_URL == https* ]] && echo yes || echo no)" \
  --secure_base_url "$BASE_URL" \
  --use_secure_admin "$([[ $ADMIN_URL == https* ]] && echo yes || echo no)" \
  --enable_charts "$ENABLE_CHARTS" \
  --skip_url_validation \
  --admin_firstname "$ADMIN_FIRSTNAME" \
  --admin_lastname "$ADMIN_LASTNAME" \
  --admin_email "$ADMIN_EMAIL" \
  --admin_username "$ADMIN_USERNAME" \
  --admin_password "$ADMIN_PASSWORD"

echo "Flushing cache..."
rm -rf ./src/var/cache/*

# OpenMage stores the base_url at the 'default' scope, which is used by the frontend.
# To make the admin panel work on a separate domain, we set the base_url at the
# 'stores' scope for store_id=0 (the admin store). OpenMage's config inheritance
# gives 'stores' scope priority over 'default', so the admin will use ADMIN_URL
# for redirects while the frontend continues to use BASE_URL.
echo "Configuring separate admin URL..."
docker exec openmage_db mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "
DELETE FROM core_config_data WHERE path IN ('admin/url/use_custom', 'admin/url/custom', 'web/unsecure/base_url', 'web/secure/base_url');
INSERT INTO core_config_data (scope, scope_id, path, value) VALUES
('default', 0, 'admin/url/use_custom',  '1'),
('default', 0, 'web/unsecure/base_url', '$BASE_URL'),
('default', 0, 'web/secure/base_url',   '$BASE_URL'),
('stores',  0, 'web/unsecure/base_url', '$ADMIN_URL'),
('stores',  0, 'web/secure/base_url',   '$ADMIN_URL');
"
rm -rf ./src/var/cache/*

echo ""
echo "✅ Setup complete!"
echo ""
echo "Frontend URL: ${BASE_URL}"
echo "Admin URL:    ${ADMIN_URL}admin"
echo "Admin login:  $ADMIN_USERNAME : $ADMIN_PASSWORD"
echo ""
echo "phpMyAdmin URL: ${PHPMYADMIN_URL}"
echo "phpMyAdmin login:  $MYSQL_USER : $MYSQL_PASSWORD"
echo ""
