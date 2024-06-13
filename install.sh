#!/bin/bash

# Load environment variables from vars.env
source ./vars.env

# Remove duplicate entries from sources list
function remove_duplicate_sources() {
    awk '!x[$0]++' /etc/apt/sources.list > /tmp/sources.list && sudo mv /tmp/sources.list /etc/apt/sources.list
    for FILE in /etc/apt/sources.list.d/*; do
        awk '!x[$0]++' $FILE > /tmp/temp.list && sudo mv /tmp/temp.list $FILE
    done
}

echo "Removing duplicate sources..."
remove_duplicate_sources
sudo apt-get update

# Remove Apache if installed
sudo apt-get purge -y apache2 apache2-utils apache2-bin
sudo apt-get autoremove -y
sudo apt-get autoclean

# Add Docker repository if not present
if ! grep -q "^deb .*download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    sudo apt-get update
fi

# Install Docker
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker ${USER}

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Firewall rules
for port in ${SMTP_PORT} ${SMTPS_PORT} ${SMTP_ALT_PORT} ${POP3_PORT} ${POP3S_PORT} ${IMAP_PORT} ${IMAPS_PORT} 80 443; do
    sudo ufw allow $port
done
echo "y" | sudo ufw enable
sudo ufw reload

# Decompress certificates
tar -xzvf ./certs.tar.gz -C ./certs

# Create Apache configuration
mkdir -p ./apache-config
cat <<EOF > ./apache-config/httpd.conf
ServerName ${DOMAIN1}
LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
IncludeOptional conf.d/*.conf
EOF

# Create mail.env file
cat <<EOF > mail.env
POSTMASTER_ADDRESS=${POSTFIXADMIN_EMAIL}
MAIL_USER=${MAIL_USER}
HOSTNAME=${MAIL_DOMAIN}
DOMAINNAME=${MAIL_DOMAIN}
EOF

# Create docker-compose.yml file
cat <<EOF > docker-compose.yml
version: '3.7'

services:
  db_shared:
    image: mysql:${MYSQL_VERSION}
    volumes:
      - db_data:/var/lib/mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}

  wordpress1:
    image: wordpress:${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    depends_on:
      - db_shared

  wordpress2:
    image: wordpress:${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    depends_on:
      - db_shared

  apache:
    image: httpd:2.4
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./apache-config:/usr/local/apache2/conf
      - ./certs:/usr/local/apache2/certs
    environment:
      - SERVER_NAME=${DOMAIN1}
    restart: always

  mailserver:
    image: mailserver/docker-mailserver:${MAILSERVER_VERSION}
    env_file: mail.env
    ports:
      - "${SMTP_PORT}:25"
      - "${POP3_PORT}:110"
      - "${SMTP_ALT_PORT}:587"
      - "${IMAPS_PORT}:993"
    volumes:
      - maildata:/var/mail
      - maillogs:/var/log/mail
      - /etc/localtime:/etc/localtime:ro
      - ./config/:/tmp/docker-mailserver/
    environment:
      - ENABLE_SPAMASSASSIN=1
      - ENABLE_CLAMAV=1
      - ENABLE_FAIL2BAN=1
      - ONE_DIR=1
      - DMS_DEBUG=0
      - POSTMASTER_ADDRESS=${POSTFIXADMIN_EMAIL}
      - MAIL_USER=${MAIL_USER}
      - HOSTNAME=${MAIL_DOMAIN}
      - DOMAINNAME=${MAIL_DOMAIN}
    restart: always

  webmail:
    image: roundcube/roundcubemail:${ROUNDCUBEMAIL_VERSION}
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: imap
      ROUNDCUBEMAIL_SMTP_SERVER: smtp
      ROUNDCUBEMAIL_DES_KEY: randomstring
      ROUNDCUBEMAIL_DB_TYPE: mysql
      ROUNDCUBEMAIL_DB_HOST: db_shared
      ROUNDCUBEMAIL_DB_USER: ${MYSQL_USER}
      ROUNDCUBEMAIL_DB_PASSWORD: ${MYSQL_PASSWORD}
      ROUNDCUBEMAIL_DB_NAME: roundcubemail
    depends_on:
      - db_shared

  postfixadmin:
    image: hardware/postfixadmin:latest
    environment:
      - DBPASS=${MYSQL_PASSWORD}
      - DBHOST=db_shared
      - DBUSER=${MYSQL_USER}
      - DBNAME=postfixadmin
      - POSTFIXADMIN_ADMIN_USER=${POSTFIXADMIN_ADMIN_USER}
      - POSTFIXADMIN_ADMIN_PASS=${POSTFIXADMIN_ADMIN_PASS}
      - POSTFIXADMIN_EMAIL=${POSTFIXADMIN_EMAIL}
    depends_on:
      - db_shared

volumes:
  db_data:
  maildata:
  maillogs:
  mailstate:
  postfixadmin_data:
EOF

# Deploying Docker containers
docker-compose up -d

echo "Installation and setup complete."
echo "You can access your applications at the following URLs:"
echo "WordPress 1: https://${DOMAIN1}"
echo "WordPress 2: https://${DOMAIN2}"
echo "Mailserver: https://${MAIL_DOMAIN}"
echo "Webmail: https://${WEBMAIL_DOMAIN}"
echo "Postfix Admin: https://${ADMIN_DOMAIN}"

