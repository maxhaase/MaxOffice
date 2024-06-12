#!/bin/bash

# Load environment variables
echo "Loading environment variables from vars.env..."
source vars.env
echo "Loaded environment variables."

# Update package lists and install necessary packages
echo "Updating package lists and installing necessary packages..."
sudo apt-get update -y
sudo apt-get install -y apache2 apt-transport-https ca-certificates certbot curl mailutils python3-certbot-apache software-properties-common
echo "Packages installed."

# Add Docker's official GPG key
echo "Adding Docker's official GPG key..."
if [ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "Docker's official GPG key added."
else
  echo "Docker's official GPG key already exists. Skipping."
fi

# Set up the Docker repository
echo "Setting up the Docker repository..."
if ! grep -q "^deb \[arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg\] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
  echo "deb \[arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg\] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  echo "Docker repository set up."
else
  echo "Docker repository already set up. Skipping."
fi

# Install Docker
echo "Installing Docker..."
sudo apt-get install -y containerd.io docker-ce docker-ce-cli
echo "Docker installed."

# Install Docker Compose
echo "Installing Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
echo "Docker Compose installed."

# Enable and start Docker service
echo "Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker
echo "Docker service started."

# Add user to the docker group
echo "Adding user to the docker group..."
sudo usermod -aG docker $USER
echo "User added to the docker group."

# Configure firewall rules
echo "Configuring firewall rules..."
ports=(${SMTP_PORT} ${SMTPS_PORT} ${SMTP_ALT_PORT} ${POP3_PORT} ${POP3S_PORT} ${IMAP_PORT} ${IMAPS_PORT} 80 443 22 ${DOMAIN1_PORT} ${DOMAIN2_PORT} ${WEBMAIL_PORT})
for port in "${ports[@]}"; do
  sudo ufw allow $port
done
sudo ufw enable
sudo ufw status
echo "Firewall rules configured."

# Create docker-compose.yml
echo "Creating docker-compose.yml..."
sudo tee docker-compose.yml > /dev/null <<EOF
version: '3.7'

services:
  db_shared:
    image: mysql:${MYSQL_VERSION}
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql

  wordpress1:
    image: wordpress:${WORDPRESS_VERSION}
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
    ports:
      - "${DOMAIN1_PORT}:80"
    depends_on:
      - db_shared

  wordpress2:
    image: wordpress:${WORDPRESS_VERSION}
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
    ports:
      - "${DOMAIN2_PORT}:80"
    depends_on:
      - db_shared

  mailserver:
    image: tvial/docker-mailserver:${MAILSERVER_VERSION}
    hostname: mail
    domainname: ${MAIL_DOMAIN}
    container_name: mail
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
      - mailstate:/var/mail-state
      - maillogs:/var/log/mail
      - ./config/:/tmp/docker-mailserver/
    environment:
      - ENABLE_SPAMASSASSIN=1
      - ENABLE_CLAMAV=1
      - ENABLE_FAIL2BAN=1
      - ONE_DIR=1
      - DMS_DEBUG=0
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    depends_on:
      - db_shared

  webmail:
    image: roundcube/roundcubemail:${ROUNDCUBEMAIL_VERSION}
    ports:
      - "${WEBMAIL_PORT}:80"
    depends_on:
      - mailserver
    environment:
      - ROUNDCUBEMAIL_DEFAULT_HOST=mail.${MAIL_DOMAIN}
      - ROUNDCUBEMAIL_SMTP_SERVER=mail.${MAIL_DOMAIN}
      - ROUNDCUBEMAIL_DES_KEY=${ROUNDCUBEMAIL_DES_KEY}
      - ROUNDCUBEMAIL_DB_TYPE=mysql
      - ROUNDCUBEMAIL_DB_HOST=db_shared
      - ROUNDCUBEMAIL_DB_USER=${MYSQL_USER}
      - ROUNDCUBEMAIL_DB_PASSWORD=${MYSQL_PASSWORD}
      - ROUNDCUBEMAIL_DB_NAME=${MYSQL_DATABASE}

  postfixadmin:
    image: hardware/postfixadmin
    ports:
      - "8080:80"
    depends_on:
      - db_shared
    environment:
      - DBPASS=${MYSQL_PASSWORD}
      - DBUSER=${MYSQL_USER}
      - DBDATABASE=${MYSQL_DATABASE}
      - DBHOST=db_shared
      - POSTFIXADMIN_SETUP_PASSWORD=${POSTFIXADMIN_ADMIN_PASS}
      - POSTFIXADMIN_SETUP_EMAIL=${POSTFIXADMIN_EMAIL}

volumes:
  db_data:
  maildata:
  mailstate:
  maillogs:
EOF
echo "docker-compose.yml created."


# Create mail.env file for Docker Mailserver
echo "Creating mail.env..."
sudo tee mail.env > /dev/null <<EOF
POSTMASTER_ADDRESS=postmaster@${MAIL_DOMAIN}
EOF
echo "mail.env created."

# Check port availability before deploying Docker containers
check_port() {
  if lsof -Pi :$1 -sTCP:LISTEN -t >/dev/null ; then
    echo "Port $1 is already in use. Exiting."
    exit 1
  fi
}

check_port ${DOMAIN1_PORT}
check_port ${DOMAIN2_PORT}
check_port ${SMTP_PORT}
check_port ${SMTPS_PORT}
check_port ${SMTP_ALT_PORT}
check_port ${POP3_PORT}
check_port ${POP3S_PORT}
check_port ${IMAP_PORT}
check_port ${IMAPS_PORT}
check_port ${WEBMAIL_PORT}

echo "Deploying Docker containers..."
sudo /usr/local/bin/docker-compose up -d
echo "Docker containers deployed."

echo "Waiting for MySQL to be ready..."
while ! docker exec -it $(docker ps -q -f name=db_shared) mysqladmin --user=root --password=${MYSQL_ROOT_PASSWORD} ping --silent &> /dev/null ; do
  echo "Waiting for database connection..."
  sleep 2
done
echo "Database connection verified."

echo "Setting up Let's Encrypt for ${DOMAIN1}, ${DOMAIN2}, ${MAIL_DOMAIN}, and ${WEBMAIL_DOMAIN}..."
sudo certbot certonly --standalone -d ${DOMAIN1} -d ${DOMAIN2} -d ${MAIL_DOMAIN} -d ${WEBMAIL_DOMAIN} --non-interactive --agree-tos --email ${POSTFIXADMIN_EMAIL} --expand
echo "Let's Encrypt setup completed."

echo "Configuring Apache virtual host for ${DOMAIN1}..."
sudo tee /etc/apache2/sites-available/${DOMAIN1}.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN1}
    Redirect permanent / https://${DOMAIN1}/
