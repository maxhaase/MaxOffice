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
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common ufw certbot
}

# Function to install Docker
install_docker() {
    echo "Installing Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo usermod -aG docker $USER
}

# Function to install kubectl
install_kubectl() {
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
}

# Function to install Minikube
install_minikube() {
    echo "Installing Minikube..."
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
}

# Function to start Minikube without root privileges
start_minikube() {
    echo "Starting Minikube..."
    sudo -u $USER minikube start --driver=docker --memory=4096 --cpus=2
}

# Function to setup Kubernetes namespace
setup_namespace() {
    echo "Setting up Kubernetes namespace..."
    kubectl get namespace $KUBE_NAMESPACE || kubectl create namespace $KUBE_NAMESPACE
}

# Function to open necessary ports on Ubuntu VM
configure_firewall() {
    echo "Configuring UFW firewall..."
    sudo ufw allow $SSH_PORT
    sudo ufw allow $HTTP_PORT
    sudo ufw allow $HTTPS_PORT
    sudo ufw allow $SMTP_PORT
    sudo ufw allow $SMTPS_PORT
    sudo ufw allow $SMTP_ALT_PORT
    sudo ufw allow $POP3_PORT
    sudo ufw allow $POP3S_PORT
    sudo ufw allow $IMAP_PORT
    sudo ufw allow $IMAPS_PORT
    sudo ufw allow $WEBMAIL_PORT
    sudo ufw allow $DOMAIN1_PORT
    sudo ufw allow $DOMAIN2_PORT
    sudo ufw allow $ADMIN_GUI_PORT
    sudo ufw --force enable
}

# Function to uninstall Cert-Manager
uninstall_cert_manager() {
    echo "Uninstalling Cert-Manager..."
    kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/v1.7.1/cert-manager.yaml --ignore-not-found
    kubectl delete namespace cert-manager --ignore-not-found
    kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io cert-manager-webhook --ignore-not-found
    kubectl delete mutatingwebhookconfigurations.admissionregistration.k8s.io cert-manager-webhook --ignore-not-found
}

# Function to cleanup Kubernetes resources
cleanup_kubernetes() {
    echo "Cleaning up Kubernetes resources..."
    kubectl delete namespace $KUBE_NAMESPACE --ignore-not-found
    kubectl delete namespace ingress-nginx --ignore-not-found
    uninstall_cert_manager
}

# Function to install and configure Nginx Ingress controller
install_ingress_controller() {
    echo "Installing Nginx Ingress controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
}

# Function to install and configure Cert-Manager
install_cert_manager() {
    echo "Installing Cert-Manager..."
    kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.7.1/cert-manager.yaml

    echo "Waiting for Cert-Manager to be ready..."
    kubectl wait --namespace cert-manager --for=condition=ready pod --selector=app.kubernetes.io/instance=cert-manager --timeout=120s

    echo "Configuring Cert-Manager ClusterIssuer..."
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
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
  selector:
    app: mysql
EOF
}

# Function to check MySQL connection
check_db_connection() {
    echo "Checking database connection..."
    kubectl run mysql-client --image=mysql:5.7 -i --rm --restart=Never --namespace=$KUBE_NAMESPACE --command -- \
    mysql -h mysql-service -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" || {
        echo "Error: Unable to connect to MySQL database."
        exit 1
    }
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

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: roundcube-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 80
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

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: postfixadmin-service
  namespace: $KUBE_NAMESPACE
spec:
  ports:
  - port: 80
  selector:
    app: postfixadmin
EOF
}

# Function to setup Ingress
setup_ingress() {
    echo "Setting up Ingress..."
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: office-ingress
  namespace: $KUBE_NAMESPACE
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  rules:
  - host: $DOMAIN1
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: wordpress1-service
            port:
              number: 80
  - host: $DOMAIN2
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: wordpress2-service
            port:
              number: 80
  - host: $ADMIN_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: postfixadmin-service
            port:
              number: 80
  - host: $WEBMAIL_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: roundcube-service
            port:
              number: 80
  - host: $MAIL_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: mailserver-service
            port:
              number: 80
  tls:
  - hosts:
    - $DOMAIN1
    - $DOMAIN2
    - $ADMIN_DOMAIN
    - $WEBMAIL_DOMAIN
    - $MAIL_DOMAIN
    secretName: office-tls
EOF
}

# Function to verify services
verify_services() {
    echo "Verifying services..."

    for deployment in mysql wordpress1 wordpress2 roundcube mailserver postfixadmin; do
        kubectl rollout status deployment/$deployment --namespace=$KUBE_NAMESPACE
        if [ $? -ne 0 ]; then
            echo "Error: Deployment $deployment failed to roll out."
            exit 1
        fi
    done

    echo "All deployments successfully rolled out."
}

# Function to test webmail access
test_webmail_access() {
    echo "Testing webmail access..."
    curl -I https://$WEBMAIL_DOMAIN
    if [ $? -ne 0 ]; then
        echo "Error: Unable to access webmail at https://$WEBMAIL_DOMAIN"
        exit 1
    fi
    echo "Webmail access verified at https://$WEBMAIL_DOMAIN"
}

# Main script execution
install_dependencies
install_docker
install_kubectl
install_minikube
start_minikube
configure_firewall
cleanup_kubernetes
setup_namespace
install_ingress_controller
install_cert_manager
deploy_mysql

# Wait for MySQL to be ready before proceeding
sleep 30
check_db_connection

deploy_wordpress1
deploy_wordpress2
deploy_roundcube
deploy_mailserver
deploy_postfixadmin

setup_ingress
verify_services
test_webmail_access

echo "Installation and setup complete."

