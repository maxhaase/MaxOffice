# Use Ubuntu 22.04 as the base image
FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Copy environment variables file
COPY vars.env /tmp/vars.env

# Source environment variables
RUN set -o allexport; source /tmp/vars.env; set +o allexport

# Install necessary packages
RUN apt-get update -y && \
    apt-get install -y \
    postfix \
    dovecot-core \
    dovecot-mysql \
    mariadb-server \
    mariadb-client \
    certbot \
    apache2 \
    php \
    php-fpm \
    php-mysql \
    php-intl \
    php-mbstring \
    php-xml \
    php-json \
    php-common \
    php-curl \
    php-zip \
    wget \
    unzip \
    openssl \
    bash && \
    apt-get clean

# Copy provisioning script
COPY provision_server.sh /usr/local/bin/provision_server.sh

# Make the script executable
RUN chmod +x /usr/local/bin/provision_server.sh

# Expose ports for HTTP, HTTPS, and mail protocols
EXPOSE 80 443 25 465 587 110 995 143 993

# Start services and run provisioning script
CMD /usr/local/bin/provision_server.sh
