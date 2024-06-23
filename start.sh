#!/bin/bash

# Load environment variables from vars.env
if [ ! -f vars.env ]; then
    echo "Error: vars.env file not found!"
    exit 1
fi

source vars.env

# Function to log messages
log() {
    local level="$1"
    shift
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Redirect all output to a log file
exec > >(tee -i install.log)
exec 2>&1

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Function to retry a command up to a specified number of times
retry_command() {
    local retries=$1
    shift
    local command="$@"
    local attempt=0

    until $command; do
        attempt=$((attempt+1))
        if [ $attempt -ge $retries ]; then
            handle_error "Command failed after $retries attempts: $command"
        fi
        echo "Retrying command ($attempt/$retries): $command"
        sleep 2
    done
}

# Function to clean environment
clean_environment() {
    log "INFO" "Cleaning environment..."
    minikube delete || true
    sudo rm -rf /etc/docker/certs.d /etc/docker/key.json /var/lib/minikube /root/.minikube /root/.kube || true
    sudo rm -rf /home/$USER/.minikube /home/$USER/.kube || true
    sudo ufw disable || true
}

# Function to install dependencies
install_dependencies() {
    log "INFO" "Installing dependencies..."
    sudo apt-get update || handle_error "Failed to update package list"
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common ufw wget git build-essential || handle_error "Failed to install required packages"
}

# Function to install Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "INFO" "Installing Docker..."
        sudo apt-get install -y docker.io || handle_error "Failed to install Docker"
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
    else
        log "INFO" "Docker is already installed"
    fi
}

# Function to install kubectl
install_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log "INFO" "Installing kubectl..."
        retry_command 3 curl -LO "$KUBECTL_URL"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || handle_error "Failed to install kubectl"
        rm kubectl
    else
        log "INFO" "kubectl is already installed"
    fi
}

# Function to install Minikube
install_minikube() {
    if ! command -v minikube &> /dev/null; then
        log "INFO" "Installing Minikube..."
        retry_command 3 curl -Lo minikube-linux-amd64 "$MINIKUBE_URL"
        sudo install minikube-linux-amd64 /usr/local/bin/minikube || handle_error "Failed to install Minikube"
        rm minikube-linux-amd64
    else
        log "INFO" "Minikube is already installed"
    fi
}

# Function to install crictl
install_crictl() {
    if ! command -v crictl &> /dev/null; then
        log "INFO" "Installing crictl..."
        retry_command 3 curl -Lo crictl.tar.gz "$CRICTL_URL"
        sudo tar zxvf crictl.tar.gz -C /usr/local/bin || handle_error "Failed to install crictl"
        rm crictl.tar.gz
    else
        log "INFO" "crictl is already installed"
    fi
}

# Function to install cri-dockerd
install_cri_dockerd() {
    if ! command -v cri-dockerd &> /dev/null; then
        log "INFO" "Installing cri-dockerd..."
        retry_command 3 git clone https://github.com/Mirantis/cri-dockerd.git
        cd cri-dockerd || handle_error "Failed to change directory to cri-dockerd"
        mkdir -p bin
        go get && go build -o bin/cri-dockerd || handle_error "Failed to build cri-dockerd"
        sudo install bin/cri-dockerd /usr/local/bin/ || handle_error "Failed to install cri-dockerd"
        cd ..
        rm -rf cri-dockerd
    else
        log "INFO" "cri-dockerd is already installed"
    fi
}

# Function to install Go
install_go() {
    if ! command -v go &> /dev/null; then
        log "INFO" "Installing Go..."
        retry_command 3 wget https://dl.google.com/go/go1.16.5.linux-amd64.tar.gz
        sudo tar -C /usr/local -xzf go1.16.5.linux-amd64.tar.gz || handle_error "Failed to extract Go"
        export PATH=$PATH:/usr/local/go/bin
        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
        rm go1.16.5.linux-amd64.tar.gz
    else
        log "INFO" "Go is already installed"
    fi
}

# Function to start Minikube without root privileges
start_minikube() {
    log "INFO" "Starting Minikube..."
    sudo -u $USER minikube start --driver=docker --cpus=4 --memory=4096
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to start Minikube. Checking logs..."
        minikube logs
        log "INFO" "Attempting to restart Minikube..."
        sudo -u $USER minikube stop
        sudo -u $USER minikube delete
        sudo -u $USER minikube start --driver=docker --cpus=4 --memory=4096
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to restart Minikube. Exiting."
            exit 1
        fi
    fi
}

