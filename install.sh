#!/bin/bash
set -e

# 1. Rilevamento Docker Compose
dc="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  if ! command -v docker-compose >/dev/null 2>&1; then
    echo "Please first install docker compose."
    exit 1
  else
    dc="docker-compose"
  fi
fi

# 2. Gestione Ambiente (.env)
if [ ! -f .env ]; then
    cp env.example .env
    echo ".env created from env.example"
fi

# Forza l'UID dell'utente corrente (ottimo per CachyOS/Arch)
sed -i "s/^USER_ID=.*/USER_ID=$(id -u)/" .env
echo "USER_ID=$(id -u) set in .env"

# Carica variabili
test -f .env && source .env

# 3. Configurazione Defaults
DB_HOST="${DB_HOST:-db}"
MYSQL_DATABASE="${MYSQL_DATABASE:-maho}"
MYSQL_USER="${MYSQL_USER:-maho_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-maho_password}"
APPNAME="${APPNAME:-maho}" 
BASE_URL="https://${FRONTEND_HOST}/"
ADMIN_URL="https://${ADMIN_HOST}/"
PHPMYADMIN_URL="https://${PHPMYADMIN_HOST}/"
PHPMYADMIN_ENABLE="${PHPMYADMIN_ENABLE:-0}"
LOCALE="${LOCALE:-en_US}"
TIMEZONE="${TIMEZONE:-America/New_York}"
CURRENCY="${CURRENCY:-USD}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-veryl0ngpassw0rd}"
ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME:-Maho}"
ADMIN_LASTNAME="${ADMIN_LASTNAME:-User}"

# 4. Gestione Profili Docker
PROFILES=""
[[ "${MAHO_APP_ENABLE:-1}"       == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}maho"
[[ "${DATABASE_ENABLE:-1}"       == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}database"
[[ "${REDIS_ENABLE:-1}"          == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}redis"
[[ "${PHPMYADMIN_ENABLE:-0}"     == "1" ]] && PROFILES="${PROFILES:+$PROFILES,}phpmyadmin"
export COMPOSE_PROFILES="$PROFILES"

# 5. Reset Flag
if [[ "$1" = "--reset" ]]; then
  echo "⚠️  WARNING: Wiping everything..."
  rm -rf ./src
  $dc --profile '*' down --volumes --remove-orphans
fi

# 6. Check Installazione esistente
if test -f ./src/app/etc/local.xml; then
  echo "Already installed! Use --reset to start over."
  exit 1
fi

mkdir -p src

echo "Building and starting containers..."
$dc build
$dc up -d

# 7. LOGICA DI INSTALLAZIONE MAHO
if [[ "$MAHO_APP_ENABLE" == "1" ]]; then

    echo "Installing Maho via Composer..."
    $dc run --rm app composer create-project mahocommerce/maho-starter /app

    # echo "Waiting for MariaDB to be ready..."
    # for i in $(seq 1 30); do
    #   if $dc run --rm app mariadb -h "$DB_HOST" -u "$MYSQL_USER" -p "$MYSQL_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
    #     echo "  MariaDB is UP!"
    #     break
    #   fi
    #   if [ $i -eq 30 ]; then
    #     echo "  ERROR: MariaDB timeout after 30s"
    #     exit 1
    #   fi
    #   echo "  waiting... ($i/30)"
    #   sleep 1
    # done

    # Preparazione comando installazione
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

    echo "Installing Maho LTS..."
    $dc run --rm app "${INSTALL_CMD[@]}"

    echo "Configuring separate admin URL..."
    $dc run --rm app mariadb -h "$DB_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "
    DELETE FROM core_config_data WHERE path IN ('admin/url/use_custom', 'web/unsecure/base_url', 'web/secure/base_url');
    INSERT INTO core_config_data (scope, scope_id, path, value) VALUES
    ('default', 0, 'admin/url/use_custom',  '1'),
    ('default', 0, 'web/unsecure/base_url', '$BASE_URL'),
    ('default', 0, 'web/secure/base_url',   '$BASE_URL'),
    ('stores',  0, 'web/unsecure/base_url', '$ADMIN_URL'),
    ('stores',  0, 'web/secure/base_url',   '$ADMIN_URL');"

    echo "Finalizing: Indexing & Cache..."
    $dc run --rm app ./maho index:reindex:all
    $dc run --rm app ./maho cache:flush

    echo "✅ Setup complete!"
    echo "Frontend: $BASE_URL"
    echo "Admin:    ${ADMIN_URL}admin"

    # Export certificato Caddy (utile per CachyOS/Chrome locale)
    docker cp maho_app:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt || true
fi

# 8. INFO FINALI
echo "------------------------------------------"
if [[ "${DATABASE_ENABLE}" == "1" ]]; then
  echo "Database login:  $MYSQL_USER : $MYSQL_PASSWORD"
fi

if [[ "${REDIS_ENABLE}" == "1" ]]; then
  echo "Redis enabled."
fi

if [[ "${PHPMYADMIN_ENABLE}" == "1" ]]; then
  echo "phpMyAdmin: $PHPMYADMIN_URL"
fi