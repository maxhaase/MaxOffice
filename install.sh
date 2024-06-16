#!/bin/bash

# Redirect all output to a log file
exec > >(tee -i install.log)
exec 2>&1

# Load environment variables from vars.env
source vars.env

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Function to install dependencies
install_dependencies() {
    echo "Installing dependencies..."
    sudo apt-get update || handle_error "Failed to update package lists"
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common ufw || handle_error "Failed to install dependencies"
}

# Function to install kubectl
install_kubectl() {
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || handle_error "Failed to download kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || handle_error "Failed to install kubectl"
    rm kubectl
}

# Function to install Minikube
install_minikube() {
    echo "Installing Minikube..."
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 || handle_error "Failed to download Minikube"
    sudo install minikube-linux-amd64 /usr/local/bin/minikube || handle_error "Failed to install Minikube"
    rm minikube-linux-amd64
}

# Function to start Minikube without root privileges
start_minikube() {
    echo "Starting Minikube..."
    minikube delete || true
    sudo -u $USER minikube start --driver=docker || handle_error "Failed to start Minikube"
}

# Function to check Kubernetes API server availability
check_k8s_api() {
    echo "Checking Kubernetes API server availability..."
    for i in {1..12}; do
        kubectl cluster-info &>/dev/null && break || sleep 5
        if [ $i -eq 12 ]; then
            handle_error "Kubernetes API server is not available"
        fi
    done
    echo "Kubernetes API server is ready."
}

# Function to setup Kubernetes namespace
setup_namespace() {
    echo "Setting up Kubernetes namespace..."
    kubectl create namespace $KUBE_NAMESPACE || handle_error "Failed to create namespace"
    echo "Creating service account and role binding..."
    kubectl apply -f - <<EOF || handle_error "Failed to create service account and role binding"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: $KUBE_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: $KUBE_NAMESPACE
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: $KUBE_NAMESPACE
subjects:
- kind: ServiceAccount
  name: default
  namespace: $KUBE_NAMESPACE
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
}

# Function to deploy MySQL
deploy_mysql() {
    echo "Deploying MySQL..."
    kubectl apply -f - <<EOF || handle_error "Failed to deploy MySQL"
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
---
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
---
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

# Function to check MySQL connection
check_db_connection() {
    echo "Checking database connection..."
    for i in {1..12}; do
        kubectl run mysql-client --image=mysql:5.7 -i --rm --restart=Never --namespace=$KUBE_NAMESPACE --command -- \
        mysql -h mysql-service -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" && break || sleep 5
        if [ $i -eq 12 ]; then
            handle_error "Unable to connect to MySQL database."
        fi
    done
    echo "Database connection successful."
}

# Function to deploy WordPress for DOMAIN1
deploy_wordpress1() {
    echo "Deploying WordPress for DOMAIN1..."
    kubectl apply -f - <<EOF || handle_error "Failed to deploy WordPress for DOMAIN1"
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
}

# Function to deploy WordPress for DOMAIN2
deploy_wordpress2() {
    echo "Deploying WordPress for DOMAIN2..."
    kubectl apply -f - <<EOF || handle_error "Failed to deploy WordPress for DOMAIN2"
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
}

# Function to deploy Roundcube
deploy_roundcube() {
    echo "Deploying Roundcube..."
    kubectl apply -f - <<EOF || handle_error "Failed to deploy Roundcube"
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
        - name: DB_HOST
          value: mysql-service
        - name: DB_USER
          value: $ROUNDCUBEMAIL_DB_USER
        - name: DB_PASSWORD
          value: $ROUNDCUBEMAIL_DB_PASSWORD
        - name: DB_NAME
          value: $ROUNDCUBEMAIL_DB
        ports:
        - containerPort: 80
EOF
}

# Function to deploy Mailserver
deploy_mailserver() {
    echo "Deploying Mailserver..."
    kubectl apply -f - <<EOF || handle_error "Failed to deploy Mailserver"
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
        image: mailserver/mailserver:latest
        env:
        - name: DB_HOST
          value: mysql-service
        - name: DB_USER
          value: $MAILSERVER_DB_USER
        - name: DB_PASSWORD
          value: $MAILSERVER_DB_PASSWORD
        - name: DB_NAME
          value: $MAILSERVER_DB
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
---
apiVersion: v1
kind: Service
metadata:
  name: $KUBE_SERVICE_NAME_MAILSERVER
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: $SMTP_PORT
    targetPort: smtp
    name: smtp
  - port: $SMTPS_PORT
    targetPort: smtps
    name: smtps
  - port: $SMTP_ALT_PORT
    targetPort: smtp-alt
    name: smtp-alt
  - port: $POP3_PORT
    targetPort: pop3
    name: pop3
  - port: $POP3S_PORT
    targetPort: pop3s
    name: pop3s
  - port: $IMAP_PORT
    targetPort: imap
    name: imap
  - port: $IMAPS_PORT
    targetPort: imaps
    name: imaps
  selector:
    app: mailserver
EOF
}

# Function to deploy PostfixAdmin
deploy_postfixadmin() {
    echo "Deploying PostfixAdmin..."
    kubectl apply -f - <<EOF || handle_error "Failed to deploy PostfixAdmin"
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
        - name: DB_HOST
          value: mysql-service
        - name: DB_USER
          value: $POSTFIXADMIN_DB_USER
        - name: DB_PASSWORD
          value: $POSTFIXADMIN_DB_PASSWORD
        - name: DB_NAME
          value: $POSTFIXADMIN_DB
        ports:
        - containerPort: 80
EOF
}

# Function to verify services
verify_services() {
    echo "Verifying services..."

    for deployment in mysql wordpress1 wordpress2 roundcube mailserver postfixadmin; do
        kubectl rollout status deployment/$deployment --namespace=$KUBE_NAMESPACE || handle_error "Deployment $deployment failed to roll out"
    done

    echo "All deployments successfully rolled out."
}

# Function to test webmail access
test_webmail_access() {
    echo "Testing webmail access..."
    curl -I https://$WEBMAIL_DOMAIN || handle_error "Unable to access webmail at https://$WEBMAIL_DOMAIN"
    echo "Webmail access verified at https://$WEBMAIL_DOMAIN"
}

# Main script execution
install_dependencies
install_kubectl
install_minikube
start_minikube
check_k8s_api
setup_namespace
deploy_mysql

# Wait for MySQL to be ready before proceeding
sleep 30
check_db_connection

deploy_wordpress1
deploy_wordpress2
deploy_roundcube
deploy_mailserver
deploy_postfixadmin

verify_services
test_webmail_access

echo "Installation and setup complete."

