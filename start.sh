#!/bin/bash

##############################################
# MaxOffice Setup Script
# Author: Max Haase - maxhaase@gmail.com
# This script creates a startup office Kubernetes cluster with multiple domains
# including mail server, webmail, Admin GUI, WordPress, storage server, and collaboration server.
##############################################

# Load environment variables from vars.env
if [ ! -f vars.env ]; then
  echo "Error: vars.env file not found!"
  exit 1
fi

source vars.env

# Redirect all output to a log file
exec > >(tee -i logs.log)
exec 2>&1

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Function to clean environment
clean_environment() {
    echo "Cleaning environment..."
    minikube delete || true
    sudo rm -rf /etc/docker/certs.d /etc/docker/key.json /var/lib/minikube /root/.minikube /root/.kube || true
    sudo rm -rf /home/$USER/.minikube /home/$USER/.kube || true
    sudo ufw disable || true
}

# Function to install missing dependencies
install_dependencies() {
    echo "Installing dependencies..."
    local required_packages=("apt-transport-https" "ca-certificates" "curl" "software-properties-common" "ufw" "wget" "git" "build-essential")
    local packages_to_install=()

    for package in "${required_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            packages_to_install+=("$package")
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        sudo apt-get update || handle_error "Failed to update package list"
        sudo apt-get install -y "${packages_to_install[@]}" || handle_error "Failed to install required packages: ${packages_to_install[*]}"
    else
        echo "All required packages are already installed"
    fi
}

# Function to check if a tool is installed
check_tool() {
    local tool=$1
    command -v $tool &> /dev/null
}

# Function to install Docker
install_docker() {
    if ! check_tool docker; then
        echo "Installing Docker..."
        sudo apt-get update
        sudo apt-get install -y docker.io
        sudo systemctl start docker
        sudo systemctl enable docker
    else
        echo "Docker is already installed"
    fi
}

# Function to install kubectl
install_kubectl() {
    if ! check_tool kubectl; then
        echo "Installing kubectl..."
        curl -LO "$KUBECTL_URL" || handle_error "Failed to download kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || handle_error "Failed to install kubectl"
        rm kubectl
    else
        echo "kubectl is already installed"
    fi
}

# Function to install Minikube
install_minikube() {
    if ! check_tool minikube; then
        echo "Installing Minikube..."
        curl -LO "$MINIKUBE_URL" || handle_error "Failed to download Minikube"
        sudo install minikube-linux-amd64 /usr/local/bin/minikube || handle_error "Failed to install Minikube"
        rm minikube-linux-amd64
    else
        echo "Minikube is already installed"
    fi
}

# Function to install crictl
install_crictl() {
    if ! check_tool crictl; then
        echo "Installing crictl..."
        curl -LO "$CRICTL_URL" || handle_error "Failed to download crictl"
        sudo tar -C /usr/local/bin -xzf crictl-v1.24.0-linux-amd64.tar.gz || handle_error "Failed to extract crictl"
        rm crictl-v1.24.0-linux-amd64.tar.gz
    else
        echo "crictl is already installed"
    fi
}

# Function to install Go
install_go() {
    if ! check_tool go; then
        echo "Installing Go..."
        wget "$GO_URL" -O go.tar.gz || handle_error "Failed to download Go"
        sudo tar -C /usr/local -xzf go.tar.gz || handle_error "Failed to extract Go"
        rm go.tar.gz
        echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.profile
        source ~/.profile
    else
        echo "Go is already installed"
    fi
}

# Function to install cri-dockerd
install_cri_dockerd() {
    if ! check_tool cri-dockerd; then
        echo "Installing cri-dockerd..."
        install_go
        if [ -d "cri-dockerd" ]; then
            sudo rm -rf cri-dockerd
        fi
        git clone "$CRI_DOCKERD_REPO" || handle_error "Failed to clone cri-dockerd"
        cd cri-dockerd || handle_error "Failed to enter cri-dockerd directory"
        mkdir -p bin
        /usr/local/go/bin/go build -o bin/cri-dockerd || handle_error "Failed to build cri-dockerd"
        sudo mv bin/cri-dockerd /usr/local/bin/
        cd ..
        rm -rf cri-dockerd
    else
        echo "cri-dockerd is already installed"
    fi
}

