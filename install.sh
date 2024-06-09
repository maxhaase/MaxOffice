#!/bin/bash

# Load variables from vars.env
source vars.env

# Function to set debconf selections to avoid interactive prompts
set_debconf_selections() {
  echo "Configuring debconf selections to avoid interactive prompts..."
  echo "postfix postfix/mailname string $MAIL_DOMAIN" | sudo debconf-set-selections
  echo "postfix postfix/main_mailer_type select Internet Site" | sudo debconf-set-selections
  echo "debconf debconf/frontend select Noninteractive" | sudo debconf-set-selections
}

# Function to uninstall conflicting packages and install necessary ones
install_packages() {
  echo "Updating package lists and installing necessary packages..."
  sudo apt-get update -y
  sudo apt-get remove -y containerd docker docker-engine docker.io runc apache2 certbot python3-certbot-apache
  sudo apt-get remove -y containerd.io

  echo "Installing Apache, Docker, Docker Compose, Certbot, and Mailutils..."
  sudo apt-get install -y apache2 mailutils
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
  sudo curl -L "https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  sudo apt-get install -y certbot python3-certbot-apache
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
  echo "Packages installed."
}

# Unmask and enable Apache service
enable_apache_service() {
  echo "Unmasking and enabling Apache service..."
  sudo systemctl unmask apache2
  sudo systemctl enable apache2
  echo "Apache service enabled."
}

# Enable required Apache modules
enable_apache_modules() {
  echo "Enabling required Apache modules..."
  sudo a2enmod proxy
  sudo a2enmod proxy_http
  sudo a2enmod ssl
  echo "Apache modules enabled."
}

# Function to set up Let's Encrypt for a domain
setup_letsencrypt() {
  local DOMAIN=$1
  echo "Setting up Let's Encrypt for $DOMAIN..."
  if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
  else
    echo "Certificate for $DOMAIN already exists and is valid."
  fi
  echo "Let's Encrypt setup completed for $DOMAIN."
}

# Function to configure Apache for reverse proxy
setup_apache_proxy() {
  local DOMAIN=$1
  local PORT=$2
  echo "Setting up Apache reverse proxy for $DOMAIN on port $PORT..."
  local CONFIG_PATH="/etc/apache2/sites-available/$DOMAIN.conf"

  if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    cat > $CONFIG_PATH <<EOL
<VirtualHost *:80>
    ServerName $DOMAIN
    Redirect permanent / https://$DOMAIN/
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN
    ProxyPreserveHost On
    ProxyPass / http://localhost:$PORT/
    ProxyPassReverse / http://localhost:$PORT/

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem
    Include /etc/letsencrypt/options-ssl-apache.conf
</VirtualHost>
EOL
  else
    cat > $CONFIG_PATH <<EOL
<VirtualHost *:80>
    ServerName $DOMAIN
    ProxyPreserveHost On
    ProxyPass / http://localhost:$PORT/
    ProxyPassReverse / http://localhost:$PORT/
</VirtualHost>
EOL
  fi

  sudo a2ensite $DOMAIN.conf
  sudo systemctl reload apache2
  echo "Apache reverse proxy configured for $DOMAIN on port $PORT."
}

# Function to ensure Apache is running correctly
ensure_apache_running() {
  echo "Restarting Apache service..."
  sudo systemctl restart apache2
  if ! sudo systemctl is-active --quiet apache2; then
    echo "Apache setup failed. Please check the configuration."
    sudo journalctl -xeu apache2.service
    exit 1
  fi
  echo "Apache is running."
}

# Function to set up services with Docker Compose
setup_services() {
  echo "Setting up services for domains $DOMAIN1 and $DOMAIN2 using a shared database..."
  cat > docker-compose.yml <<EOL
version: '3.9'

services:
  db_shared:
    image: mysql:5.7
    container_name: db_shared
    environment:
      MYSQL_DATABASE: wordpress
      MYSQL_USER: $WORDPRESS_DB_USER
      MYSQL_PASSWORD: $WORDPRESS_DB_PASSWORD
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
    volumes:
      - db_data_shared:/var/lib/mysql
    networks:
      - wpnet

  wordpress_$DOMAIN1:
    image: wordpress:latest
    container_name: wordpress_$DOMAIN1
    environment:
      WORDPRESS_DB_HOST: db_shared
      WORDPRESS_DB_USER: $WORDPRESS_DB_USER
      WORDPRESS_DB_PASSWORD: $WORDPRESS_DB_PASSWORD
      WORDPRESS_DB_NAME: wordpress_$DOMAIN1
    volumes:
      - ./wordpress_$DOMAIN1:/var/www/html
    networks:
      - wpnet

  wordpress_$DOMAIN2:
    image: wordpress:latest
    container_name: wordpress_$DOMAIN2
    environment:
      WORDPRESS_DB_HOST: db_shared
      WORDPRESS_DB_USER: $WORDPRESS_DB_USER
      WORDPRESS_DB_PASSWORD: $WORDPRESS_DB_PASSWORD
      WORDPRESS_DB_NAME: wordpress_$DOMAIN2
    volumes:
      - ./wordpress_$DOMAIN2:/var/www/html
    networks:
      - wpnet

  mailserver:
    image: tvial/docker-mailserver:latest
    hostname: mail
    domainname: $MAIL_DOMAIN
    container_name: mailserver
    env_file: vars.env
    ports:
      - "2525:25"
      - "143:143"
      - "587:587"
      - "993:993"
      - "465:465"
      - "110:110"
      - "995:995"
      - "4190:4190"
    volumes:
      - ./maildata:/var/mail
      - ./mailstate:/var/mail-state
      - ./config:/tmp/docker-mailserver/
    environment:
      - ENABLE_SPAMASSASSIN=1
      - ENABLE_CLAMAV=1
      - ENABLE_FAIL2BAN=1
      - ENABLE_POSTGREY=1
      - ONE_DIR=1
      - DMS_DEBUG=0
    cap_add:
      - NET_ADMIN
      - SYS_PTRACE
    restart: unless-stopped
    networks:
      - mailnet

  webmail:
    image: roundcube/roundcubemail:latest
    container_name: webmail
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: $MAIL_DOMAIN
      ROUNDCUBEMAIL_SMTP_SERVER: tls://$MAIL_DOMAIN
      ROUNDCUBEMAIL_SMTP_PORT: 587
      ROUNDCUBEMAIL_DEFAULT_PORT: 143
    volumes:
      - ./webmail:/var/www/html
    ports:
      - "8080:80"
    networks:
      - mailnet

networks:
  wpnet:
  mailnet:
volumes:
  db_data_shared:
EOL

  echo "Starting Docker containers..."
  docker-compose up --force-recreate --remove-orphans --build --no-start
  docker-compose start
  echo "Docker containers started."
}

# Main setup function
main_setup() {
  set_debconf_selections
  install_packages
  enable_apache_service
  enable_apache_modules

  setup_letsencrypt $DOMAIN1
  setup_letsencrypt $DOMAIN2

  setup_apache_proxy $DOMAIN1 8000
  setup_apache_proxy $DOMAIN2 8001
  setup_apache_proxy $MAIL_DOMAIN 8080
  setup_apache_proxy $WEBMAIL_DOMAIN 8080

  ensure_apache_running
  setup_services

  echo "Setup completed. Access your services at:"
  echo "https://$DOMAIN1 for DOMAIN1"
  echo "https://$DOMAIN2 for DOMAIN2"
  echo "https://$MAIL_DOMAIN for mail services"
  echo "https://$WEBMAIL_DOMAIN for webmail"
}

# Execute the main setup
main_setup