# Function to setup Kubernetes namespace
setup_namespace() {
    log "INFO" "Setting up Kubernetes namespace..."
    kubectl get namespace $KUBE_NAMESPACE || kubectl create namespace $KUBE_NAMESPACE
    log "INFO" "Creating service account and role binding..."
    kubectl apply -f - <<EOF
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

# Function to deploy MariaDB
deploy_mariadb() {
    log "INFO" "Deploying MariaDB..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-pvc
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
  name: mariadb
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
      - name: mariadb
        image: mariadb:latest
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
          name: mysql
        volumeMounts:
        - mountPath: /var/lib/mysql
          name: mariadb-persistent-storage
      volumes:
      - name: mariadb-persistent-storage
        persistentVolumeClaim:
          claimName: mariadb-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 3306
    targetPort: 3306
    name: mysql
  selector:
    app: mariadb
EOF
}

# Check MariaDB connection
check_db_connection() {
    log "INFO" "Checking database connection..."
    kubectl run mariadb-client --image=mariadb:latest --restart=Never --rm -i --namespace=$KUBE_NAMESPACE --command -- \
    bash -c "mysql -h mariadb-service -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'SHOW DATABASES;'" || {
        log "ERROR" "Unable to connect to MariaDB database. Fetching diagnostic information..."
        
        # Describe the MariaDB pod and service
        kubectl describe pod -l app=mariadb --namespace=$KUBE_NAMESPACE
        kubectl describe service mariadb-service --namespace=$KUBE_NAMESPACE
        
        # Fetch logs from the MariaDB pod
        kubectl logs -l app=mariadb --namespace=$KUBE_NAMESPACE
        
        # Check endpoints and service configuration
        kubectl get endpoints mariadb-service --namespace=$KUBE_NAMESPACE
        kubectl get svc mariadb-service --namespace=$KUBE_NAMESPACE -o yaml
        
        exit 1
    }
}

# Deploy WordPress for DOMAIN1
deploy_wordpress1() {
    log "INFO" "Deploying WordPress for DOMAIN1..."
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
          value: mariadb-service
        - name: WORDPRESS_DB_USER
          value: $WORDPRESS_DB_USER_DOMAIN1
        - name: WORDPRESS_DB_PASSWORD
          value: $WORDPRESS_DB_PASSWORD_DOMAIN1
        - name: WORDPRESS_DB_NAME
          value: $WORDPRESS_DB_DOMAIN1
        ports:
        - containerPort: 80
          name: http
EOF
}

# Deploy WordPress for DOMAIN2
deploy_wordpress2() {
    if [ -n "$DOMAIN2" ]; then
        log "INFO" "Deploying WordPress for DOMAIN2..."
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
          value: mariadb-service
        - name: WORDPRESS_DB_USER
          value: $WORDPRESS_DB_USER_DOMAIN2
        - name: WORDPRESS_DB_PASSWORD
          value: $WORDPRESS_DB_PASSWORD_DOMAIN2
        - name: WORDPRESS_DB_NAME
          value: $WORDPRESS_DB_DOMAIN2
        ports:
        - containerPort: 80
          name: http
EOF
    fi
}

# Deploy Roundcube
deploy_roundcube() {
    log "INFO" "Deploying Roundcube..."
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
        - name: DB_HOST
          value: mariadb-service
        - name: DB_USER
          value: $ROUNDCUBEMAIL_DB_USER
        - name: DB_PASSWORD
          value: $ROUNDCUBEMAIL_DB_PASSWORD
        - name: DB_NAME
          value: $ROUNDCUBEMAIL_DB
        ports:
        - containerPort: $WEBMAIL_PORT
          name: webmail
EOF
}

# Deploy Mailserver
deploy_mailserver() {
    log "INFO" "Deploying Mailserver..."
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
        image: mailserver/mailserver:latest
        env:
        - name: DB_HOST
          value: mariadb-service
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
    log "INFO" "Deploying PostfixAdmin..."
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
        - name: DB_HOST
          value: mariadb-service
        - name: DB_USER
          value: $POSTFIXADMIN_DB_USER
        - name: DB_PASSWORD
          value: $POSTFIXADMIN_DB_PASSWORD
        - name: DB_NAME
          value: $POSTFIXADMIN_DB
        ports:
        - containerPort: 80
          name: http
EOF
}

# Verify services
verify_services() {
    log "INFO" "Verifying services..."
    for deployment in mariadb wordpress1 wordpress2 roundcube mailserver postfixadmin; do
        kubectl rollout status deployment/$deployment --namespace=$KUBE_NAMESPACE
        if [ $? -ne 0 ]; then
            log "ERROR" "Deployment $deployment failed to roll out."
            log "INFO" "Fetching deployment details for $deployment..."
            kubectl describe deployment $deployment --namespace=$KUBE_NAMESPACE
            log "INFO" "Fetching logs for $deployment..."
            kubectl logs deployment/$deployment --namespace=$KUBE_NAMESPACE
            exit 1
        fi
    done
    log "INFO" "All deployments successfully rolled out."
}

# Test webmail access
test_webmail_access() {
    log "INFO" "Testing webmail access..."
    curl -I https://$WEBMAIL_DOMAIN
    if [ $? -ne 0 ]; then
        log "ERROR" "Unable to access webmail at https://$WEBMAIL_DOMAIN"
        exit 1
    fi
    log "INFO" "Webmail access verified at https://$WEBMAIL_DOMAIN"
}

# Check if port 8080 is in use
check_port_8080() {
    log "INFO" "Checking if port 8080 is in use..."
    if sudo lsof -i:8080 &> /dev/null; then
        log "ERROR" "Port 8080 is currently in use. Please resolve this conflict before proceeding."
        exit 1
    else
        log "INFO" "Port 8080 is free."
    fi
}

# Main script execution
clean_environment
install_dependencies
install_docker
install_kubectl
install_minikube
install_crictl
install_cri_dockerd
install_go
check_port_8080
start_minikube
setup_namespace
deploy_mariadb

# Wait for MariaDB to be ready before proceeding
sleep 30
check_db_connection

deploy_wordpress1
deploy_wordpress2
deploy_roundcube
deploy_mailserver
deploy_postfixadmin

verify_services
test_webmail_access

log "INFO" "Installation and setup complete."
log "INFO" "Access the services at the following URLs:"
log "INFO" "WordPress (DOMAIN1): http://$DOMAIN1"
log "INFO" "WordPress (DOMAIN2): http://$DOMAIN2"
log "INFO" "PostfixAdmin: http://admin.$DOMAIN1"
log "INFO" "Roundcube Webmail: http://webmail.$DOMAIN1"
log "INFO" "Mail server: mail.$DOMAIN1"

