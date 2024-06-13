#!/bin/bash

# Load environment variables from vars.env
if [ ! -f vars.env ]; then
  echo "vars.env file not found!"
  exit 1
fi

source vars.env

# Ensure Docker is installed
if ! [ -x "$(command -v docker)" ]; then
  echo "Installing Docker..."
  sudo apt-get update
  sudo apt-get install -y docker.io
fi

# Ensure Docker Compose is installed
if ! [ -x "$(command -v docker-compose)" ]; then
  echo "Installing Docker Compose..."
  sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

# Setup necessary directories and permissions
echo "Setting up directories and permissions..."
sudo mkdir -p /var/log/apache2
sudo chmod -R 755 /var/log/apache2

# Cleanup old containers and images
echo "Cleaning up old Docker containers and images..."
docker-compose down
docker system prune -af

# Create docker-compose.yml dynamically
echo "Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  db_shared:
    image: mysql:\${MYSQL_VERSION}
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - \${VOLUME_DB_DATA}:/var/lib/mysql

  mailserver:
    image: mailserver/docker-mailserver:\${MAILSERVER_VERSION}
    environment:
      - MAILSERVER_HOSTNAME=\${MAIL_DOMAIN}
      - MAILSERVER_DOMAIN=\${MAIL_DOMAIN}
    ports:
      - "\${SMTP_PORT}:25"
      - "\${SMTPS_PORT}:465"
      - "\${SMTP_ALT_PORT}:587"
      - "\${POP3_PORT}:110"
      - "\${POP3S_PORT}:995"
      - "\${IMAP_PORT}:143"
      - "\${IMAPS_PORT}:993"
    volumes:
      - \${VOLUME_MAILDATA}:/var/mail
      - \${VOLUME_MAILLOGS}:/var/log/mail
      - \${VOLUME_MAILSTATE}:/var/mail-state

  webmail:
    image: roundcube/roundcubemail:\${ROUNDCUBEMAIL_VERSION}
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: "db_shared"
      ROUNDCUBEMAIL_SMTP_SERVER: "smtp://mailserver"
      ROUNDCUBEMAIL_DEFAULT_PORT: 3306
      ROUNDCUBEMAIL_DB_USER: \${MYSQL_USER}
      ROUNDCUBEMAIL_DB_PASS: \${MYSQL_PASSWORD}
      ROUNDCUBEMAIL_DB_NAME: \${MYSQL_DATABASE}
    ports:
      - "\${WEBMAIL_PORT}:80"
    depends_on:
      - db_shared
      - mailserver

  wordpress1:
    image: wordpress:\${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: \${MYSQL_DATABASE}
      WORDPRESS_DB_USER: \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
    ports:
      - "\${DOMAIN1_PORT}:80"
    volumes:
      - wordpress1_data:/var/www/html
    depends_on:
      - db_shared

  wordpress2:
    image: wordpress:\${WORDPRESS_VERSION}
    environment:
      WORDPRESS_DB_HOST: db_shared:3306
      WORDPRESS_DB_NAME: \${MYSQL_DATABASE}
      WORDPRESS_DB_USER: \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
    ports:
      - "\${DOMAIN2_PORT}:80"
    volumes:
      - wordpress2_data:/var/www/html
    depends_on:
      - db_shared

  apache:
    image: httpd:2.4
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/log/apache2:/usr/local/apache2/logs

  postfixadmin:
    image: hardware/postfixadmin:latest
    environment:
      POSTFIXADMIN_SETUP_PASSWORD: \${POSTFIXADMIN_ADMIN_PASS}
      POSTFIXADMIN_DB_HOST: db_shared
      POSTFIXADMIN_DB_NAME: \${MYSQL_DATABASE}
      POSTFIXADMIN_DB_USER: \${MYSQL_USER}
      POSTFIXADMIN_DB_PASSWORD: \${MYSQL_PASSWORD}
    ports:
      - "8080:80"
    volumes:
      - \${VOLUME_POSTFIXADMIN_DATA}:/data
    depends_on:
      - db_shared

volumes:
  db_data:
  maildata:
  maillogs:
  mailstate:
  wordpress1_data:
  wordpress2_data:
  postfixadmin_data:
EOF

# Start the services
echo "Starting Docker services..."
docker-compose up -d --build

# Check the status of services
echo "Checking the status of services..."
docker-compose ps

# Display logs for debugging if necessary
echo "Displaying logs..."
docker-compose logs

echo "Installation and setup complete."
echo "You can access your applications at the following URLs:"
echo "WordPress 1: http://$DOMAIN1"
echo "WordPress 2: http://$DOMAIN2"
echo "Mailserver: http://$MAIL_DOMAIN"
echo "Webmail: http://$WEBMAIL_DOMAIN"
echo "Postfix Admin: http://$ADMIN_DOMAIN"
