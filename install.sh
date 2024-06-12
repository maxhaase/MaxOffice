#!/bin/bash

# Load environment variables from vars.env
set -o allexport
source vars.env
set +o allexport

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

# Function to check port availability
check_port() {
  if lsof -Pi :$1 -sTCP:LISTEN -t >/dev/null ; then
    echo "Port $1 is already in use. Exiting."
    exit 1
  fi
}

# Check all necessary ports
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

# Update and install necessary packages
echo "Updating package lists and installing necessary packages..."
apt-get update -y
apt-get install -y apache2 apt-transport-https ca-certificates certbot curl mailutils python3-certbot-apache software-properties-common

# Add Docker’s official GPG key and setup Docker repository
if [ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]; then
  echo "Adding Docker's official GPG key..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
fi

if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  echo "Setting up the Docker repository..."
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
fi

# Install Docker and Docker Compose
echo "Installing Docker..."
apt-get update -y
apt-get install -y containerd.io docker-ce docker-ce-cli

echo "Installing Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Start Docker service and add user to Docker group
echo "Enabling and starting Docker service..."
systemctl enable docker
systemctl start docker
usermod -aG docker $USER

# Configure firewall rules
echo "Configuring firewall rules..."
for PORT in 25 465 587 110 995 143 993 8080 8000 8001 80 443; do
  ufw allow $PORT
done

ufw allow OpenSSH
ufw allow "Apache Full"
ufw --force enable

echo "Firewall rules configured."

# Create docker-compose.yml file
echo "Creating docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: '3.7'
services:
  db_shared:
    image: mysql:${MYSQL_VERSION}
    container_name: db_shared
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - webnet

  wordpress1:
    image: wordpress:${WORDPRESS_VERSION}
    container_name: wordpress1
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
    ports:
      - "${DOMAIN1_PORT}:80"
    networks:
      - webnet

  wordpress2:
    image: wordpress:${WORDPRESS_VERSION}
    container_name: wordpress2
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
    ports:
      - "${DOMAIN2_PORT}:80"
    networks:
      - webnet

  mailserver:
    image: mailserver/docker-mailserver:${MAILSERVER_VERSION}
    container_name: mailserver
    restart: always
    env_file: mail.env
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
    networks:
      - webnet

  webmail:
    image: roundcube/roundcubemail:${ROUNDCUBEMAIL_VERSION}
    container_name: webmail
    restart: always
    ports:
      - "${WEBMAIL_PORT}:80"
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: mail.${MAIL_DOMAIN}
    networks:
      - webnet

  postfixadmin:
    image: hardware/postfixadmin
    container_name: postfixadmin
    restart: always
    ports:
      - "8080:80"
    environment:
      ADMIN_USER: ${POSTFIXADMIN_ADMIN_USER}
      ADMIN_PASS: ${POSTFIXADMIN_ADMIN_PASS}
      POSTFIXADMIN_SETUP_PASS: ${POSTFIXADMIN_SETUP_PASS}
      POSTFIXADMIN_MAIL: ${POSTFIXADMIN_EMAIL}
    networks:
      - webnet

volumes:
  db_data:
  maildata:
  mailstate:
  maillogs:

networks:
  webnet:
EOF
echo "docker-compose.yml created."

# Create mail.env file for Docker Mailserver
echo "Creating mail.env..."
cat > mail.env <<EOF
POSTMASTER_ADDRESS=postmaster@${MAIL_DOMAIN}
EOF
echo "mail.env created."

#!/bin/bash

# Load environment variables from vars.env
set -o allexport
source vars.env
set +o allexport

# Deploy Docker containers
echo "Deploying Docker containers..."
docker-compose up -d
if [ $? -ne 0 ]; then
  echo "Docker deployment failed. Exiting."
  exit 1
fi
echo "Docker containers deployed."

# Wait for MySQL to be ready
echo "Waiting for MySQL to be ready..."
while ! docker exec -it db_shared mysqladmin --user=root --password=${MYSQL_ROOT_PASSWORD} ping --silent &> /dev/null ; do
  echo "Waiting for database connection..."
  sleep 2
done
echo "Database connection verified."

# Setting up Let's Encrypt certificates
echo "Setting up Let's Encrypt for ${DOMAIN1}, ${DOMAIN2}, ${MAIL_DOMAIN}, and ${WEBMAIL_DOMAIN}..."
certbot certonly --standalone -d ${DOMAIN1} -d ${DOMAIN2} -d ${MAIL_DOMAIN} -d ${WEBMAIL_DOMAIN} --non-interactive --agree-tos --email ${POSTFIXADMIN_EMAIL} --expand
if [ $? -ne 0 ]; then
  echo "Let's Encrypt setup failed. Exiting."
  exit 1
fi
echo "Let's Encrypt setup completed."

# Configure Apache virtual hosts
configure_apache_virtual_host() {
  DOMAIN=$1
  sudo tee /etc/apache2/sites-available/${DOMAIN}.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    Redirect permanent / https://${DOMAIN}/
</VirtualHost>
<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN}/privkey.pem
</VirtualHost>
EOF
  sudo a2ensite ${DOMAIN}
}

echo "Configuring Apache virtual hosts..."
configure_apache_virtual_host ${DOMAIN1}
configure_apache_virtual_host ${DOMAIN2}
configure_apache_virtual_host ${MAIL_DOMAIN}
configure_apache_virtual_host ${WEBMAIL_DOMAIN}

# Restart Apache to apply changes
echo "Restarting Apache..."
systemctl restart apache2

echo "Apache virtual host configuration completed."

# Display access URLs
echo "You can access your applications at the following URLs:"
echo "WordPress 1: https://${DOMAIN1}"
echo "WordPress 2: https://${DOMAIN2}"
echo "Mailserver: https://${MAIL_DOMAIN}"
echo "Webmail: https://${WEBMAIL_DOMAIN}"

# Checking the status of Docker containers
echo "Checking the status of Docker containers..."
docker-compose ps

echo "Installation and setup complete."

