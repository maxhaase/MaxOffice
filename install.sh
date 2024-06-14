#!/bin/bash

# Load environment variables
source vars.env

# Update package lists and install necessary packages
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    software-properties-common \
    apt-transport-https \
    certbot \
    docker.io \
    docker-compose \
    ufw

# Remove Apache if installed
sudo apt-get remove -y apache2 apache2-bin apache2-utils apache2.2-common

# Add user to Docker group
sudo usermod -aG docker ${USER}

# Configure firewall rules
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow ${SMTP_PORT}/tcp
sudo ufw allow ${SMTPS_PORT}/tcp
sudo ufw allow ${SMTP_ALT_PORT}/tcp
sudo ufw allow ${POP3_PORT}/tcp
sudo ufw allow ${POP3S_PORT}/tcp
sudo ufw allow ${IMAP_PORT}/tcp
sudo ufw allow ${IMAPS_PORT}/tcp
sudo ufw allow ${WEBMAIL_PORT}/tcp
sudo ufw allow ${DOMAIN1_PORT}/tcp
sudo ufw allow ${DOMAIN2_PORT}/tcp
sudo ufw allow ${ADMIN_GUI_PORT}/tcp
sudo ufw --force enable

# Check if certs.tar exists, if not, generate new certificates
if [ ! -f "certs.tar" ]; then
    echo "No existing certificates found, requesting new ones."
    sudo certbot certonly --standalone --email $CERT_EMAIL --agree-tos --no-eff-email -d $DOMAIN1 -d $DOMAIN2 -d $MAIL_DOMAIN -d $ADMIN_DOMAIN -d $WEBMAIL_DOMAIN
    sudo tar -cvf certs.tar /etc/letsencrypt
else
    sudo tar -xvf certs.tar -C /
fi

# Create Docker compose file
cat <<EOF > docker-compose.yml
version: '${DOCKER_COMPOSE_VERSION}'

services:
  db_shared:
    image: mysql:${MYSQL_VERSION}
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ${VOLUME_DB_DATA}:/var/lib/mysql
    command: --explicit_defaults_for_timestamp

  wordpress1:
    image: wordpress:${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_DOMAIN1}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER_DOMAIN1}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD_DOMAIN1}
    ports:
      - "${DOMAIN1_PORT}:80"
    depends_on:
      - db_shared

  wordpress2:
    image: wordpress:${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_DOMAIN2}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER_DOMAIN2}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD_DOMAIN2}
    ports:
      - "${DOMAIN2_PORT}:80"
    depends_on:
      - db_shared

  mailserver:
    image: mailserver/docker-mailserver:${MAILSERVER_VERSION}
    hostname: mail
    domainname: ${MAIL_DOMAIN}
    env_file: mail.env
    volumes:
      - ${VOLUME_MAILDATA}:/var/mail
      - ${VOLUME_MAILSTATE}:/var/mail-state
      - ${VOLUME_MAILLOGS}:/var/log/mail
      - ./config/:/tmp/docker-mailserver/
      - /etc/letsencrypt:/etc/letsencrypt
    ports:
      - "${SMTP_PORT}:25"
      - "${IMAP_PORT}:143"
      - "${SMTP_ALT_PORT}:587"
      - "${IMAPS_PORT}:993"
    environment:
      - ONE_DIR=1
      - DMS_DEBUG=0
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    restart: always

  webmail:
    image: roundcube/roundcubemail:${ROUNDCUBEMAIL_VERSION}
    ports:
      - "${WEBMAIL_PORT}:80"
    depends_on:
      - mailserver
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: imap
      ROUNDCUBEMAIL_SMTP_SERVER: smtp

  postfixadmin:
    image: hardware/postfixadmin:latest
    environment:
      POSTFIXADMIN_DB_HOST: db_shared
      POSTFIXADMIN_DB_USER: ${POSTFIXADMIN_DB_USER}
      POSTFIXADMIN_DB_PASSWORD: ${POSTFIXADMIN_DB_PASSWORD}
    depends_on:
      - db_shared
    ports:
      - "${ADMIN_GUI_PORT}:80"

volumes:
  db_data:
  maildata:
  mailstate:
  maillogs:
EOF

# Create mail.env file for mailserver configuration
cat <<EOF > mail.env
PERMIT_DOCKER=network
ENABLE_SPAMASSASSIN=1
ENABLE_CLAMAV=1
ENABLE_FAIL2BAN=1
SSL_TYPE=letsencrypt
SSL_CERT_PATH=/etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem
SSL_KEY_PATH=/etc/letsencrypt/live/${MAIL_DOMAIN}/privkey.pem
EOF

# Deploy Docker containers
sudo docker-compose up -d

# Wait for containers to start
sleep 30

# Create a mail account if not exists
sudo docker exec -it mailserver setup email add ${POSTFIXADMIN_EMAIL} ${POSTFIXADMIN_ADMIN_PASS}

echo "Installation and setup complete."
echo "You can access your applications at the following URLs:"
echo "WordPress 1: http://${DOMAIN1}"
echo "WordPress 2: http://${DOMAIN2}"
echo "Mailserver: http://${MAIL_DOMAIN}"
echo "Webmail: http://${WEBMAIL_DOMAIN}"
echo "Postfix Admin: http://${ADMIN_DOMAIN}"
