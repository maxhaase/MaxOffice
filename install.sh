#!/bin/bash

# Load environment variables from vars.env
source vars.env

# Function to install dependencies
install_dependencies() {
  echo "Installing dependencies..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl software-properties-common ufw apt-transport-https certbot jq
}

# Function to install Docker
install_docker() {
  echo "Installing Docker..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  sudo apt-get update
  sudo apt-get install -y containerd.io docker-ce docker-ce-cli
  sudo usermod -aG docker $USER
}

# Function to install kubectl
install_kubectl() {
  echo "Installing kubectl..."
  curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
}

# Function to install Minikube
install_minikube() {
  echo "Installing Minikube..."
  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo install minikube-linux-amd64 /usr/local/bin/minikube
}

# Function to start Minikube
start_minikube() {
  echo "Starting Minikube..."
  minikube start --driver=docker --force
}

# Function to configure UFW firewall
configure_firewall() {
  echo "Configuring UFW firewall..."
  sudo ufw allow ${SSH_PORT}
  sudo ufw allow ${K8S_API_SERVER_PORT}/tcp
  sudo ufw allow ${HTTPS_PORT}/tcp
  sudo ufw allow ${HTTP_PORT}/tcp
  yes | sudo ufw enable
}

# Function to clean up Kubernetes resources
cleanup_kubernetes() {
  echo "Cleaning up Kubernetes resources..."
  kubectl delete namespace ${KUBE_NAMESPACE} || true
  kubectl delete namespace ingress-nginx || true
  kubectl delete namespace cert-manager || true
  minikube stop
  minikube delete
  sudo rm -rf ~/.kube ~/.minikube
  sudo rm -rf /usr/local/bin/localkube /usr/local/bin/minikube
  sudo systemctl stop '*kubelet*.mount' || true
  sudo systemctl disable kubelet || true
  sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/minikube /var/lib/localkube /var/log/localkube /var/log/minikube
  sudo ip link delete cni0 || true
  sudo ip link delete flannel.1 || true
  sudo rm -rf /var/lib/cni/
}

# Function to uninstall Cert-Manager
uninstall_cert_manager() {
  echo "Uninstalling Cert-Manager..."
  kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/v1.10.1/cert-manager.yaml || true
}

# Function to install Nginx Ingress controller
install_nginx_ingress() {
  echo "Installing Nginx Ingress controller..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
}

# Function to install Cert-Manager
install_cert_manager() {
  echo "Installing Cert-Manager..."
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.10.1/cert-manager.yaml
}

# Function to wait for Cert-Manager to be ready
wait_for_cert_manager() {
  echo "Waiting for Cert-Manager to be ready..."
  kubectl wait --namespace cert-manager --for=condition=ready pod --selector=app.kubernetes.io/instance=cert-manager --timeout=120s
}

