#!/bin/sh
set -e

DB_PASS=$(cat /run/secrets/db_password)
. /run/secrets/credentials

cd /var/www/html

if [ ! -f "wp-config.php" ]; then
    echo "[wordpress] downloading core"
    wp core download --allow-root

    echo "[wordpress] creating configuration"
    wp config create \
        --dbname="${MYSQL_DATABASE}" \
        --dbuser="${MYSQL_USER}" \
        --dbpass="${DB_PASS}" \
        --dbhost=mariadb:3306 \
        --allow-root

    echo "[wordpress] installing site"
    wp core install \
        --url="https://${DOMAIN_NAME}" \
        --title="${WP_TITLE}" \
        --admin_user="${WP_ADMIN_USER}" \
        --admin_password="${WP_ADMIN_PASSWORD}" \
        --admin_email="${WP_ADMIN_EMAIL}" \
        --skip-email \
        --allow-root

    echo "[wordpress] creating second user"
    wp user create "${WP_USER}" "${WP_USER_EMAIL}" \
        --role=author \
        --user_pass="${WP_USER_PASSWORD}" \
        --allow-root

    chown -R www-data:www-data /var/www/html
    echo "[wordpress] installation complete"
else
    echo "[wordpress] already installed, skipping"
fi

exec php-fpm8.2 -F
