#!/bin/bash

# Load variables from vars.env
source vars.env

# Function to install necessary packages
install_packages() {
  echo "Updating package lists and installing necessary packages..."
  sudo apt-get update
  sudo apt-get install -y docker.io docker-compose nginx certbot python3-certbot-nginx mailutils
  echo "Packages installed."
}

# Enable and start Docker service
start_docker() {
  echo "Enabling and starting Docker service..."
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "Docker service started."
}

# Function to set up Let's Encrypt for a domain
setup_letsencrypt() {
  local DOMAIN=$1
  echo "Setting up Let's Encrypt for $DOMAIN..."
  sudo certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
  echo "Let's Encrypt setup completed for $DOMAIN."
}

# Function to configure Nginx for SSL
setup_nginx_ssl() {
  local DOMAIN=$1
  echo "Setting up Nginx for SSL for $DOMAIN..."
  cat > /etc/nginx/sites-available/$DOMAIN <<EOL
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}

server {
    if (\$host = www.$DOMAIN) {
        return 301 https://$DOMAIN\$request_uri;
    } # managed by Certbot

    if (\$host = $DOMAIN) {
        return 301 https://$DOMAIN\$request_uri;
    } # managed by Certbot

    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    return 404; # managed by Certbot
}
EOL

  ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
  sudo systemctl reload nginx
  echo "Nginx configured for SSL for $DOMAIN."
}

# Function to set up WordPress with Let's Encrypt
setup_wordpress() {
  local DOMAIN=$1
  echo "Setting up WordPress for $DOMAIN..."

  # Create docker-compose file
  cat > docker-compose.yml <<EOL
version: '$DOCKER_COMPOSE_VERSION'

services:
  wordpress_$DOMAIN:
    image: wordpress:$WORDPRESS_VERSION
    container_name: wordpress_$DOMAIN
    environment:
      WORDPRESS_DB_HOST: db_$DOMAIN
      WORDPRESS_DB_USER: $WORDPRESS_DB_USER
      WORDPRESS_DB_PASSWORD: $WORDPRESS_DB_PASSWORD
      WORDPRESS_DB_NAME: wordpress_$DOMAIN
    volumes:
      - ./wordpress_$DOMAIN:/var/www/html
    ports:
      - "8000:80"
    networks:
      - wpnet_$DOMAIN

  db_$DOMAIN:
    image: mysql:$MYSQL_VERSION
    container_name: db_$DOMAIN
    environment:
      MYSQL_DATABASE: wordpress_$DOMAIN
      MYSQL_USER: $WORDPRESS_DB_USER
      MYSQL_PASSWORD: $WORDPRESS_DB_PASSWORD
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
    volumes:
      - db_data_$DOMAIN:/var/lib/mysql
    networks:
      - wpnet_$DOMAIN

  mailserver:
    image: tvial/docker-mailserver:$MAILSERVER_VERSION
    hostname: mail
    domainname: $MAIL_DOMAIN
    container_name: mailserver
    env_file: vars.env
    ports:
      - "25:25"
      - "143:143"
      - "587:587"
      - "993:993"
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
    image: roundcube/roundcubemail:$ROUNDCUBEMAIL_VERSION
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
  wpnet_$DOMAIN:
  mailnet:
volumes:
  db_data_$DOMAIN:
EOL

  # Start the containers with verbose output
  docker-compose up --force-recreate --remove-orphans --build --no-cache --verbose

  # Set up Let's Encrypt
  setup_letsencrypt $DOMAIN

  # Set up Nginx for SSL
  setup_nginx_ssl $DOMAIN

  echo "WordPress setup completed for $DOMAIN."
}

# Main setup function
main_setup() {
  install_packages
  start_docker

  # Provision the server for DOMAIN1
  setup_wordpress $DOMAIN1

  # Provision the server for DOMAIN2 if defined
  if [ -n "$DOMAIN2" ]; then
    setup_wordpress $DOMAIN2
  fi

  # Display access information
  echo "Setup completed. Access your services at:"
  echo "https://$DOMAIN1 for DOMAIN1"
  if [ -n "$DOMAIN2" ]; then
    echo "https://$DOMAIN2 for DOMAIN2"
  fi
  echo "https://$MAIL_DOMAIN for mail services"
  echo "https://$WEBMAIL_DOMAIN for webmail"
}

# Execute the main setup
main_setup

