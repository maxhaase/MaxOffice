# Installation file for MaxOffice. You shouldn't need to edit this file.
# Author: Max Haase - maxhaase@gmail.com
# This program creates a startup office Kubernetes cluster with 1 or more domains 
# with mail server, webmail, Admin GUI, WordPress, storage server and collaboration server.
# Make sure your user has password-less sudo rights, make this script executable chmod +x 
# The script install.sh will deploy the complete Kubernetes cluster automagically!
##########################################################################################
#!/bin/bash

# Function to log information
log() {
    local level="$1"
    shift
    echo "[$level] $(date +%F" "%T) $*"
}

# Redirect all output to a log file
exec > >(tee -i logs.log)
exec 2>&1

# Load environment variables from vars.env
if [ -f vars.env ]; then
    source vars.env
else
    log "ERROR" "vars.env file not found!"
    exit 1
fi

# Adjust fs.protected_regular setting to avoid lock permission issues
log "INFO" "Adjusting fs.protected_regular setting..."
sudo sysctl fs.protected_regular=0

# Function to clean up environment
cleanup_environment() {
    log "INFO" "Cleaning up environment..."
    sudo kubectl delete namespace $KUBE_NAMESPACE --ignore-not-found=true
    sudo kubectl delete pods --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
    sudo kubectl delete services --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
    sudo kubectl delete deployments --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
    sudo kubectl delete pvc --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
}

# Function to install dependencies
install_dependencies() {
    log "INFO" "Installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common ufw pv
}

# Function to install Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "INFO" "Installing Docker..."
        sudo apt-get update
        sudo apt-get install -y docker.io
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
        # Refresh group membership
        newgrp docker <<EOF
EOF
    else
        log "INFO" "Docker is already installed"
        sudo usermod -aG docker $USER
        newgrp docker <<EOF
EOF
    fi
}

# Function to install kubectl
install_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log "INFO" "Installing kubectl..."
        curl -LO $KUBECTL_URL
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
    else
        log "INFO" "kubectl is already installed"
    fi
}

# Function to install Minikube
install_minikube() {
    if ! command -v minikube &> /dev/null; then
        log "INFO" "Installing Minikube..."
        curl -LO $MINIKUBE_URL
        sudo install minikube-linux-amd64 /usr/local/bin/minikube
        rm minikube-linux-amd64
    else
        log "INFO" "Minikube is already installed"
    fi
}

# Function to install crictl
install_crictl() {
    if ! command -v crictl &> /dev/null; then
        log "INFO" "Installing crictl..."
        curl -LO $CRICTL_URL
        sudo tar zxvf $(basename $CRICTL_URL) -C /usr/local/bin
        rm -f $(basename $CRICTL_URL)
    else
        log "INFO" "crictl is already installed"
    fi
}

# Function to install cri-dockerd
install_cri_dockerd() {
    if ! command -v cri-dockerd &> /dev/null; then
        log "INFO" "Installing cri-dockerd..."
        sudo apt-get install -y git make
        sudo apt-get install -y gcc g++ golang-1.20-go
        sudo ln -sf /usr/lib/go-1.20/bin/go /usr/bin/go
        git clone $CRI_DOCKERD_REPO
        cd cri-dockerd
        mkdir bin
        go build -o bin/cri-dockerd
        sudo install -o root -g root -m 0755 bin/cri-dockerd /usr/local/bin/
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
        sudo apt-get update
        sudo apt-get install -y golang-1.20-go
        sudo ln -sf /usr/lib/go-1.20/bin/go /usr/bin/go
    else
        log "INFO" "Go is already installed"
    fi
}

# Function to start Minikube
start_minikube() {
    log "INFO" "Starting Minikube..."
    # Suppress Minikube logs by redirecting to /dev/null
    sudo minikube start --driver=docker --cpus=$MINIKUBE_CPUS --memory=$MINIKUBE_MEMORY --force > minikube_start.log 2>&1
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to start Minikube. Checking logs..."
        sudo minikube logs
        log "INFO" "Attempting to restart Minikube..."
        sudo minikube stop
        sudo minikube delete
        sudo minikube start --driver=docker --cpus=$MINIKUBE_CPUS --memory=$MINIKUBE_MEMORY --force > minikube_start.log 2>&1
        if [ $? -ne 0 ];then
            log "ERROR" "Failed to restart Minikube. Exiting."
            exit 1
        fi
    fi
}

# Function to setup Kubernetes namespace
setup_namespace() {
    log "INFO" "Setting up Kubernetes namespace..."
    sudo kubectl get namespace $KUBE_NAMESPACE || sudo kubectl create namespace $KUBE_NAMESPACE
    log "INFO" "Creating service account and role binding..."
    sudo kubectl apply -f - <<EOF
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
    sudo kubectl apply -f - <<EOF
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
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-secret
  namespace: $KUBE_NAMESPACE
type: Opaque
data:
  mysql-root-password: $(echo -n $MYSQL_ROOT_PASSWORD | base64)
  mysql-database: $(echo -n $MYSQL_DATABASE | base64)
  mysql-user: $(echo -n $MYSQL_USER | base64)
  mysql-password: $(echo -n $MYSQL_PASSWORD | base64)
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
        ports:
        - containerPort: 3306
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: mysql-root-password
        - name: MYSQL_DATABASE
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: mysql-database
        - name: MYSQL_USER
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: mysql-user
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mariadb-secret
              key: mysql-password
        volumeMounts:
        - name: mariadb-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mariadb-storage
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
  selector:
    app: mariadb
EOF
}

# Function to verify MariaDB deployment
verify_mariadb() {
    log "INFO" "Verifying MariaDB deployment..."
    sudo kubectl wait --namespace $KUBE_NAMESPACE --for=condition=available --timeout=600s deployment/mariadb
    if [ $? -ne 0 ]; then
        log "ERROR" "MariaDB deployment did not become ready. Exiting."
        exit 1
    fi
    log "INFO" "MariaDB deployment is ready."
    log "INFO" "Checking MariaDB connection..."
    
    # Retry mechanism for MariaDB connection
    local retries=5
    local wait=10
    local count=0
    while [ $count -lt $retries ]; do
        sudo kubectl run mariadb-client --rm -i --tty --namespace $KUBE_NAMESPACE --image=bitnami/mariadb:latest --restart=Never -- bash -c "/opt/bitnami/mariadb/bin/mariadb -hmariadb-service -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'SHOW DATABASES;'"
        if [ $? -eq 0 ]; then
            log "INFO" "Successfully connected to MariaDB database."
            return
        else
            log "WARN" "Unable to connect to MariaDB database. Retrying in $wait seconds..."
            sleep $wait
            count=$((count+1))
        fi
    done
    log "ERROR" "Unable to connect to MariaDB database after $retries attempts. Exiting."
    exit 1
}

# Main script execution
cleanup_environment
install_dependencies
install_docker
install_kubectl
install_minikube
install_crictl
install_cri_dockerd
install_go
start_minikube
setup_namespace
deploy_mariadb
verify_mariadb

log "INFO" "Installation and setup complete."
