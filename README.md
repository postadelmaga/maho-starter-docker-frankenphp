# Maho Local Development with FrankenPHP + MariaDB

A Docker setup for running [Maho](https://mahocommerce.com/) locally using [FrankenPHP](https://frankenphp.dev/) (Caddy + PHP in a single container) and MariaDB, with separate frontend and admin URLs.

## Stack

| Service    | Image                                   | Version           |
|------------|-----------------------------------------|-------------------|
| app        | `dunglas/frankenphp` (Alpine-based)     | `1-php8.3-alpine` |
| db         | `mariadb`                               | `lts`             |
| phpmyadmin | `phpmyadmin`                            | `5.2`             |

## Requirements

- Docker + Docker Compose
- Internet connection (required for nip.io DNS resolution)

## Directory structure

```
maho-docker/
├── Caddyfile
├── Dockerfile
├── docker-compose.yml
├── install.sh
├── .env               # your local config (not committed)
├── env.example        # template to copy
└── src/               # Maho will be installed here
    └── public/        # ← document root (served by Caddy)
```

> Unlike OpenMage/Magento 1, in Maho the project root and the web document root are **separate**.
> Composer packages, `app/`, `var/` and `lib/` live in `src/`, while only `src/public/` is exposed by the web server.

---

## URLs

By default the setup uses [nip.io](https://nip.io) — a public DNS service that resolves any domain containing an IP address back to that IP. No `/etc/hosts` edits required.

| Service    | URL                                              |
|------------|--------------------------------------------------|
| Frontend   | https://maho.127.0.0.1.nip.io                   |
| Admin      | https://maho-admin.127.0.0.1.nip.io/admin        |
| phpMyAdmin | https://maho-phpmyadmin.127.0.0.1.nip.io         |

You can override these in `.env` with your own domains (including `.test` domains if you prefer to manage `/etc/hosts` manually).

---

## Quick Install

### 1. Configure the environment

```bash
cp env.example .env
```

Edit `.env` with your preferred values — locale, timezone, currency, admin credentials, etc. The default URLs use nip.io and work out of the box.

### 2. Run the install script

```bash
chmod +x install.sh
./install.sh
```

The script will:
- Build and start all containers
- Install Maho via `composer create-project mahocommerce/maho-starter`
- Wait for the database to be ready
- Run `./maho install` with the values from `.env`
- Optionally download and install sample data (set `SAMPLE_DATA=1` in `.env`)
- Configure the separate admin URL in the database
- Flush the cache

To reset everything and start fresh:

```bash
./install.sh --reset
```

### 3. Trust the local CA certificate

FrankenPHP generates a local CA to sign the `tls internal` certificate. Import it once so your browser trusts it.

Extract the certificate:

```bash
docker cp maho_app:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

**Arch Linux:**
```bash
sudo cp caddy-root.crt /etc/ca-certificates/trust-source/anchors/caddy-root.crt
sudo trust extract-compat
## For Chrome (arch package nss)
certutil -d sql:$HOME/.pki/nssdb -A -t "CT,," -n "Caddy Local CA" -i ./caddy-root.crt
```

**Debian / Ubuntu:**
```bash
sudo cp caddy-root.crt /usr/local/share/ca-certificates/caddy-root.crt
sudo update-ca-certificates
## For Chrome (ubuntu package libnss3-tools)
certutil -d sql:$HOME/.pki/nssdb -A -t "CT,," -n "Caddy Local CA" -i ./caddy-root.crt
```

**Chrome / Chromium:**
If you used `certutil`, skip the manual import.
Go to `chrome://settings/certificates` → **Authorities** → **Import** → select `caddy-root.crt` → check "Trust this certificate for identifying websites".

**Firefox:**
Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import → select `caddy-root.crt`.

Restart your browser after importing.

> **Note:** If you delete the `caddy_data` Docker volume, a new certificate will be generated and you will need to re-import it.

### 4. Open the store

Frontend and admin URLs are printed at the end of the install script.

---

## Manual Install

If you prefer to install Maho via the web wizard:

```bash
mkdir src
docker compose up -d
docker compose run --rm app composer create-project mahocommerce/maho-starter /app
```

Trust the certificate (step 3 above), then navigate to your frontend URL and follow the installation wizard.

**Database credentials:**

| Field    | Value          |
|----------|----------------|
| Host     | `db`           |
| Database | `maho`         |
| User     | `maho_user`    |
| Password | `maho_password`|

> Use `db` as the host, not `localhost`.

**Use Secure URLs:** select **Yes** — Caddy handles SSL automatically.

---

## Key differences from OpenMage

| Aspect | OpenMage | Maho |
|---|---|---|
| Composer package | `openmage/magento-lts` | `mahocommerce/maho-starter` |
| Installer | `php install.php` | `./maho install` |
| Document root | project root | `public/` subdirectory |
| Volume mount | `./src:/app/public` | `./src:/app` |
| Sample data | manual wget + SQL import | `--sample_data 1` flag |
| Removed install params | — | `enable_charts`, `skip_url_validation` |

---

## Security

The Caddyfile includes the following protections on both frontend and admin:

- **Security headers** — `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options`, `X-XSS-Protection`, `Referrer-Policy`
- **Dot files blocked** — any path containing a dot-prefixed segment returns 404
- **Private media blocked** — `/media/customer/`, `/media/downloadable/`, `/media/import/` return 404
- **Static asset caching** — `/skin/` and `/js/` are served with a 1-year cache header

Frontend only:
- **Admin path blocked** — requests to `/admin` on the frontend domain return 404
- **PHP entry points blocked** — direct requests to `install.php`, `index.php` return 404
- **Admin skin blocked** — `/skin/adminhtml/` and `/skin/install/` return 404

Admin only:
- **Upload limit** — request body limit raised to 512MB to support large file uploads in the admin panel

---

## phpMyAdmin

Available at `https://maho-phpmyadmin.127.0.0.1.nip.io` (or your configured `PHPMYADMIN_HOST`).

| Field | Value            |
|-------|------------------|
| User  | `maho_user`      |
| Pass  | `maho_password`  |

For full root access use `root` / `root_password`.

---

## Xdebug

Xdebug 3 is included and configured for remote debugging on port `9003` with `start_with_request=trigger` — it only activates when the `XDEBUG_TRIGGER` cookie or query parameter is present.

### VSCode setup

1. Install the [PHP Debug](https://marketplace.visualstudio.com/items?itemName=xdebug.php-debug) extension.

2. Create `.vscode/launch.json` in your project root:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Listen for Xdebug",
      "type": "php",
      "request": "launch",
      "port": 9003,
      "pathMappings": {
        "/app": "${workspaceFolder}/src"
      }
    }
  ]
}
```

> Note: the path mapping is `/app` (project root), not `/app/public`, because Maho's core lives outside the document root.

3. Start debugging with **Run → Start Debugging** (`F5`).

4. Activate Xdebug per-request by adding `?XDEBUG_TRIGGER=1` to the URL, or use the [Xdebug Helper](https://chromewebstore.google.com/detail/xdebug-helper/eadndfjplgieldjbigjakmdgkmoaaaoc) browser extension.

### Linux: firewall note

On Linux, iptables may block incoming connections from Docker bridge interfaces to the host, preventing Xdebug from reaching your IDE. If breakpoints are not hit, run:

```bash
sudo iptables -I INPUT -i br+ -p tcp --dport 9003 -j ACCEPT
```

To make the rule persistent across reboots:

```bash
# Arch Linux
sudo iptables-save > /etc/iptables/iptables.rules
sudo systemctl enable iptables

