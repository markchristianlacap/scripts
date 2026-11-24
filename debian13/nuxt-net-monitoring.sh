
#!/usr/bin/env bash
#
# Nuxt Network Monitoring
# Native installer for Debian 13 / Proxmox LXC
#
# Runtime:
#   Node.js 26 LTS
#   pnpm 10.18.3
#   PostgreSQL
#   systemd
#
# No Docker or Docker Compose.
#
# Interactive:
#   chmod +x install-nuxt-monitoring.sh
#   sudo ./install-nuxt-monitoring.sh
#
# Unattended:
#   sudo env \
#     UNATTENDED=1 \
#     APP_DIR=/opt/nuxt-net-monitoring \
#     APP_PORT=3000 \
#     DB_NAME=net-monitor \
#     DB_USER=netmonitor \
#     DB_PASSWORD='ChangeThisDatabasePassword' \
#     INSTALL_SPEEDTEST=1 \
#     INSTALL_SNMP_TOOLS=1 \
#     ./install-nuxt-monitoring.sh
#

set -Eeuo pipefail

# ============================================================
# DEFAULT SETTINGS
# ============================================================

REPO_URL="https://github.com/markchristianlacap/nuxt-net-monitoring.git"

APP_NAME="nuxt-net-monitoring"

UNATTENDED="${UNATTENDED:-0}"

APP_DIR="${APP_DIR:-/opt/nuxt-net-monitoring}"
APP_USER="${APP_USER:-nuxt-monitoring}"

APP_HOST="${APP_HOST:-0.0.0.0}"
APP_PORT="${APP_PORT:-3000}"

DB_NAME="${DB_NAME:-net-monitor}"
DB_USER="${DB_USER:-netmonitor}"
DB_PASSWORD="${DB_PASSWORD:-}"

NODE_MAJOR="${NODE_MAJOR:-26}"
PNPM_VERSION="${PNPM_VERSION:-10.18.3}"

INSTALL_SPEEDTEST="${INSTALL_SPEEDTEST:-0}"
INSTALL_SNMP_TOOLS="${INSTALL_SNMP_TOOLS:-0}"

SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
ENV_FILE="${APP_DIR}/.env"
SECRETS_FILE="/root/${APP_NAME}-secrets"

# ============================================================
# LOGGING
# ============================================================

log() {
    echo
    echo "============================================================"
    echo "[INFO] $*"
    echo "============================================================"
}

warn() {
    echo "[WARNING] $*" >&2
}

die() {
    echo
    echo "[ERROR] $*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    echo
    echo "[ERROR] Installation failed."
    echo "[ERROR] Exit code: ${exit_code}"
    echo
    echo "Check the output above for details."
    exit "$exit_code"
}

trap on_error ERR

# ============================================================
# HELPER FUNCTIONS
# ============================================================

generate_password() {
    openssl rand -hex 24
}

prompt_value() {
    local variable="$1"
    local description="$2"
    local default="$3"
    local answer

    if [[ "$UNATTENDED" == "1" ]]; then
        printf -v "$variable" '%s' "$default"
        return
    fi

    read -r -p "${description} [${default}]: " answer

    printf -v "$variable" '%s' "${answer:-$default}"
}

prompt_password() {
    local variable="$1"
    local description="$2"
    local default="$3"
    local answer

    if [[ "$UNATTENDED" == "1" ]]; then
        printf -v "$variable" '%s' "$default"
        return
    fi

    read -r -s -p "${description} [generated default]: " answer
    echo

    printf -v "$variable" '%s' "${answer:-$default}"
}

# ============================================================
# SYSTEM VALIDATION
# ============================================================

