#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configurazione — adatta o passa come variabili d'ambiente
# ---------------------------------------------------------------------------
DB_CONTAINER="${DB_CONTAINER:-mahodoc_db}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-root_password}"
DB_NAME="${DB_NAME:-magento}"
DUMP_FILE="${1:-}"

# ---------------------------------------------------------------------------
# Controlli preliminari
# ---------------------------------------------------------------------------
if [[ -z "$DUMP_FILE" ]]; then
    echo "Uso: $0 /path/to/dump.sql[.gz]"
    exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "Errore: file '$DUMP_FILE' non trovato."
    exit 1
fi

if ! command -v pv &>/dev/null; then
    echo "pv non trovato — installa con: sudo pacman -S pv"
    exit 1
fi

MYSQL="docker exec -i $DB_CONTAINER mysql -u $DB_USER -p$DB_PASS"

# ---------------------------------------------------------------------------
# Crea il database se non esiste
# ---------------------------------------------------------------------------
echo ">>> Creazione database '$DB_NAME' se non esiste..."
$MYSQL -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8 COLLATE utf8_general_ci;"

# ---------------------------------------------------------------------------
# Impostazioni per velocizzare l'import (applicate a runtime, non permanenti)
# ---------------------------------------------------------------------------
echo ">>> Applicazione impostazioni performance..."
$MYSQL "$DB_NAME" <<'EOF'
SET GLOBAL innodb_flush_log_at_trx_commit = 0;
SET GLOBAL innodb_doublewrite             = 0;
SET GLOBAL sync_binlog                   = 0;
SET GLOBAL foreign_key_checks            = 0;
SET GLOBAL unique_checks                 = 0;
SET GLOBAL innodb_buffer_pool_size       = 512 * 1024 * 1024;
EOF

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------
echo ">>> Import di '$DUMP_FILE' in corso..."
$MYSQL -e "CREATE USER IF NOT EXISTS 'boi_production'@'88.99.252.228' IDENTIFIED BY 'placeholder'; GRANT ALL PRIVILEGES ON magento.* TO 'boi_production'@'88.99.252.228'; FLUSH PRIVILEGES;"

if [[ "$DUMP_FILE" == *.gz ]]; then
    gunzip -c "$DUMP_FILE" | pv | $MYSQL "$DB_NAME"
else
    pv "$DUMP_FILE" | $MYSQL "$DB_NAME"
fi

# ---------------------------------------------------------------------------
# Ripristino impostazioni sicure post-import
# ---------------------------------------------------------------------------
echo ">>> Ripristino impostazioni sicure..."
$MYSQL "$DB_NAME" <<'EOF'
SET GLOBAL innodb_flush_log_at_trx_commit = 1;
SET GLOBAL innodb_doublewrite             = 1;
SET GLOBAL sync_binlog                   = 1;
SET GLOBAL foreign_key_checks            = 1;
SET GLOBAL unique_checks                 = 1;
EOF

echo ""
echo "✓ Import completato."