# Debian / Ubuntu
sudo apt install iptables-persistent
sudo netfilter-persistent save

# ufw
sudo ufw allow in on br+ to any port 9003

# firewalld
sudo firewall-cmd --permanent --add-port=9003/tcp
sudo firewall-cmd --reload
```

---

## Useful commands

```bash
# Start
docker compose up -d

# Stop
docker compose down

# Build (after Dockerfile changes)
docker compose build

# Force rebuild from scratch
docker compose build --no-cache

# View logs
docker compose logs app

# Access the app container
docker exec -it maho_app bash

# Access the Maho CLI tool
docker exec -it maho_app ./maho --help

# Access the database
docker exec -it maho_db mariadb -u maho_user -pmaho_password maho

# Flush cache via CLI
docker exec -it maho_app ./maho cache:flush

# Reset and reinstall
./install.sh --reset
```

---

## Troubleshooting

### nip.io not resolving

nip.io requires an internet connection for DNS resolution. If you are offline, add the domains manually to `/etc/hosts`:

```bash
echo "127.0.0.1 maho.127.0.0.1.nip.io" | sudo tee -a /etc/hosts
echo "127.0.0.1 maho-admin.127.0.0.1.nip.io" | sudo tee -a /etc/hosts
echo "127.0.0.1 maho-phpmyadmin.127.0.0.1.nip.io" | sudo tee -a /etc/hosts
```

### Permission denied on var/cache or caddy volumes

```bash
sudo chmod -R 777 /var/lib/docker/volumes/maho-docker_caddy_data/_data
docker compose restart app
```

### Browser blocks the site after switching from HTTPS to HTTP

The Caddyfile sets a `Strict-Transport-Security` (HSTS) header, which tells the browser to always use HTTPS for a domain for 180 days. If you change your local configuration to HTTP only, the browser will refuse to connect.

To fix it:

1. Go to `chrome://net-internals/#hsts`
2. Scroll to **Delete domain security policies**
3. Enter the hostname (e.g. `maho.127.0.0.1.nip.io`) and click **Delete**

Repeat for each affected domain. No browser restart required.