</VirtualHost>
<VirtualHost *:443>
    ServerName ${DOMAIN1}
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${DOMAIN1}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN1}/privkey.pem
    <Directory /var/www/html>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF
sudo a2ensite ${DOMAIN1}.conf
sudo systemctl reload apache2
echo "Apache virtual host configured for ${DOMAIN1}."

echo "Configuring Apache virtual host for ${DOMAIN2}..."
sudo tee /etc/apache2/sites-available/${DOMAIN2}.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN2}
    Redirect permanent / https://${DOMAIN2}/
</VirtualHost>
<VirtualHost *:443>
    ServerName ${DOMAIN2}
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${DOMAIN2}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN2}/privkey.pem
    <Directory /var/www/html>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF
sudo a2ensite ${DOMAIN2}.conf
sudo systemctl reload apache2
echo "Apache virtual host configured for ${DOMAIN2}."

echo "Configuring Apache virtual host for ${MAIL_DOMAIN}..."
sudo tee /etc/apache2/sites-available/${MAIL_DOMAIN}.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName ${MAIL_DOMAIN}
    Redirect permanent / https://${MAIL_DOMAIN}/
</VirtualHost>
<VirtualHost *:443>
    ServerName ${MAIL_DOMAIN}
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${MAIL_DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${MAIL_DOMAIN}/privkey.pem
    <Directory /var/www/html>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF
sudo a2ensite ${MAIL_DOMAIN}.conf
sudo systemctl reload apache2
echo "Apache virtual host configured for ${MAIL_DOMAIN}."

echo "Configuring Apache virtual host for ${WEBMAIL_DOMAIN}..."
sudo tee /etc/apache2/sites-available/${WEBMAIL_DOMAIN}.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName ${WEBMAIL_DOMAIN}
    Redirect permanent / https://${WEBMAIL_DOMAIN}/
</VirtualHost>
<VirtualHost *:443>
    ServerName ${WEBMAIL_DOMAIN}
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${WEBMAIL_DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${WEBMAIL_DOMAIN}/privkey.pem
    <Directory /var/www/html>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF
sudo a2ensite ${WEBMAIL_DOMAIN}.conf
sudo systemctl reload apache2
echo "Apache virtual host configured for ${WEBMAIL_DOMAIN}."

echo "You can access your applications at the following URLs:"
echo "WordPress 1: https://${DOMAIN1}"
echo "WordPress 2: https://${DOMAIN2}"
echo "Mailserver: https://${MAIL_DOMAIN}"
echo "Webmail: https://${WEBMAIL_DOMAIN}"

# Check the status of Docker containers
echo "Checking the status of Docker containers..."
sudo /usr/local/bin/docker-compose ps
echo "Installation and setup complete."

