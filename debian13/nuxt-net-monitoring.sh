
    
  
fi
install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 0750 "${APP_DIR}"

log "Creating PostgreSQL role and database"
systemctl enable --now postgresql
DB_PASSWORD="$(openssl rand -hex 32)"
DB_PASSWORD_SQL="${DB_PASSWORD//\'/\'\'}"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
  -v dbuser="${APP_USER}" -v dbname="net-monitor" <<SQL
CREATE ROLE "${APP_USER}" LOGIN PASSWORD '${DB_PASSWORD_SQL}';
CREATE DATABASE "net-monitor" OWNER "${APP_USER}";
SQL

log "Cloning application"
git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"

log "Writing private application environment"
umask 077
cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
HOST=0.0.0.0
PORT=${APP_PORT}
NUXT_DB_HOST=127.0.0.1
NUXT_DB_PORT=5432
NUXT_DB_USER=${APP_USER}
NUXT_DB_PASSWORD=${DB_PASSWORD}
NUXT_DB_NAME=net-monitor
NUXT_TRUST_PROXY=false
EOF
chown root:"${APP_GROUP}" "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

log "Installing dependencies, migrating database, and building Nuxt"
runuser -u "${APP_USER}" -- bash -lc "
  set -Eeuo pipefail
  cd '${APP_DIR}'
  set -a
  . '${ENV_FILE}'
  set +a
  pnpm install --frozen-lockfile
  pnpm run db:migrate
  pnpm run build
"

log "Installing systemd service"
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
Environment=NODE_ENV=production
Environment=HOST=0.0.0.0
Environment=PORT=${APP_PORT}
ExecStart=/usr/bin/node ${APP_DIR}/.output/server/index.mjs
Restart=on-failure
RestartSec=5
TimeoutStartSec=90
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable --now "${APP_NAME}"

log "Installation complete"
IP_ADDR="$(hostname -I | awk '{print $1}')"
cat <<EOF

Application: http://${IP_ADDR:-YOUR_LXC_IP}:${APP_PORT}
First-run setup: http://${IP_ADDR:-YOUR_LXC_IP}:${APP_PORT}/setup
Admin/configuration: http://${IP_ADDR:-YOUR_LXC_IP}:${APP_PORT}/admin

Service status: systemctl status ${APP_NAME}
Live logs:      journalctl -u ${APP_NAME} -f
Environment:    ${ENV_FILE}
App directory:  ${APP_DIR}

Next steps:
  1. Open /setup and create the first administrator account.
  2. Open /admin and configure ping hosts, SNMP devices/interfaces,
     and speed-test scheduling.
  3. Keep the service reachable only from a trusted LAN or put it behind
     a trusted reverse proxy with TLS.

Optional Ookla Speedtest CLI:
  The app's speed-test feature requires the official 'speedtest' command.
  Install it from Ookla's Debian package repository, then run
  'speedtest --accept-license --accept-gdpr' once as a normal user.
  Do not enable scheduled speed tests until this command succeeds.

Database password was generated automatically and is stored in ${ENV_FILE}.
Back up that file securely along with the PostgreSQL database.
EOF