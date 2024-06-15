#!/bin/bash

# Redirect all output to a log file
exec > >(tee -i install.log)
exec 2>&1

# Load environment variables from vars.env
source vars.env

# Function to install dependencies
install_dependencies() {
    echo "Installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl software-properties-common ufw apt-transport-https conntrack
}

# Function to install Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        sudo usermod -aG docker $USER
        newgrp docker
    else
        echo "Docker is already installed."
    fi
}

# Function to install kubectl
install_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    else
        echo "kubectl is already installed."
    fi
}

# Function to install Minikube
install_minikube() {
    if ! command -v minikube &> /dev/null; then
        echo "Installing Minikube..."
        curl -LO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"
        chmod +x minikube-linux-amd64
        sudo mv minikube-linux-amd64 /usr/local/bin/minikube
    else
        echo "Minikube is already installed."
    fi
}

# Function to start Minikube
start_minikube() {
    echo "Starting Minikube..."
    sudo sysctl fs.protected_regular=0
    minikube start --driver=docker --force --wait=false
    sleep 60
    kubectl cluster-info
    if [ $? -ne 0 ]; then
        echo "Error: Minikube failed to start correctly."
        exit 1
    fi
}

# Function to set up Kubernetes namespace
setup_namespace() {
    echo "Setting up Kubernetes namespace..."
    kubectl create namespace $KUBE_NAMESPACE || echo "Namespace already exists"
}

# Function to deploy MySQL
deploy_mysql() {
    echo "Deploying MySQL..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: $KUBE_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:5.7
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: $MYSQL_ROOT_PASSWORD
        - name: MYSQL_DATABASE
          value: $MYSQL_DATABASE
        - name: MYSQL_USER
          value: $MYSQL_USER
        - name: MYSQL_PASSWORD
          value: $MYSQL_PASSWORD
        ports:
        - containerPort: 3306
        volumeMounts:
        - mountPath: /var/lib/mysql
          name: mysql-persistent-storage
      volumes:
      - name: mysql-persistent-storage
        persistentVolumeClaim:
          claimName: mysql-pvc
EOF

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: mysql-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 3306
    targetPort: 3306
  selector:
    app: mysql
EOF
}

# Function to wait for MySQL to be ready
wait_for_mysql() {
    echo "Waiting for MySQL to be ready..."
    kubectl wait --namespace $KUBE_NAMESPACE --for=condition=ready pod -l app=mysql --timeout=300s
}

# Function to check MySQL database connection
check_db_connection() {
    echo "Checking database connection..."
    kubectl run mysql-client --rm --tty -i --restart='Never' --namespace $KUBE_NAMESPACE --image=mysql:5.7 --command -- mysql -h mysql-service -u $MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;"
    if [ $? -ne 0 ]; then
        echo "Error: Unable to connect to MySQL database."
        exit 1
    fi
}

# Function to deploy WordPress for DOMAIN1
deploy_wordpress1() {
    echo "Deploying WordPress for DOMAIN1..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress1
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: wordpress1
  template:
    metadata:
      labels:
        app: wordpress1
    spec:
      containers:
      - name: wordpress
        image: wordpress:latest
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql-service
        - name: WORDPRESS_DB_USER
          value: $WORDPRESS_DB_USER_DOMAIN1
        - name: WORDPRESS_DB_PASSWORD
          value: $WORDPRESS_DB_PASSWORD_DOMAIN1
        - name: WORDPRESS_DB_NAME
          value: $WORDPRESS_DB_DOMAIN1
        ports:
        - containerPort: 80
EOF

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: wordpress1-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: wordpress1
EOF
}

# Function to deploy WordPress for DOMAIN2
deploy_wordpress2() {
    echo "Deploying WordPress for DOMAIN2..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress2
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: wordpress2
  template:
    metadata:
      labels:
        app: wordpress2
    spec:
      containers:
      - name: wordpress
        image: wordpress:latest
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql-service
        - name: WORDPRESS_DB_USER
          value: $WORDPRESS_DB_USER_DOMAIN2
        - name: WORDPRESS_DB_PASSWORD
          value: $WORDPRESS_DB_PASSWORD_DOMAIN2
        - name: WORDPRESS_DB_NAME
          value: $WORDPRESS_DB_DOMAIN2
        ports:
        - containerPort: 80
EOF

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: wordpress2-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: wordpress2
EOF
}

