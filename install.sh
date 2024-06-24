# Installation file for MaxOffice. You shouldn't need to edit this file.
# Author: Max Haase - maxhaase@gmail.com
# This program creates a startup office Kubernetes cluster with 1 or more domains 
# with mail server, webmail, Admin GUI, WordPress, storage server and collaboration server.
# Make sure your user has password-less sudo rights, make this script executable chmod +x 
# The script install.sh will deploy the complete K8s cluster automagically!
###############################################################################
#!/bin/bash

log() {
    local level="$1"
    shift
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Redirect all output to a log file
exec > >(tee -i logs.log)
exec 2>&1

# Load environment variables from vars.env
if [ -f vars.env ]; then
    source vars.env
else
    echo "vars.env file not found!"
    exit 1
fi

# Function to clean up environment
cleanup_environment() {
    log "INFO" "Cleaning up environment..."
    kubectl delete namespace $KUBE_NAMESPACE --ignore-not-found=true
    kubectl delete pods --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
    kubectl delete services --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
    kubectl delete deployments --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
    kubectl delete pvc --all --namespace=$KUBE_NAMESPACE --ignore-not-found=true
}

# Function to install dependencies
install_dependencies() {
    log "INFO" "Installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common ufw
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
    else
        log "INFO" "Docker is already installed"
        sudo usermod -aG docker $USER
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
        sudo tar zxvf crictl-v1.24.0-linux-amd64.tar.gz -C /usr/local/bin
        rm -f crictl-v1.24.0-linux-amd64.tar.gz
    else
        log "INFO" "crictl is already installed"
    fi
}

# Function to install cri-dockerd
install_cri_dockerd() {
    if ! command -v cri-dockerd &> /dev/null; then
        log "INFO" "Installing cri-dockerd..."
        sudo apt-get install -y git
        git clone $CRI_DOCKERD_REPO
        cd cri-dockerd
        mkdir bin
        /usr/local/go/bin/go build -o bin/cri-dockerd
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
        curl -LO $GO_URL
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
        rm go$GO_VERSION.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.profile
    else
        log "INFO" "Go is already installed"
    fi
}

# Function to start Minikube
start_minikube() {
    log "INFO" "Starting Minikube..."
    newgrp docker <<EONG
        minikube start --driver=docker --cpus=$MINIKUBE_CPUS --memory=$MINIKUBE_MEMORY
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to start Minikube. Checking logs..."
            minikube logs
            log "INFO" "Attempting to restart Minikube..."
            minikube stop
            minikube delete
            minikube start --driver=docker --cpus=$MINIKUBE_CPUS --memory=$MINIKUBE_MEMORY
            if [ $? -ne 0 ];then
                log "ERROR" "Failed to restart Minikube. Exiting."
                exit 1
            fi
        fi
EONG
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
    targetPort: 3306
    name: mysql
  selector:
    app: mariadb
EOF
}

# Function to verify MariaDB deployment
verify_mariadb() {
    log "INFO" "Verifying MariaDB deployment..."
    kubectl wait --namespace $KUBE_NAMESPACE --for=condition=available --timeout=300s deployment/mariadb
    if [ $? -ne 0 ]; then
        log "ERROR" "MariaDB deployment did not become ready. Exiting."
        exit 1
    fi
    log "INFO" "MariaDB deployment is ready."
    log "INFO" "Checking MariaDB connection..."
    kubectl run mariadb-client --rm -i --tty --namespace $KUBE_NAMESPACE --image=bitnami/mariadb:latest --restart=Never -- bash -c "mysql -hmariadb-service -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'SHOW DATABASES;'"
    if [ $? -ne 0 ]; then
        log "ERROR" "Unable to connect to MariaDB database. Exiting."
        exit 1
    fi
    log "INFO" "Successfully connected to MariaDB database."
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