# Function to configure Docker group
configure_docker_group() {
    # Ensure Docker group exists
    if ! getent group docker; then
        sudo groupadd docker
    fi

    # Add the user to the Docker group
    if ! groups $USER | grep -q "\bdocker\b"; then
        sudo usermod -aG docker $USER
        echo "You have been added to the Docker group. Restarting script with new group membership..."
        sudo chmod 666 /var/run/docker.sock
        exec sg docker "$0"
        exit 0
    fi
}

# Function to start Minikube
start_minikube() {
    echo "Starting Minikube..."
    minikube start --driver=docker --cpus=$MINIKUBE_CPUS --memory=${MINIKUBE_MEMORY}mb || handle_error "Failed to start Minikube"
}

# Function to check Kubernetes API server availability
check_k8s_api() {
    echo "Checking Kubernetes API server availability..."
    for i in {1..10}; do
        kubectl cluster-info && return 0
        echo "Kubernetes API server is not ready yet. Retrying in 5 seconds..."
        sleep 5
    done
    handle_error "Kubernetes API server is not available after multiple attempts"
}

# Function to set up Kubernetes namespace
setup_namespace() {
    echo "Setting up Kubernetes namespace..."
    kubectl get namespace $KUBE_NAMESPACE &> /dev/null || kubectl create namespace $KUBE_NAMESPACE || handle_error "Failed to create namespace"
}

# Function to create MySQL secret
create_mysql_secret() {
    echo "Creating MySQL secret..."
    kubectl create secret generic mysql-secret \
        --from-literal=root-password=$MYSQL_ROOT_PASSWORD \
        --from-literal=username=$MYSQL_USER \
        --from-literal=password=$MYSQL_PASSWORD \
        --namespace=$KUBE_NAMESPACE --dry-run=client -o yaml | kubectl apply -f - || handle_error "Failed to create MySQL secret"
}

# Function to deploy MySQL
deploy_mysql() {
    echo "Deploying MySQL..."
    cat <<EOF | kubectl apply -f - || handle_error "Failed to deploy MySQL"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: $KUBE_NAMESPACE
spec:
  selector:
    matchLabels:
      app: mysql
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - image: mysql:5.7
        name: mysql
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        - name: MYSQL_DATABASE
          value: "$MYSQL_DATABASE"
        - name: MYSQL_USER
          value: "$MYSQL_USER"
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: password
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: mysql-persistent-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mysql-persistent-storage
        persistentVolumeClaim:
          claimName: $KUBE_PVC_NAME_MAIL
EOF

    kubectl rollout status deployment/mysql --namespace=$KUBE_NAMESPACE || handle_error "Deployment mysql failed to roll out"
}

# Function to check MySQL database connection
check_db_connection() {
    echo "Checking MySQL database connection..."
    for i in {1..10}; do
        kubectl run mysql-client --rm --tty -i --restart='Never' --namespace $KUBE_NAMESPACE --image=mysql:5.7 --command -- mysql -h mysql.$KUBE_NAMESPACE.svc.cluster.local -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" && return 0
        echo "Error: Unable to connect to MySQL database. Retrying in 5 seconds..."
        sleep 5
    done
    handle_error "Unable to connect to MySQL database after multiple attempts"
}

# Function for dry-run with Let's Encrypt to avoid hitting request limits
dry_run_letsencrypt() {
    echo "Performing Let's Encrypt dry-run for certificates..."
    certbot certonly --dry-run --standalone -d $DOMAIN1 -d $MAIL_DOMAIN -d $ADMIN_DOMAIN -d $WEBMAIL_DOMAIN --email $CERT_MANAGER_EMAIL --agree-tos --non-interactive || handle_error "Failed Let's Encrypt dry-run"
}

main() {
    clean_environment
    install_dependencies
    install_docker
    install_kubectl
    install_minikube
    install_crictl
    install_cri_dockerd
    configure_docker_group
    start_minikube
    check_k8s_api
    setup_namespace
    create_mysql_secret
    deploy_mysql
    check_db_connection
    dry_run_letsencrypt
    echo "Setup complete. Services are running."
}

main "$@"

