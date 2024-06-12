#!/bin/bash

# Load environment variables
source vars.env

# Update package lists and install necessary packages
echo "Updating package lists and installing necessary packages..."
sudo apt-get update -y
sudo apt-get install -y \
  apache2 \
  ca-certificates \
  curl \
  software-properties-common \
  apt-transport-https \
  certbot \
  python3-certbot-apache

# Install Docker
echo "Installing Docker..."
sudo apt-get remove -y docker docker-engine docker.io containerd runc
sudo apt-get update -y
sudo apt-get install -y \
  containerd.io \
  docker-ce \
  docker-ce-cli

# Install Docker Compose
echo "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Enable and start Docker service
echo "Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

# Configure firewall rules
echo "Configuring firewall rules..."
ports=(${SMTP_PORT} ${SMTPS_PORT} ${SMTP_ALT_PORT} ${POP3_PORT} ${POP3S_PORT} ${IMAP_PORT} ${IMAPS_PORT} ${WEBMAIL_PORT} ${DOMAIN1_PORT} ${DOMAIN2_PORT} 80 443)
for port in "${ports[@]}"; do
  sudo ufw allow $port
  sudo ufw allow $port/tcp
done
sudo ufw enable
sudo ufw reload

# Create docker-compose.yml
echo "Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: '3.8'

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
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
    ports:
      - "${DOMAIN1_PORT}:80"
    depends_on:
      - db_shared

  wordpress2:
    image: wordpress:${WORDPRESS_VERSION}
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
    image: mailserver/docker-mailserver:${MAILSERVER_VERSION}
    hostname: mail
    domainname: ${MAIL_DOMAIN}
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

  webmail:
    image: roundcube/roundcubemail:${ROUNDCUBEMAIL_VERSION}
    ports:
      - "${WEBMAIL_PORT}:80"
    environment:
      - ROUNDCUBEMAIL_DEFAULT_HOST=ssl://mail
      - ROUNDCUBEMAIL_SMTP_SERVER=ssl://mail

  postfixadmin:
    image: hardware/postfixadmin:latest
    ports:
      - "8081:80"
    environment:
      - ADMIN_USERNAME=${POSTFIXADMIN_ADMIN_USER}
      - ADMIN_PASSWORD=${POSTFIXADMIN_ADMIN_PASS}
      - ADMIN_EMAIL=${POSTFIXADMIN_EMAIL}
    volumes:
      - postfixadmin_data:/data

volumes:
  db_data:
  maildata:
  mailstate:
  maillogs:
  postfixadmin_data:
EOF

echo "# END OF PART 1"

# Create mail.env
echo "Creating mail.env..."
cat <<EOF > mail.env
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
EOF


#!/bin/bash

# Load environment variables
source vars.env

# Deploy Docker containers
echo "Deploying Docker containers..."
sudo docker-compose up -d

# Wait for MySQL to be ready
echo "Waiting for MySQL to be ready..."
while ! sudo docker exec -it $(sudo docker ps -qf "name=db_shared") mysqladmin ping -h "localhost" --silent; do
    echo "Waiting for database connection..."
    sleep 5
done
echo "Database connection verified."

# Obtain Let's Encrypt certificates
domains=(${DOMAIN1} ${DOMAIN2} ${MAIL_DOMAIN} ${WEBMAIL_DOMAIN} ${ADMIN_DOMAIN})
for domain in "${domains[@]}"; do
  echo "Obtaining certificate for $domain..."
  sudo systemctl stop apache2
  sudo certbot certonly --standalone --non-interactive --agree-tos --email your-email@example.com -d $domain
  sudo systemctl start apache2
done

# Enable SSL module
sudo a2enmod ssl

# Configure Apache virtual hosts
echo "Configuring Apache virtual hosts..."
for domain in "${domains[@]}"; do
  sudo cp /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/$domain.conf
  sudo sed -i "s|DocumentRoot /var/www/html|DocumentRoot /var/www/html\n\tServerName $domain\n\tSSLEngine on\n\tSSLCertificateFile /etc/letsencrypt/live/$domain/fullchain.pem\n\tSSLCertificateKeyFile /etc/letsencrypt/live/$domain/privkey.pem|" /etc/apache2/sites-available/$domain.conf
  sudo a2ensite $domain
done

sudo systemctl reload apache2

# Check Docker container statuses
echo "Checking the status of Docker containers..."
sudo docker ps

echo "Installation and setup complete."
echo "You can access your applications at the following URLs:"
echo "WordPress 1: https://${DOMAIN1}"
echo "WordPress 2: https://${DOMAIN2}"
echo "Mailserver: https://${MAIL_DOMAIN}"
echo "Webmail: https://${WEBMAIL_DOMAIN}"
echo "Postfix Admin: https://${ADMIN_DOMAIN}"

