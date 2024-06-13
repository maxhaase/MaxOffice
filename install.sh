#!/bin/bash

# Load environment variables
source vars.env

# Function to check if a package is installed
is_installed() {
    dpkg -l | grep -qw "$1"
}

# Update package lists and install necessary packages
echo 'Updating package lists and installing necessary packages...'
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl software-properties-common apt-transport-https certbot

# Remove any existing installations of Apache on the host
echo 'Removing Apache from the host...'
sudo apt-get purge -y apache2 apache2-utils apache2-bin apache2.2-common
sudo apt-get autoremove -y
sudo apt-get autoclean

# Install Docker if it's not already installed
if ! is_installed docker-ce; then
    echo 'Installing Docker...'
    sudo apt-get remove -y docker docker-engine docker.io containerd runc
    sudo apt-get update -y
    sudo apt-get install -y containerd.io docker-ce docker-ce-cli
fi

# Install Docker Compose if it's not already installed
if ! command -v docker-compose &> /dev/null; then
    echo 'Installing Docker Compose...'
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

# Add the user to the Docker group
echo 'Adding user to Docker group...'
sudo usermod -aG docker $USER

# Configure firewall rules
echo 'Configuring firewall rules...'
ports=(${SMTP_PORT} ${SMTPS_PORT} ${SMTP_ALT_PORT} ${POP3_PORT} ${POP3S_PORT} ${IMAP_PORT} ${IMAPS_PORT} ${WEBMAIL_PORT} ${DOMAIN1_PORT} ${DOMAIN2_PORT} 80 443)
for port in "${ports[@]}"; do
  sudo ufw allow ${port}/tcp
done
echo y | sudo ufw enable
sudo ufw reload

# Decompress certificates
echo 'Decompressing certificates...'
if [ -f certs.tar ]; then
  mkdir -p etc
  tar -xvf certs.tar -C etc
else
  echo "certs.tar not found, skipping certificate decompression."
fi

# Create docker-compose.yml
echo 'Creating docker-compose.yml...'
cat <<EOL > docker-compose.yml
version: '3'

services:
  db_shared:
    image: mysql:${MYSQL_VERSION}
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql

  wordpress1:
    image: wordpress:${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    depends_on:
      - db_shared
    ports:
      - "${DOMAIN1_PORT}:80"

  wordpress2:
    image: wordpress:${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    depends_on:
      - db_shared
    ports:
      - "${DOMAIN2_PORT}:80"

  apache:
    image: httpd:2.4
    volumes:
      - ./etc/letsencrypt:/etc/letsencrypt
      - ./apache-config:/usr/local/apache2/conf
    ports:
      - "80:80"
      - "443:443"
    environment:
      - SERVER_NAME=${DOMAIN1}

  mailserver:
    image: mailserver/docker-mailserver:${MAILSERVER_VERSION}
    hostname: ${MAIL_DOMAIN}
    domainname: ${MAIL_DOMAIN}
    environment:
      ENABLE_SPAMASSASSIN: 1
      ENABLE_CLAMAV: 1
      ENABLE_FAIL2BAN: 1
    ports:
      - "${SMTP_PORT}:25"
      - "${SMTPS_PORT}:465"
      - "${SMTP_ALT_PORT}:587"
      - "${POP3_PORT}:110"
      - "${POP3S_PORT}:995"
      - "${IMAP_PORT}:143"
      - "${IMAPS_PORT}:993"
    volumes:
      - maildata:/var/mail
      - maillogs:/var/log/mail
      - mailstate:/var/mail-state
      - ./mail.env:/tmp/docker-mailserver/mailserver.env

  webmail:
    image: roundcube/roundcubemail:${ROUNDCUBEMAIL_VERSION}
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: imap
      ROUNDCUBEMAIL_SMTP_SERVER: smtp
    depends_on:
      - mailserver
    ports:
      - "${WEBMAIL_PORT}:80"

  postfixadmin:
    image: hardware/postfixadmin:latest
    environment:
      ADMIN_EMAIL: ${POSTFIXADMIN_EMAIL}
      ADMIN_PASSWORD: ${POSTFIXADMIN_ADMIN_PASS}
    ports:
      - "8081:80"

volumes:
  db_data:
  maildata:
  maillogs:
  mailstate:
  postfixadmin_data:
EOL

# Create mail.env
echo 'Creating mail.env...'
cat <<EOL > mail.env
HOSTNAME=${MAIL_DOMAIN}
DOMAINNAME=${MAIL_DOMAIN}
SMTP_PORT=${SMTP_PORT}
SMTPS_PORT=${SMTPS_PORT}
SMTP_ALT_PORT=${SMTP_ALT_PORT}
POP3_PORT=${POP3_PORT}
POP3S_PORT=${POP3S_PORT}
IMAP_PORT=${IMAP_PORT}
IMAPS_PORT=${IMAPS_PORT}
POSTFIXADMIN_ADMIN_USER=${POSTFIXADMIN_ADMIN_USER}
POSTFIXADMIN_ADMIN_PASS=${POSTFIXADMIN_ADMIN_PASS}
POSTFIXADMIN_EMAIL=${POSTFIXADMIN_EMAIL}
POSTFIX_USER=${POSTFIX_USER}
EOL

# Deploy Docker containers
echo 'Deploying Docker containers...'
docker-compose up -d

# Ensure Apache container is using the correct server name
echo 'Configuring Apache in the container...'
APACHE_CONTAINER_ID=$(docker ps -qf "name=office_apache_1")
if [ -n "$APACHE_CONTAINER_ID" ]; then
    docker exec -it "$APACHE_CONTAINER_ID" bash -c "echo 'ServerName ${DOMAIN1}' >> /usr/local/apache2/conf/httpd.conf && apachectl restart"
else
    echo "Error: Apache container not found."
fi

# Display completion message
echo 'Installation and setup complete.'
echo 'You can access your applications at the following URLs:'
echo "WordPress 1: https://${DOMAIN1}"
echo "WordPress 2: https://${DOMAIN2}"
echo "Mailserver: https://${MAIL_DOMAIN}"
echo "Webmail: https://${WEBMAIL_DOMAIN}"
echo "Postfix Admin: https://${ADMIN_DOMAIN}"

