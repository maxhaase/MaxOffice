#!/bin/bash

# Load variables from vars.env
source vars.env

# Function to clean up sources.list
clean_sources() {
  echo "Cleaning up sources.list to remove duplicates..."
  sudo sh -c 'grep -v "^#" /etc/apt/sources.list | sort | uniq > /etc/apt/sources.list.new'
  sudo mv /etc/apt/sources.list.new /etc/apt/sources.list
  echo "Cleaned up sources.list."
}

# Function to install required packages
install_packages() {
  echo "Updating package lists and installing necessary packages..."
  sudo apt-get update -y
  sudo apt-get install -y apache2 apt-transport-https ca-certificates curl software-properties-common certbot python3-certbot-apache mailutils
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
  sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  echo "Docker Compose installed."
}

# Function to start Docker service
start_docker_service() {
  echo "Enabling and starting Docker service..."
  sudo systemctl enable docker
  sudo systemctl start docker
  echo "Docker service started."
}

# Function to add user to Docker group
add_user_to_docker_group() {
  echo "Adding user to the docker group..."
  sudo usermod -aG docker $USER
  echo "User added to the docker group."
}

# Function to configure firewall rules
configure_firewall() {
  echo "Configuring firewall rules..."
  sudo ufw allow 25
  sudo ufw allow 465
  sudo ufw allow 587
  sudo ufw allow 110
  sudo ufw allow 995
  sudo ufw allow 143
  sudo ufw allow 993
  sudo ufw allow 4190
  sudo ufw allow 80
  sudo ufw allow 443
  echo "Firewall rules configured."
}

# Function to create docker-compose.yml
create_docker_compose() {
  echo "Creating docker-compose.yml..."
  cat <<EOF > docker-compose.yml
version: '3.8'

services:
  db_shared:
    image: mysql:\${MYSQL_VERSION}
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql

  wordpress1:
    image: wordpress:\${WORDPRESS_VERSION}
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: \${MYSQL_DATABASE}
    depends_on:
      - db_shared
    ports:
      - "\${DOMAIN1_PORT}:80"

  wordpress2:
    image: wordpress:\${WORDPRESS_VERSION}
    restart: always
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_USER: \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
      WORDPRESS_DB_NAME: \${MYSQL_DATABASE}
    depends_on:
      - db_shared
    ports:
      - "\${DOMAIN2_PORT}:80"

  mailserver:
    image: tvial/docker-mailserver:\${MAILSERVER_VERSION}
    hostname: mail
    domainname: \${MAIL_DOMAIN}
    restart: always
    env_file: vars.env
    ports:
      - "\${SMTP_PORT}:25"
      - "\${SMTPS_PORT}:465"
      - "\${SMTP_ALT_PORT}:587"
      - "\${POP3_PORT}:110"
      - "\${POP3S_PORT}:995"
      - "\${IMAP_PORT}:143"
      - "\${IMAPS_PORT}:993"
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
    image: roundcube/roundcubemail:\${ROUNDCUBEMAIL_VERSION}
    restart: always
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: imaps://\${MAIL_DOMAIN}
      ROUNDCUBEMAIL_SMTP_SERVER: tls://\${MAIL_DOMAIN}
    ports:
      - "\${WEBMAIL_PORT}:80"
    depends_on:
      - mailserver

  postfixadmin:
    image: hardware/postfixadmin
    restart: always
    environment:
      POSTFIXADMIN_DB_TYPE: mysqli
      POSTFIXADMIN_DB_USER: \${MYSQL_USER}
      POSTFIXADMIN_DB_PASS: \${MYSQL_PASSWORD}
      POSTFIXADMIN_DB_HOST: db_shared
      POSTFIXADMIN_DB_NAME: \${MYSQL_DATABASE}
      POSTFIXADMIN_ADMIN_USER: \${POSTFIXADMIN_ADMIN_USER}
      POSTFIXADMIN_ADMIN_PASS: \${POSTFIXADMIN_ADMIN_PASS}
    depends_on:
      - db_shared
    ports:
      - "8081:80"

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
  sudo docker-compose up -d
  echo "Docker containers deployed."
}

# Function to set up Let's Encrypt
setup_letsencrypt() {
  domain=$1
  echo "Setting up Let's Encrypt for $domain..."
  sudo certbot certonly --standalone --non-interactive --agree-tos -m admin@$domain -d $domain
  echo "Let's Encrypt setup completed for $domain."
}

# Function to configure Apache
configure_apache() {
  domain=$1
  port=$2
  echo "Configuring Apache virtual host for $domain..."
  sudo sh -c "cat <<EOF > /etc/apache2/sites-available/$domain.conf
<VirtualHost *:80>
    ServerName $domain
    Redirect permanent / https://$domain/
</VirtualHost>

<VirtualHost *:443>
    ServerName $domain

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$domain/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$domain/privkey.pem

    ProxyPreserveHost On
    ProxyPass / http://localhost:$port/
    ProxyPassReverse / http://localhost:$port/
</VirtualHost>
EOF"
  sudo a2ensite $domain.conf
  sudo systemctl reload apache2
  echo "Apache virtual host configured for $domain."
}

# Main installation
clean_sources
install_packages
install_docker
install_docker_compose
start_docker_service
add_user_to_docker_group
configure_firewall
create_docker_compose
deploy_docker_containers

# Setting up Let's Encrypt and Apache configurations
setup_letsencrypt $DOMAIN1
configure_apache $DOMAIN1 $DOMAIN1_PORT
setup_letsencrypt $DOMAIN2
configure_apache $DOMAIN2 $DOMAIN2_PORT
setup_letsencrypt $MAIL_DOMAIN
configure_apache $MAIL_DOMAIN $WEBMAIL_PORT

echo "Setup completed. Access your services at:"
echo "https://$DOMAIN1 for DOMAIN1"
echo "https://$DOMAIN2 for DOMAIN2"
echo "https://$MAIL_DOMAIN for mail services"
echo "https://$WEBMAIL_DOMAIN for webmail"

