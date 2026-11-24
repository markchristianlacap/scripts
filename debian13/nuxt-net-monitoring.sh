#!/usr/bin/env bash
#
# Install nuxt-net-monitoring on Debian 13 (Trixie), without Docker.
# Run as root:
#   bash install-nuxt-net-monitoring-debian13.sh
#
set -Eeuo pipefail
umask 027

APP_NAME="nuxt-net-monitoring"
APP_DIR="/opt/nuxt-net-monitoring"
APP_USER="netmonitor"
APP_GROUP="netmonitor"
ENV_FILE="/etc/nuxt-net-monitoring.env"
SERVICE_FILE="/etc/systemd/system/nuxt-net-monitoring.service"
REPO_URL="https://github.com/markchristianlacap/nuxt-net-monitoring.git"
NODE_MAJOR="26"
PNPM_VERSION="10.18.3"
DB_NAME="net-monitor"
DB_USER="netmonitor"
APP_PORT="3000"

log() { printf '\n[+] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run this installer as root (for example: sudo bash $0)."
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
. /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] || \
  die "This script targets Debian 13. Detected: ${PRETTY_NAME:-unknown}."
[[ ! -e "${APP_DIR}" ]] || die "${APP_DIR} already exists. Back it up/remove it before installing."

export DEBIAN_FRONTEND=noninteractive

log "Installing system dependencies"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git gnupg build-essential python3 \
  postgresql postgresql-client snmp iputils-ping openssl libatomic1

log "Adding Node.js ${NODE_MAJOR}.x repository and installing Node.js LTS"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs

node --version
npm --version

log "Installing pnpm ${PNPM_VERSION}"
npm install --global "pnpm@${PNPM_VERSION}"
pnpm --version

log "Creating dedicated service account"
if ! getent group "${APP_GROUP}" >/dev/null; then
  groupadd --system "${APP_GROUP}"
fi
if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --gid "${APP_GROUP}" --home-dir "${APP_DIR}" \
    --create-home --shell /usr/sbin/nologin "${APP_USER}"
fi

log "Preparing PostgreSQL database"
systemctl enable --now postgresql
DB_PASSWORD="$(openssl rand -hex 32)"
DB_PASSWORD_SQL="${DB_PASSWORD//\'/\'\'}"

if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD_SQL}';"
else
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD_SQL}';"
fi

if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  log "Database ${DB_NAME} already exists; assigning ownership to ${DB_USER}"
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
    -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};"
else
  runuser -u postgres -- createdb --owner="${DB_USER}" "${DB_NAME}"
fi

log "Writing application environment file"
cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
HOST=0.0.0.0
PORT=${APP_PORT}
NUXT_DB_HOST=127.0.0.1
NUXT_DB_PORT=5432
NUXT_DB_USER=${DB_USER}
NUXT_DB_PASSWORD=${DB_PASSWORD}
NUXT_DB_NAME=${DB_NAME}
NUXT_TRUST_PROXY=false
EOF
chown root:"${APP_GROUP}" "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

log "Cloning application"
git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"

log "Installing dependencies, applying database migrations, and building Nuxt"
runuser -u "${APP_USER}" -- env \
  APP_DIR="${APP_DIR}" ENV_FILE="${ENV_FILE}" PNPM_HOME="/home/${APP_USER}/.local/share/pnpm" \
  bash -c '
    set -Eeuo pipefail
    set -a
    . "$ENV_FILE"
    set +a
    cd "$APP_DIR"
    pnpm install --frozen-lockfile
    pnpm run db:migrate
    pnpm run build
  '

log "Creating systemd service"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Nuxt Network Monitoring
Wants=network-online.target
After=network-online.target postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/node ${APP_DIR}/.output/server/index.mjs
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${APP_NAME}"

log "Installation complete"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '\n'
printf 'Application URL: http://%s:%s\n' "${SERVER_IP:-<LXC-IP>}" "${APP_PORT}"
printf 'First-run setup: http://%s:%s/setup\n' "${SERVER_IP:-<LXC-IP>}" "${APP_PORT}"
printf 'Admin dashboard: http://%s:%s/admin\n' "${SERVER_IP:-<LXC-IP>}" "${APP_PORT}"
printf '\n'
printf 'Service status:  systemctl status %s\n' "${APP_NAME}"
printf 'Live logs:       journalctl -u %s -f\n' "${APP_NAME}"
printf 'Restart:         systemctl restart %s\n' "${APP_NAME}"
printf 'Environment:     %s (root:%s, mode 0640)\n' "${ENV_FILE}" "${APP_GROUP}"
printf '\n'
printf 'Next steps:\n'
printf '  1. Open /setup and create the administrator account.\n'
printf '  2. Sign in at /admin and configure ping/SNMP monitoring.\n'
printf '  3. Allow ICMP and, where needed, UDP port 161 from this LXC to monitored devices.\n'
printf '\n'
printf 'Optional speed testing:\n'
printf '  The Ookla Speedtest CLI is not installed by this script. Install the official\n'
printf '  Ookla Debian package if you want speed tests, then run `speedtest --accept-license\n'
printf '  --accept-gdpr` as the service user once and verify it succeeds before enabling\n'
printf '  scheduled speed tests in the dashboard.\n'
printf '\n'
printf 'Node.js: %s | pnpm: %s\n' "$(node --version)" "$(pnpm --version)"