check_system() {
    log "Checking operating system"

    [[ "$EUID" -eq 0 ]] ||
        die "Run this installer as root."

    [[ -f /etc/debian_version ]] ||
        die "This installer requires Debian."

    . /etc/os-release

    [[ "$ID" == "debian" ]] ||
        die "This installer requires Debian."

    if [[ "${VERSION_ID:-}" != "13" ]]; then
        warn "This script was prepared for Debian 13."
        warn "Detected version: ${VERSION_ID:-unknown}"
    fi

    local architecture
    architecture="$(dpkg --print-architecture)"

    case "$architecture" in
        amd64|arm64)
            ;;
        *)
            die "NodeSource Node.js 26 packages are not configured for architecture: $architecture"
            ;;
    esac

    [[ "$APP_DIR" == /* ]] ||
        die "APP_DIR must be an absolute path."

    [[ "$APP_DIR" != "/" ]] ||
        die "APP_DIR cannot be /."

    [[ "$APP_DIR" != *" "* ]] ||
        die "APP_DIR cannot contain spaces."

    log "Operating system: ${PRETTY_NAME:-Debian}"
    log "Architecture: ${architecture}"
}

# ============================================================
# CONFIGURATION
# ============================================================

configure() {
    log "Application configuration"

    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD="$(generate_password)"
    fi

    echo
    echo "Application settings"
    echo "--------------------"

    prompt_value APP_DIR \
        "Application directory" \
        "$APP_DIR"

    prompt_value APP_HOST \
        "Application bind address" \
        "$APP_HOST"

    prompt_value APP_PORT \
        "Application port" \
        "$APP_PORT"

    echo
    echo "PostgreSQL settings"
    echo "-------------------"

    prompt_value DB_NAME \
        "Database name" \
        "$DB_NAME"

    prompt_value DB_USER \
        "Database username" \
        "$DB_USER"

    prompt_password DB_PASSWORD \
        "Database password" \
        "$DB_PASSWORD"

    echo
    echo "Optional components"
    echo "-------------------"

    prompt_value INSTALL_SPEEDTEST \
        "Install Ookla Speedtest CLI? (1=yes, 0=no)" \
        "$INSTALL_SPEEDTEST"

    prompt_value INSTALL_SNMP_TOOLS \
        "Install SNMP utilities? (1=yes, 0=no)" \
        "$INSTALL_SNMP_TOOLS"

    validate_configuration
}

validate_configuration() {
    [[ "$APP_PORT" =~ ^[0-9]+$ ]] ||
        die "APP_PORT must be numeric."

    (( APP_PORT >= 1 && APP_PORT <= 65535 )) ||
        die "APP_PORT must be between 1 and 65535."

    [[ "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] ||
        die "Invalid database name."

    [[ "$DB_USER" =~ ^[a-zA-Z0-9_]+$ ]] ||
        die "Invalid database username."

    # Restrict the password to safe characters for PostgreSQL
    # SQL commands and the application's environment file.
    [[ "$DB_PASSWORD" =~ ^[a-zA-Z0-9_-]+$ ]] ||
        die "Database password may contain only letters, numbers, underscores and hyphens."

    [[ "$APP_HOST" =~ ^[a-zA-Z0-9.:]+$ ]] ||
        die "Invalid application bind address."

    [[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] ||
        die "Invalid application system username."

    [[ "$INSTALL_SPEEDTEST" =~ ^[01]$ ]] ||
        die "INSTALL_SPEEDTEST must be 0 or 1."

    [[ "$INSTALL_SNMP_TOOLS" =~ ^[01]$ ]] ||
        die "INSTALL_SNMP_TOOLS must be 0 or 1."
}

# ============================================================
# BASE PACKAGES
# ============================================================

install_base_packages() {
    log "Installing Debian packages"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        git \
        gnupg \
        openssl \
        build-essential \
        iputils-ping \
        postgresql \
        postgresql-client

    systemctl enable --now postgresql

    unset DEBIAN_FRONTEND
}

# ============================================================
# NODE.JS 26 LTS
# ============================================================

install_nodejs() {
    log "Installing Node.js ${NODE_MAJOR}.x"

    install -d -m 0755 /usr/share/keyrings

    curl -fsSL \
        https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor --yes \
            -o /usr/share/keyrings/nodesource.gpg

    chmod 0644 /usr/share/keyrings/nodesource.gpg

    local architecture
    architecture="$(dpkg --print-architecture)"

    cat > /etc/apt/sources.list.d/nodesource.sources <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x
Suites: nodistro
Components: main
Architectures: ${architecture}
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

    log "Checking Node.js version"

    node --version
    npm --version

    if [[ "$(node -p 'process.versions.node.split(".")[0]')" != "$NODE_MAJOR" ]]; then
        die "Expected Node.js ${NODE_MAJOR}, but another major version is installed."
    fi
}

# ============================================================
# PNPM
# ============================================================

install_pnpm() {
    log "Installing pnpm ${PNPM_VERSION}"

    npm install --global "pnpm@${PNPM_VERSION}"

    pnpm --version

    [[ "$(pnpm --version)" == "$PNPM_VERSION" ]] ||
        die "pnpm version verification failed."
}

# ============================================================
# OPTIONAL SPEEDTEST
# ============================================================

install_speedtest() {
    if [[ "$INSTALL_SPEEDTEST" != "1" ]]; then
        log "Skipping Ookla Speedtest CLI"
        return
    fi

    log "Installing Ookla Speedtest CLI"

    curl -fsSL \
        https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh \
        -o /tmp/ookla-speedtest-install.sh

    bash /tmp/ookla-speedtest-install.sh

    apt-get install -y speedtest

    rm -f /tmp/ookla-speedtest-install.sh

    speedtest --version || true
}

# ============================================================
# OPTIONAL SNMP UTILITIES
# ============================================================

install_snmp_tools() {
    if [[ "$INSTALL_SNMP_TOOLS" != "1" ]]; then
        log "Skipping SNMP utilities"
        return
    fi

    log "Installing SNMP utilities"

    apt-get install -y snmp

    snmpget --version || true
}

# ============================================================
# APPLICATION USER
# ============================================================

create_app_user() {
    log "Creating application system user"

    if ! id "$APP_USER" >/dev/null 2>&1; then
        useradd \
            --system \
            --user-group \
            --home-dir "$APP_DIR" \
            --create-home \
            --shell /usr/sbin/nologin \
            "$APP_USER"
    fi

    if [[ ! -d "$APP_DIR" ]]; then
        install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
    fi

    chown "$APP_USER:$APP_USER" "$APP_DIR"
}

# ============================================================
# CLONE APPLICATION
# ============================================================

clone_repository() {
    log "Downloading Nuxt Network Monitoring"

    if [[ -d "$APP_DIR/.git" ]]; then
        log "Existing Git repository found. Updating."

        runuser -u "$APP_USER" -- \
            git -C "$APP_DIR" pull --ff-only

    elif [[ -d "$APP_DIR" ]] &&
        [[ -n "$(ls -A "$APP_DIR")" ]]; then

        die "$APP_DIR already exists and is not an empty Git repository."

    else
        runuser -u "$APP_USER" -- \
            git clone "$REPO_URL" "$APP_DIR"
    fi

    [[ -f "$APP_DIR/package.json" ]] ||
        die "package.json not found."

    [[ -f "$APP_DIR/pnpm-lock.yaml" ]] ||
        die "pnpm-lock.yaml not found."

    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
}

# ============================================================
# POSTGRESQL
# ============================================================

configure_postgresql() {
    log "Configuring PostgreSQL"

    systemctl enable --now postgresql

    if ! runuser -u postgres -- psql -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
        | grep -q 1; then

        runuser -u postgres -- psql \
            -v ON_ERROR_STOP=1 \
            -c "CREATE ROLE \"${DB_USER}\" LOGIN PASSWORD '${DB_PASSWORD}';"

    else

        runuser -u postgres -- psql \
            -v ON_ERROR_STOP=1 \
            -c "ALTER ROLE \"${DB_USER}\" WITH LOGIN PASSWORD '${DB_PASSWORD}';"

    fi

    if ! runuser -u postgres -- psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
        | grep -q 1; then

        runuser -u postgres -- createdb \
            --owner="$DB_USER" \
            "$DB_NAME"

    else

        runuser -u postgres -- psql \
            -v ON_ERROR_STOP=1 \
            -c "ALTER DATABASE \"${DB_NAME}\" OWNER TO \"${DB_USER}\";"

    fi

    log "PostgreSQL database is ready"
}

# ============================================================
# ENVIRONMENT FILE
# ============================================================

write_environment() {
    log "Writing application environment file"

    cat > "$ENV_FILE" <<EOF
NODE_ENV=production

HOST=${APP_HOST}
PORT=${APP_PORT}

NUXT_DB_HOST=localhost
NUXT_DB_PORT=5432
NUXT_DB_USER=${DB_USER}
NUXT_DB_PASSWORD=${DB_PASSWORD}
NUXT_DB_NAME=${DB_NAME}
EOF

    chown "$APP_USER:$APP_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# ============================================================
# PNPM DEPENDENCIES
# ============================================================

install_dependencies() {
    log "Installing application dependencies"

    cd "$APP_DIR"

    runuser -u "$APP_USER" -- \
        pnpm install --frozen-lockfile
}

# ============================================================
# BUILD NUXT
# ============================================================

build_application() {
    log "Building production application"

    runuser -u "$APP_USER" -- bash -c "
        cd '$APP_DIR'
        set -a
        source .env
        set +a
        pnpm run build
    "

    [[ -f "$APP_DIR/.output/server/index.mjs" ]] ||
        die "Nuxt production server output was not generated."
}

# ============================================================
# DATABASE MIGRATIONS
# ============================================================

run_migrations() {
    log "Running PostgreSQL database migrations"

    runuser -u "$APP_USER" -- bash -c "
        cd '$APP_DIR'
        set -a
        source .env
        set +a
        pnpm run db:migrate
    "

    log "Database migrations completed"
}

# ============================================================
# SYSTEMD SERVICE
# ============================================================

create_systemd_service() {
    log "Creating systemd service"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Nuxt Network Monitoring
Documentation=https://github.com/markchristianlacap/nuxt-net-monitoring
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple

User=${APP_USER}
Group=${APP_USER}

WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}

ExecStart=/usr/bin/node ${APP_DIR}/.output/server/index.mjs

Restart=always
RestartSec=5

KillSignal=SIGINT
TimeoutStopSec=30

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$APP_NAME"
    systemctl restart "$APP_NAME"

    sleep 3

    if ! systemctl is-active --quiet "$APP_NAME"; then
        journalctl -u "$APP_NAME" -n 60 --no-pager || true
        die "Application service failed to start."
    fi

    log "Application service is running"
}

# ============================================================
# SAVE CREDENTIALS
# ============================================================

save_credentials() {
    log "Saving installation credentials"

    cat > "$SECRETS_FILE" <<EOF
Nuxt Network Monitoring
=======================

Application URL:
http://<YOUR-LXC-IP>:${APP_PORT}

First administrator setup:
http://<YOUR-LXC-IP>:${APP_PORT}/setup

Monitoring administration:
http://<YOUR-LXC-IP>:${APP_PORT}/admin

PostgreSQL database:
${DB_NAME}

PostgreSQL username:
${DB_USER}

PostgreSQL password:
${DB_PASSWORD}

Application directory:
${APP_DIR}

Environment file:
${ENV_FILE}

Systemd service:
${APP_NAME}

Node.js major:
${NODE_MAJOR}

pnpm version:
${PNPM_VERSION}

The administrator account is created through /setup.
EOF

    chmod 600 "$SECRETS_FILE"
}

# ============================================================
# FINAL SUMMARY
# ============================================================

show_result() {
    echo
    echo "============================================================"
    echo " Nuxt Network Monitoring Installation Complete"
    echo "============================================================"
    echo
    echo "Runtime:"
    echo "  Node.js:       $(node --version)"
    echo "  npm:           $(npm --version)"
    echo "  pnpm:          $(pnpm --version)"
    echo
    echo "Application:"
    echo "  Directory:     $APP_DIR"
    echo "  User:          $APP_USER"
    echo "  Bind address:  $APP_HOST"
    echo "  Port:          $APP_PORT"
    echo
    echo "Database:"
    echo "  Database:      $DB_NAME"
    echo "  Username:      $DB_USER"
    echo
    echo "Service:"
    echo "  Name:          $APP_NAME"
    echo "  Environment:   $ENV_FILE"
    echo "  Credentials:   $SECRETS_FILE"
    echo
    echo "============================================================"
    echo " NEXT STEPS"
    echo "============================================================"
    echo
    echo "1. Open:"
    echo "   http://<YOUR-LXC-IP>:${APP_PORT}/setup"
    echo
    echo "2. Create your administrator account."
    echo
    echo "3. Sign in and open:"
    echo "   http://<YOUR-LXC-IP>:${APP_PORT}/admin"
    echo
    echo "4. Configure your monitoring devices and targets."
    echo
    echo "============================================================"
    echo " SERVICE COMMANDS"
    echo "============================================================"
    echo
    echo "Status:"
    echo "  systemctl status $APP_NAME"
    echo
    echo "Restart:"
    echo "  systemctl restart $APP_NAME"
    echo
    echo "Stop:"
    echo "  systemctl stop $APP_NAME"
    echo
    echo "Logs:"
    echo "  journalctl -u $APP_NAME -f"
    echo
    echo "============================================================"
}

# ============================================================
# MAIN
# ============================================================

main() {
    check_system
    configure

    install_base_packages
    install_nodejs
    install_pnpm

    install_speedtest
    install_snmp_tools

    create_app_user
    clone_repository

    configure_postgresql
    write_environment

    install_dependencies
    build_application
    run_migrations

    create_systemd_service
    save_credentials

    show_result
}

main "$@"
