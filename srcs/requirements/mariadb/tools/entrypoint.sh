#!/bin/sh
set -e

DB_ROOT_PASS=$(cat /run/secrets/db_root_password)
DB_PASS=$(cat /run/secrets/db_password)

if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "[mariadb] installing system tables"
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql --skip-test-db > /dev/null
fi

if [ ! -d "/var/lib/mysql/${MYSQL_DATABASE}" ]; then
    echo "[mariadb] bootstrapping database and users"

    cat > /tmp/init.sql <<EOF
USE mysql;
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOF

    if ! mariadbd --user=mysql --bootstrap < /tmp/init.sql; then
        echo "[mariadb] BOOTSTRAP FAILED"
        rm -f /tmp/init.sql
        exit 1
    fi
    rm -f /tmp/init.sql
    echo "[mariadb] bootstrap complete"
else
    echo "[mariadb] database already present, skipping bootstrap"
fi

exec mariadbd --user=mysql --console
