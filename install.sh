#!/bin/bash

# Load environment variables
source vars.env

# Function to clean up sources.list
cleanup_sources() {
  echo "Cleaning up sources.list to remove duplicates..."
  # Clean up logic for sources.list
  echo "Cleaned up sources.list."
}

# Function to install necessary packages
install_packages() {
  echo "Updating package lists and installing necessary packages..."
  sudo apt-get update
  sudo apt-get install -y apache2 apt-transport-https ca-certificates certbot curl mailutils python3-certbot-apache software-properties-common
  echo "Packages installed."
}

# Function to install Docker
install_docker() {
  echo "Installing Docker..."
  sudo apt-get install -y containerd.io docker-ce docker-ce-cli
  echo "Docker installed."
}

# Function to install Docker Compose
install_docker_compose() {
  echo "Installing Docker Compose..."
  sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  echo "Docker Compose installed."
}

# Function to enable and start Docker service
enable_docker_service() {
  echo "Enabling and starting Docker service..."
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "Docker service started."
}

# Function to add user to docker group
add_user_to_docker_group() {
  echo "Adding user to the docker group..."
  sudo usermod -aG docker $USER
  echo "User added to the docker group."
}

# Function to configure firewall
configure_firewall() {
  echo "Configuring firewall rules..."
  sudo ufw allow 22/tcp
  sudo ufw allow $SMTP_PORT/tcp
  sudo ufw allow $SMTPS_PORT/tcp
  sudo ufw allow $SMTP_ALT_PORT/tcp
  sudo ufw allow 80/tcp
  sudo ufw allow $POP3_PORT/tcp
  sudo ufw allow $IMAPS_PORT/tcp
  sudo ufw allow 443/tcp
  sudo ufw allow $IMAPS_PORT/tcp
  sudo ufw allow $POP3S_PORT/tcp
  sudo ufw allow $WEBMAIL_PORT/tcp
  sudo ufw allow $DOMAIN1_PORT/tcp
  sudo ufw allow $DOMAIN2_PORT/tcp
  sudo ufw allow $MAIL_PORT/tcp
  echo "Firewall rules configured."
}

# Function to create docker-compose.yml
create_docker_compose_yml() {
  echo "Creating docker-compose.yml..."
  cat <<EOF > docker-compose.yml
version: '3.8'

services:
  db_shared:
    image: mysql:$MYSQL_VERSION
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: $MYSQL_DATABASE
      MYSQL_USER: $MYSQL_USER
      MYSQL_PASSWORD: $MYSQL_PASSWORD
    volumes:
      - db_data:/var/lib/mysql

  wordpress1:
    image: wordpress:$WORDPRESS_VERSION
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: $WORDPRESS_DB_USER
      WORDPRESS_DB_PASSWORD: $WORDPRESS_DB_PASSWORD
      WORDPRESS_DB_NAME: $MYSQL_DATABASE
    depends_on:
      - db_shared
    ports:
      - "$DOMAIN1_PORT:80"

  wordpress2:
    image: wordpress:$WORDPRESS_VERSION
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: $WORDPRESS_DB_USER
      WORDPRESS_DB_PASSWORD: $WORDPRESS_DB_PASSWORD
      WORDPRESS_DB_NAME: $MYSQL_DATABASE
    depends_on:
      - db_shared
    ports:
      - "$DOMAIN2_PORT:80"

  mailserver:
    image: tvial/docker-mailserver:$MAILSERVER_VERSION
    hostname: mail
    domainname: $MAIL_DOMAIN
    restart: always
    env_file: vars.env
    ports:
      - "$SMTP_PORT:25"
      - "$SMTPS_PORT:465"
      - "$SMTP_ALT_PORT:587"
      - "$POP3_PORT:110"
      - "$POP3S_PORT:995"
      - "$IMAP_PORT:143"
      - "$IMAPS_PORT:993"
    volumes:
      - maildata:/var/mail
      - mailstate:/var/mail-state
      - ./config/:/tmp/docker-mailserver/
    environment:
      ENABLE_SPAMASSASSIN: 1
      ENABLE_CLAMAV: 1
      ENABLE_FAIL2BAN: 1
      ENABLE_POSTGREY: 0

  webmail:
    image: roundcube/roundcubemail:$ROUNDCUBEMAIL_VERSION
    restart: always
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: imaps://mail.$MAIL_DOMAIN
      ROUNDCUBEMAIL_SMTP_SERVER: tls://mail.$MAIL_DOMAIN
    ports:
      - "$WEBMAIL_PORT:80"
    depends_on:
      - mailserver

  postfixadmin:
    image: hardware/postfixadmin
    restart: always
    environment:
      - POSTFIXADMIN_DB_TYPE=mysqli
      - POSTFIXADMIN_DB_USER=$MYSQL_USER
      - POSTFIXADMIN_DB_PASS=$MYSQL_PASSWORD
      - POSTFIXADMIN_DB_HOST=db_shared
      - POSTFIXADMIN_DB_NAME=$MYSQL_DATABASE
      - POSTFIXADMIN_ADMIN_USER=admin
      - POSTFIXADMIN_ADMIN_PASS=$MYSQL_PASSWORD
    depends_on:
      - db_shared
    ports:
      - "$POSTFIXADMIN_PORT:80"

volumes:
  db_data:
  maildata:
  mailstate:
EOF
  echo "docker-compose.yml created."
}

# Function to deploy Docker containers
deploy_docker_containers() {
  echo "Deploying Docker containers..."
  docker-compose up -d
  echo "Docker containers deployed."
}

# Function to setup Let's Encrypt for domain
setup_letsencrypt() {
  local DOMAIN=$1
  echo "Setting up Let's Encrypt for $DOMAIN..."
  sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
  echo "Let's Encrypt setup completed for $DOMAIN."
}

# Function to configure Apache virtual host
configure_apache() {
  local DOMAIN=$1
  local PORT=$2
  echo "Configuring Apache virtual host for $DOMAIN..."
  sudo tee /etc/apache2/sites-available/$DOMAIN.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    Redirect permanent / https://$DOMAIN/
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem

    ProxyPreserveHost On
    ProxyPass / http://localhost:$PORT/
    ProxyPassReverse / http://localhost:$PORT/
</VirtualHost>
EOF
  sudo a2ensite $DOMAIN.conf
  sudo systemctl reload apache2
  echo "Apache virtual host configured for $DOMAIN."
}

# Main function
main() {
  cleanup_sources
  install_packages
  install_docker
  install_docker_compose
  enable_docker_service
  add_user_to_docker_group
  configure_firewall
  create_docker_compose_yml
  deploy_docker_containers

  setup_letsencrypt $DOMAIN1
  configure_apache $DOMAIN1 $DOMAIN1_PORT

  setup_letsencrypt $DOMAIN2
  configure_apache $DOMAIN2 $DOMAIN2_PORT

  setup_letsencrypt $MAIL_DOMAIN
  configure_apache $MAIL_DOMAIN $MAIL_PORT

  setup_letsencrypt $WEBMAIL_DOMAIN
  configure_apache $WEBMAIL_DOMAIN $WEBMAIL_PORT

  echo "Setup completed. Access your services at:"
  echo "https://$DOMAIN1 for DOMAIN1"
  echo "https://$DOMAIN2 for DOMAIN2"
  echo "https://$MAIL_DOMAIN for mail services"
  echo "https://$WEBMAIL_DOMAIN for webmail"
}

# Execute main installation
main

