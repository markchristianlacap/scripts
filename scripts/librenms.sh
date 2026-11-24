
#!/usr/bin/env bash
#
# LibreNMS automated installer
# Debian 13 / Proxmox LXC
#
# Run: bash install-librenms.sh
#
# Optional unattended variables:
# SERVER_NAME=librenms.example.com
# TIMEZONE=Asia/Manila
# DB_PASSWORD=your-secure-password
# SNMP_COMMUNITY=your-community
#

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

INSTALL_DIR="/opt/librenms"
DB_NAME="librenms"
DB_USER="librenms"
PHP_SOCKET="/run/php-fpm-librenms.sock"
SECRETS="/root/librenms-install-secrets"

SERVER_NAME="${SERVER_NAME:-_}"
TIMEZONE="${TIMEZONE:-Asia/Manila}"

log() {
    echo
    echo "[$(date '+%F %T')] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

trap 'fail "Installation failed at line $LINENO. Check the error above."' ERR

# --------------------------------------------------
# 1. System checks
# --------------------------------------------------

[[ $EUID -eq 0 ]] || fail "Run this installer as root."

[[ -f /etc/debian_version ]] || fail "Debian is required."

DEBIAN_VERSION="$(. /etc/os-release && echo "$VERSION_ID")"

[[ "$DEBIAN_VERSION" == "13" ]] || \
    fail "This installer is intended for Debian 13. Detected: $DEBIAN_VERSION"

if [[ -d "$INSTALL_DIR" ]]; then
    fail "$INSTALL_DIR already exists. Refusing to overwrite an existing installation."
fi

log "Starting LibreNMS installation on Debian $DEBIAN_VERSION"

# --------------------------------------------------
# 2. Generate credentials
# --------------------------------------------------

DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -hex 24)}"
SNMP_COMMUNITY="${SNMP_COMMUNITY:-$(openssl rand -hex 16)}"

[[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._-]+$ ]] || \
    fail "DB_PASSWORD may only contain letters, numbers, dots, underscores and hyphens."

[[ "$SNMP_COMMUNITY" =~ ^[A-Za-z0-9._-]+$ ]] || \
    fail "SNMP_COMMUNITY may only contain letters, numbers, dots, underscores and hyphens."

# --------------------------------------------------
# 3. Install packages
# --------------------------------------------------

log "Installing required packages"

apt-get update

apt-get install -y \
    acl \
    ca-certificates \
    curl \
    fping \
    git \
    lsb-release \
    mariadb-client \
    mariadb-server \
    mtr-tiny \
    nginx-full \
    nmap \
    openssl \
    php-cli \
    php-curl \
    php-fpm \
    php-gd \
    php-gmp \
    php-mbstring \
    php-mysql \
    php-snmp \
    php-xml \
    php-zip \
    python3-command-runner \
    python3-dotenv \
    python3-pip \
    python3-psutil \
    python3-pymysql \
    python3-redis \
    python3-setuptools \
    python3-systemd \
    rrdtool \
    snmp \
    snmpd \
    unzip \
    wget \
    whois

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"

[[ "$(php -r 'echo PHP_VERSION_ID;')" -ge 80400 ]] || \
    fail "LibreNMS requires PHP 8.4 or newer."

log "Detected PHP $PHP_VERSION"

# --------------------------------------------------
# 4. Set timezone
# --------------------------------------------------

log "Configuring timezone"

timedatectl set-timezone "$TIMEZONE"

for ini in \
    "/etc/php/$PHP_VERSION/cli/php.ini" \
    "/etc/php/$PHP_VERSION/fpm/php.ini"
do
    sed -i -E \
        "s|^[; ]*date.timezone[ ]*=.*|date.timezone = $TIMEZONE|" \
        "$ini"

    grep -q '^date.timezone' "$ini" || \
        echo "date.timezone = $TIMEZONE" >> "$ini"
done

# --------------------------------------------------
# 5. Create LibreNMS user and download
# --------------------------------------------------

log "Downloading LibreNMS"

useradd -r -M -d "$INSTALL_DIR" -s /bin/bash librenms

git clone https://github.com/librenms/librenms.git "$INSTALL_DIR"

chown -R librenms:librenms "$INSTALL_DIR"
chmod 771 "$INSTALL_DIR"

setfacl -d -m g::rwx \
    "$INSTALL_DIR/rrd" \
    "$INSTALL_DIR/logs" \
    "$INSTALL_DIR/bootstrap/cache" \
    "$INSTALL_DIR/storage"

setfacl -R -m g::rwx \
    "$INSTALL_DIR/rrd" \
    "$INSTALL_DIR/logs" \
    "$INSTALL_DIR/bootstrap/cache" \
    "$INSTALL_DIR/storage"

# --------------------------------------------------
# 6. Install Composer dependencies
# --------------------------------------------------

log "Installing LibreNMS Composer dependencies"

runuser -u librenms -- bash -c \
    'cd /opt/librenms && ./scripts/composer_wrapper.php install --no-dev'

# --------------------------------------------------
# 7. Configure MariaDB
# --------------------------------------------------

log "Configuring MariaDB"

