#!/bin/bash

# Load variables from vars.env
source vars.env

# Updating package lists and installing necessary packages
echo "Updating package lists and installing necessary packages..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl software-properties-common apt-transport-https certbot

# Remove Apache from the host if it's installed
echo "Removing Apache from the host..."
sudo apt-get purge -y apache2 apache2-utils apache2-bin apache2.2-common
sudo apt-get autoremove -y
sudo apt-get autoclean

# Install Docker
echo "Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker ${USER}

# Install Docker Compose
echo "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Configure firewall rules
echo "Configuring firewall rules..."
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 25
sudo ufw allow 143
sudo ufw allow 587
sudo ufw allow 993
sudo ufw enable
sudo ufw reload

# Decompress certificates
echo "Decompressing certificates..."
tar -xzvf certs.tar.gz -C /

# Create docker-compose.yml
echo "Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: '3.7'

services:
  db_shared:
    image: mysql:5.7
    volumes:
      - db_data:/var/lib/mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: wordpress
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}

  wordpress1:
    image: wordpress:latest
    ports:
      - "8000:80"
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: ${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
    depends_on:
      - db_shared

  wordpress2:
    image: wordpress:latest
    ports:
      - "8001:80"
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: ${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
    depends_on:
      - db_shared

  apache:
    image: httpd:2.4
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./apache-config:/usr/local/apache2/conf

  mailserver:
    image: mailserver/docker-mailserver:latest
    env_file: mail.env
    ports:
      - "25:25"
      - "143:143"
      - "587:587"
      - "993:993"
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
      - POSTMASTER_ADDRESS=${POSTMASTER_ADDRESS}
      - MAIL_USER=${MAIL_USER}

  webmail:
    image: roundcube/roundcubemail:latest
    ports:
      - "8080:80"
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
    depends_on:
      - db_shared

volumes:
  db_data:
  maildata:
  maillogs:
  mailstate:
  postfixadmin_data:
EOF

# Create mail.env
echo "Creating mail.env..."
cat <<EOF > mail.env
POSTMASTER_ADDRESS=${POSTMASTER_ADDRESS}
MAIL_USER=${MAIL_USER}
EOF

# Deploy Docker containers
echo "Deploying Docker containers..."
docker-compose up -d

# Configure Apache in the container
echo "Configuring Apache in the container..."
docker exec -it office_apache_1 bash -c "echo 'ServerName localhost' >> /usr/local/apache2/conf/httpd.conf"

# END OF PART 1

# Final message
echo "Installation and setup complete."
echo "You can access your applications at the following URLs:"
echo "WordPress 1: https://${DOMAIN1}"
echo "WordPress 2: https://${DOMAIN2}"
echo "Mailserver: https://mail.${DOMAIN1}"
echo "Webmail: https://webmail.${DOMAIN1}"
echo "Postfix Admin: https://admin.${DOMAIN1}"