# Function to deploy Roundcube
deploy_roundcube() {
    echo "Deploying Roundcube..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: roundcube
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: roundcube
  template:
    metadata:
      labels:
        app: roundcube
    spec:
      containers:
      - name: roundcube
        image: roundcube/roundcubemail:latest
        env:
        - name: ROUNDCUBEMAIL_DEFAULT_HOST
          value: ssl://$MAIL_DOMAIN
        - name: ROUNDCUBEMAIL_SMTP_SERVER
          value: tls://$MAIL_DOMAIN
        - name: MYSQL_ROOT_PASSWORD
          value: $MYSQL_ROOT_PASSWORD
        - name: MYSQL_DATABASE
          value: $ROUNDCUBEMAIL_DB
        - name: MYSQL_USER
          value: $ROUNDCUBEMAIL_DB_USER
        - name: MYSQL_PASSWORD
          value: $ROUNDCUBEMAIL_DB_PASSWORD
        ports:
        - containerPort: 80
EOF

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: roundcube-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: roundcube
EOF
}

# Function to deploy Mailserver
deploy_mailserver() {
    echo "Deploying Mailserver..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailserver
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: mailserver
  template:
    metadata:
      labels:
        app: mailserver
    spec:
      containers:
      - name: mailserver
        image: mailserver/docker-mailserver:latest
        env:
        - name: MAILSERVER_HOST
          value: $MAIL_DOMAIN
        - name: MAILSERVER_SSL_TYPE
          value: letsencrypt
        - name: LETSENCRYPT_EMAIL
          value: $CERT_MANAGER_EMAIL
        ports:
        - containerPort: $SMTP_PORT
          name: smtp
        - containerPort: $SMTPS_PORT
          name: smtps
        - containerPort: $SMTP_ALT_PORT
          name: smtp-alt
        - containerPort: $POP3_PORT
          name: pop3
        - containerPort: $POP3S_PORT
          name: pop3s
        - containerPort: $IMAP_PORT
          name: imap
        - containerPort: $IMAPS_PORT
          name: imaps
      volumes:
      - name: mail-persistent-storage
        persistentVolumeClaim:
          claimName: $KUBE_PVC_NAME_MAIL
EOF

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $KUBE_SERVICE_NAME_MAILSERVER
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: $SMTP_PORT
    targetPort: smtp
  - port: $SMTPS_PORT
    targetPort: smtps
  - port: $SMTP_ALT_PORT
    targetPort: smtp-alt
  - port: $POP3_PORT
    targetPort: pop3
  - port: $POP3S_PORT
    targetPort: pop3s
  - port: $IMAP_PORT
    targetPort: imap
  - port: $IMAPS_PORT
    targetPort: imaps
  selector:
    app: mailserver
EOF
}

# Function to deploy PostfixAdmin
deploy_postfixadmin() {
    echo "Deploying PostfixAdmin..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postfixadmin
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: postfixadmin
  template:
    metadata:
      labels:
        app: postfixadmin
    spec:
      containers:
      - name: postfixadmin
        image: postfixadmin/postfixadmin:latest
        env:
        - name: POSTFIXADMIN_DB_HOST
          value: mysql-service
        - name: POSTFIXADMIN_DB_USER
          value: $POSTFIXADMIN_DB_USER
        - name: POSTFIXADMIN_DB_PASSWORD
          value: $POSTFIXADMIN_DB_PASSWORD
        - name: POSTFIXADMIN_DB_NAME
          value: $POSTFIXADMIN_DB
        ports:
        - containerPort: 80
EOF

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: postfixadmin-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: postfixadmin
EOF
}

# Function to verify the deployment
verify_deployment() {
    echo "Verifying services..."
    kubectl rollout status deployment/mysql -n $KUBE_NAMESPACE
    kubectl rollout status deployment/wordpress1 -n $KUBE_NAMESPACE
    kubectl rollout status deployment/wordpress2 -n $KUBE_NAMESPACE
    kubectl rollout status deployment/roundcube -n $KUBE_NAMESPACE
    kubectl rollout status deployment/mailserver -n $KUBE_NAMESPACE
    kubectl rollout status deployment/postfixadmin -n $KUBE_NAMESPACE
}

# Function to cleanup Kubernetes resources
cleanup_kubernetes() {
    echo "Cleaning up Kubernetes resources..."
    kubectl delete namespace $KUBE_NAMESPACE --force --grace-period=0
}

# Function to run the script
run() {
    install_dependencies
    install_docker
    install_kubectl
    install_minikube
    start_minikube
    setup_namespace
    deploy_mysql
    wait_for_mysql
    check_db_connection
    deploy_wordpress1
    deploy_wordpress2
    deploy_roundcube
    deploy_mailserver
    deploy_postfixadmin
    verify_deployment

    echo "All services deployed successfully."
    echo "Access the services at the following URLs:"
    echo "DOMAIN1: http://$DOMAIN1"
    echo "DOMAIN2: http://$DOMAIN2"
    echo "Admin: http://$ADMIN_DOMAIN"
    echo "Webmail: http://$WEBMAIL_DOMAIN"
    echo "Mailserver: http://$MAIL_DOMAIN"
}

# Main
run