cat > /etc/mysql/mariadb.conf.d/99-librenms.cnf <<'EOF'
[mariadbd]
innodb_file_per_table=1
lower_case_table_names=0
EOF

systemctl enable mariadb
systemctl restart mariadb

mysql <<SQL
CREATE DATABASE IF NOT EXISTS $DB_NAME
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '$DB_USER'@'localhost'
    IDENTIFIED BY '$DB_PASSWORD';

ALTER USER '$DB_USER'@'localhost'
    IDENTIFIED BY '$DB_PASSWORD';

GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';

FLUSH PRIVILEGES;
SQL

# --------------------------------------------------
# 8. Configure PHP-FPM
# --------------------------------------------------

log "Configuring PHP-FPM"

cp "/etc/php/$PHP_VERSION/fpm/pool.d/www.conf" \
   "/etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf"

sed -i \
    -e 's/^\[www\]/[librenms]/' \
    -e 's/^user = .*/user = librenms/' \
    -e 's/^group = .*/group = librenms/' \
    -e "s|^listen = .*|listen = $PHP_SOCKET|" \
    "/etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf"

# --------------------------------------------------
# 9. Configure NGINX
# --------------------------------------------------

log "Configuring NGINX"

cat > /etc/nginx/sites-available/librenms <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;

    root $INSTALL_DIR/html;
    index index.php;

    charset utf-8;

    gzip on;
    gzip_types text/css application/javascript
        text/javascript application/x-javascript
        application/json image/svg+xml text/plain
        text/xsd text/xsl text/xml image/x-icon;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ [^/]\\.php(/|$) {
        fastcgi_pass unix:$PHP_SOCKET;
        fastcgi_split_path_info ^(.+\\.php)(/.+)$;
        include fastcgi.conf;
    }

    location ~ /\\. {
        deny all;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/librenms \
    /etc/nginx/sites-enabled/librenms

rm -f /etc/nginx/sites-enabled/default

nginx -t

# --------------------------------------------------
# 10. Configure SNMP
# --------------------------------------------------

log "Configuring SNMP"

cp "$INSTALL_DIR/snmpd.conf.example" /etc/snmp/snmpd.conf

sed -i "s/RANDOMSTRINGGOESHERE/$SNMP_COMMUNITY/g" \
    /etc/snmp/snmpd.conf

curl -fsSL \
    https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro \
    -o /usr/bin/distro

chmod +x /usr/bin/distro

# --------------------------------------------------
# 11. Cron and scheduler
# --------------------------------------------------

log "Configuring LibreNMS scheduler and cron"

cp "$INSTALL_DIR/dist/librenms.cron" /etc/cron.d/librenms
chmod 644 /etc/cron.d/librenms

cp "$INSTALL_DIR/dist/librenms-scheduler.service" \
   "$INSTALL_DIR/dist/librenms-scheduler.timer" \
   /etc/systemd/system/

cp "$INSTALL_DIR/misc/librenms.logrotate" \
   /etc/logrotate.d/librenms

chmod 644 /etc/logrotate.d/librenms

ln -sfn "$INSTALL_DIR/lnms" /usr/bin/lnms

mkdir -p /etc/bash_completion.d

cp "$INSTALL_DIR/misc/lnms-completion.bash" \
   /etc/bash_completion.d/

# --------------------------------------------------
# 12. Save installation credentials
# --------------------------------------------------

log "Saving credentials"

umask 077

cat > "$SECRETS" <<EOF
LIBRENMS_URL=http://$SERVER_NAME/
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
SNMP_COMMUNITY=$SNMP_COMMUNITY
TIMEZONE=$TIMEZONE
PHP_VERSION=$PHP_VERSION
EOF

chmod 600 "$SECRETS"

# --------------------------------------------------
# 13. Start services
# --------------------------------------------------

log "Enabling and starting services"

systemctl daemon-reload

systemctl enable nginx
systemctl enable "php$PHP_VERSION-fpm"
systemctl enable snmpd
systemctl enable cron
systemctl enable librenms-scheduler.timer

systemctl restart "php$PHP_VERSION-fpm"
systemctl restart nginx
systemctl restart snmpd
systemctl restart cron

systemctl start librenms-scheduler.timer

# --------------------------------------------------
# 14. Validate
# --------------------------------------------------

log "Running LibreNMS validation"

runuser -u librenms -- bash -c \
    'cd /opt/librenms && ./validate.php' || \
    echo "WARNING: Validation reported issues. Review output."

# --------------------------------------------------
# 15. Installation summary
# --------------------------------------------------

echo
echo "================================================"
echo "       LIBRENMS INSTALLATION COMPLETED"
echo "================================================"
echo
echo "URL: http://$SERVER_NAME/install"
echo "Installation directory: $INSTALL_DIR"
echo "PHP version: $PHP_VERSION"
echo "Timezone: $TIMEZONE"
echo
echo "Credentials saved in:"
echo "$SECRETS"
echo
echo "IMPORTANT:"
echo "1. Complete the web installer."
echo "2. Configure HTTPS before public access."
echo "3. Back up the LibreNMS .env file."
echo "4. Keep the credentials file secure."
echo
echo "================================================"