# Function to configure Cert-Manager ClusterIssuer
configure_cert_manager() {
  echo "Configuring Cert-Manager ClusterIssuer..."
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${CERT_MANAGER_EMAIL}
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
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: ${KUBE_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mysql-service
  namespace: ${KUBE_NAMESPACE}
spec:
  ports:
    - port: 3306
      name: mysql
  selector:
    app: mysql
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: ${KUBE_NAMESPACE}
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
          value: ${MYSQL_ROOT_PASSWORD}
        - name: MYSQL_DATABASE
          value: ${MYSQL_DATABASE}
        - name: MYSQL_USER
          value: ${MYSQL_USER}
        - name: MYSQL_PASSWORD
          value: ${MYSQL_PASSWORD}
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: mysql-persistent-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mysql-persistent-storage
        persistentVolumeClaim:
          claimName: mysql-pvc
EOF
}

# Function to check database connection
check_database_connection() {
  echo "Checking database connection..."
  kubectl run mysql-client --rm -i --restart='Never' --namespace ${KUBE_NAMESPACE} --image=mysql:5.7 -- mysql -h mysql-service -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW DATABASES;"
}

# Function to deploy WordPress
deploy_wordpress() {
  echo "Deploying WordPress for ${DOMAIN1} and ${DOMAIN2}..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress1
  namespace: ${KUBE_NAMESPACE}
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
      - image: wordpress:latest
        name: wordpress1
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql-service
        - name: WORDPRESS_DB_NAME
          value: ${MYSQL_DATABASE}
        - name: WORDPRESS_DB_USER
          value: ${WORDPRESS_DB_USER_DOMAIN1}
        - name: WORDPRESS_DB_PASSWORD
          value: ${WORDPRESS_DB_PASSWORD_DOMAIN1}
        ports:
        - containerPort: 80
          name: wordpress1
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: wordpress1-service
  namespace: ${KUBE_NAMESPACE}
spec:
  ports:
    - port: ${DOMAIN1_PORT}
      targetPort: 80
      name: wordpress1
  selector:
    app: wordpress1
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress2
  namespace: ${KUBE_NAMESPACE}
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
      - image: wordpress:latest
        name: wordpress2
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql-service
        - name: WORDPRESS_DB_NAME
          value: ${MYSQL_DATABASE}
        - name: WORDPRESS_DB_USER
          value: ${WORDPRESS_DB_USER_DOMAIN2}
        - name: WORDPRESS_DB_PASSWORD
          value: ${WORDPRESS_DB_PASSWORD_DOMAIN2}
        ports:
        - containerPort: 80
          name: wordpress2
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: wordpress2-service
  namespace: ${KUBE_NAMESPACE}
spec:
  ports:
    - port: ${DOMAIN2_PORT}
      targetPort: 80
      name: wordpress2
  selector:
    app: wordpress2
EOF
}

# Function to deploy Roundcube
deploy_roundcube() {
  echo "Deploying Roundcube..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: roundcube
  namespace: ${KUBE_NAMESPACE}
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
      - image: roundcube/roundcubemail:latest
        name: roundcube
        env:
        - name: ROUNDCUBEMAIL_DB_HOST
          value: mysql-service
        - name: ROUNDCUBEMAIL_DB_NAME
          value: ${ROUNDCUBEMAIL_DB}
        - name: ROUNDCUBEMAIL_DB_USER
          value: ${ROUNDCUBEMAIL_DB_USER}
        - name: ROUNDCUBEMAIL_DB_PASSWORD
          value: ${ROUNDCUBEMAIL_DB_PASSWORD}
        ports:
        - containerPort: ${WEBMAIL_PORT}
          name: roundcube
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: roundcube-service
  namespace: ${KUBE_NAMESPACE}
spec:
  ports:
    - port: ${WEBMAIL_PORT}
      targetPort: 80
      name: roundcube
  selector:
    app: roundcube
EOF
}

# Function to deploy Mailserver
deploy_mailserver() {
  echo "Deploying Mailserver..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${KUBE_PVC_NAME_MAIL}
  namespace: ${KUBE_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${KUBE_SERVICE_NAME_MAILSERVER}
  namespace: ${KUBE_NAMESPACE}
spec:
  ports:
    - port: ${SMTP_PORT}
      name: smtp
    - port: ${SMTPS_PORT}
      name: smtps
    - port: ${SMTP_ALT_PORT}
      name: smtp-alt
    - port: ${POP3_PORT}
      name: pop3
    - port: ${POP3S_PORT}
      name: pop3s
    - port: ${IMAP_PORT}
      name: imap
    - port: ${IMAPS_PORT}
      name: imaps
  selector:
    app: mailserver
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailserver
  namespace: ${KUBE_NAMESPACE}
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
      - image: mailserver/mailserver:latest
        name: mailserver
        env:
        - name: MAILSERVER_DB_HOST
          value: mysql-service
        - name: MAILSERVER_DB_NAME
          value: ${MAILSERVER_DB}
        - name: MAILSERVER_DB_USER
          value: ${MAILSERVER_DB_USER}
        - name: MAILSERVER_DB_PASSWORD
          value: ${MAILSERVER_DB_PASSWORD}
        ports:
        - containerPort: ${SMTP_PORT}
          name: smtp
        - containerPort: ${SMTPS_PORT}
          name: smtps
        - containerPort: ${SMTP_ALT_PORT}
          name: smtp-alt
        - containerPort: ${POP3_PORT}
          name: pop3
        - containerPort: ${POP3S_PORT}
          name: pop3s
        - containerPort: ${IMAP_PORT}
          name: imap
        - containerPort: ${IMAPS_PORT}
          name: imaps
        volumeMounts:
        - name: mail-persistent-storage
          mountPath: /var/mail
      volumes:
      - name: mail-persistent-storage
        persistentVolumeClaim:
          claimName: ${KUBE_PVC_NAME_MAIL}
EOF
}

# Function to deploy PostfixAdmin
deploy_postfixadmin() {
  echo "Deploying PostfixAdmin..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postfixadmin
  namespace: ${KUBE_NAMESPACE}
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
      - image: postfixadmin/postfixadmin:latest
        name: postfixadmin
        env:
        - name: POSTFIXADMIN_DB_HOST
          value: mysql-service
        - name: POSTFIXADMIN_DB_NAME
          value: ${POSTFIXADMIN_DB}
        - name: POSTFIXADMIN_DB_USER
          value: ${POSTFIXADMIN_DB_USER}
        - name: POSTFIXADMIN_DB_PASSWORD
          value: ${POSTFIXADMIN_DB_PASSWORD}
        ports:
        - containerPort: ${ADMIN_GUI_PORT}
          name: postfixadmin
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postfixadmin-service
  namespace: ${KUBE_NAMESPACE}
spec:
  ports:
    - port: ${ADMIN_GUI_PORT}
      targetPort: 80
      name: postfixadmin
  selector:
    app: postfixadmin
EOF
}

# Function to set up Ingress
setup_ingress() {
  echo "Setting up Ingress..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: office-ingress
  namespace: ${KUBE_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  rules:
  - host: ${DOMAIN1}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: wordpress1-service
            port:
              number: 80
  - host: ${DOMAIN2}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: wordpress2-service
            port:
              number: 80
  - host: ${WEBMAIL_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: roundcube-service
            port:
              number: 80
  - host: ${MAIL_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: mailserver-service
            port:
              number: 80
  - host: ${ADMIN_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: postfixadmin-service
            port:
              number: 80
  tls:
  - hosts:
    - ${DOMAIN1}
    - ${DOMAIN2}
    - ${WEBMAIL_DOMAIN}
    - ${MAIL_DOMAIN}
    - ${ADMIN_DOMAIN}
    secretName: office-tls
EOF
}

# Function to verify services
verify_services() {
  echo "Verifying services..."
  kubectl rollout status deployment/mysql -n ${KUBE_NAMESPACE}
  kubectl rollout status deployment/wordpress1 -n ${KUBE_NAMESPACE}
  kubectl rollout status deployment/wordpress2 -n ${KUBE_NAMESPACE}
  kubectl rollout status deployment/roundcube -n ${KUBE_NAMESPACE}
  kubectl rollout status deployment/mailserver -n ${KUBE_NAMESPACE}
  kubectl rollout status deployment/postfixadmin -n ${KUBE_NAMESPACE}
}

# Function to back up certificates
backup_certificates() {
  echo "Backing up certificates..."
  kubectl get secret -n cert-manager letsencrypt-prod -o json | jq -r '.data["tls.crt"]' | base64 --decode > tls.crt
  kubectl get secret -n cert-manager letsencrypt-prod -o json | jq -r '.data["tls.key"]' | base64 --decode > tls.key
  tar -cvf certs.tar tls.crt tls.key
  rm tls.crt tls.key
}

# Check if certs.tar exists, if not run the whole script, else restore certificates
if [ ! -f certs.tar ]; then
  install_dependencies
  install_docker
  install_kubectl
  install_minikube
  configure_firewall
  cleanup_kubernetes
  uninstall_cert_manager
  start_minikube
  install_nginx_ingress
  install_cert_manager
  wait_for_cert_manager
  configure_cert_manager
  deploy_mysql
  check_database_connection
  deploy_wordpress
  deploy_roundcube
  deploy_mailserver
  deploy_postfixadmin
  setup_ingress
  verify_services
  backup_certificates
else
  echo "Restoring certificates from certs.tar..."
  tar -xvf certs.tar
  kubectl create secret tls letsencrypt-prod --cert=tls.crt --key=tls.key -n cert-manager
  rm tls.crt tls.key
  echo "Certificates restored."
fi

# Output service URLs
echo "You can access your applications at the following URLs:"
echo "WordPress 1: https://${DOMAIN1}"
echo "WordPress 2: https://${DOMAIN2}"
echo "Mailserver: https://${MAIL_DOMAIN}"
echo "Webmail: https://${WEBMAIL_DOMAIN}"
echo "Admin: https://${ADMIN_DOMAIN}"

