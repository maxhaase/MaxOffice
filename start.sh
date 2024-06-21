#!/bin/bash
# Author: Max Haase - maxhaase@gmail.com
##############################################################################################

# Load environment variables from vars.env
source vars.env

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Initialize Terraform
terraform init || handle_error "Failed to initialize Terraform"

# Apply Terraform configuration
terraform apply -auto-approve || handle_error "Failed to apply Terraform configuration"

# Configure kubectl
aws eks --region ${AWS_REGION} update-kubeconfig --name office-cluster || handle_error "Failed to configure kubectl"

# Apply Kubernetes manifests
kubectl apply -f kubernetes_manifests.yaml || handle_error "Failed to apply Kubernetes manifests"

# Deploy WordPress for DOMAIN1
kubectl apply -f - <<EOF || handle_error "Failed to deploy WordPress for DOMAIN1"
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
      - name: wordpress
        image: wordpress:latest
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql-service
        - name: WORDPRESS_DB_USER
          value: ${WORDPRESS_DB_USER_DOMAIN1}
        - name: WORDPRESS_DB_PASSWORD
          value: ${WORDPRESS_DB_PASSWORD_DOMAIN1}
        - name: WORDPRESS_DB_NAME
          value: ${WORDPRESS_DB_DOMAIN1}
        ports:
        - containerPort: 80
EOF

# Deploy WordPress for DOMAIN2 (if defined)
if [ -n "${DOMAIN2}" ]; then
  kubectl apply -f - <<EOF || handle_error "Failed to deploy WordPress for DOMAIN2"
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
      - name: wordpress
        image: wordpress:latest
        env:
        - name: WORDPRESS_DB_HOST
          value: mysql-service
        - name: WORDPRESS_DB_USER
          value: ${WORDPRESS_DB_USER_DOMAIN2}
        - name: WORDPRESS_DB_PASSWORD
          value: ${WORDPRESS_DB_PASSWORD_DOMAIN2}
        - name: WORDPRESS_DB_NAME
          value: ${WORDPRESS_DB_DOMAIN2}
        ports:
        - containerPort: 80
EOF
fi

# Deploy Roundcube
kubectl apply -f - <<EOF || handle_error "Failed to deploy Roundcube"
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
      - name: roundcube
        image: roundcube/roundcubemail:latest
        env:
        - name: DB_HOST
          value: mysql-service
        - name: DB_USER
          value: ${ROUNDCUBEMAIL_DB_USER}
        - name: DB_PASSWORD
          value: ${ROUNDCUBEMAIL_DB_PASSWORD}
        - name: DB_NAME
          value: ${ROUNDCUBEMAIL_DB}
        ports:
        - containerPort: 80
EOF

# Deploy Mailserver
kubectl apply -f - <<EOF || handle_error "Failed to deploy Mailserver"
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
      - name: mailserver
        image: mailserver/mailserver:latest
        env:
        - name: DB_HOST
          value: mysql-service
        - name: DB_USER
          value: ${MAILSERVER_DB_USER}
        - name: DB_PASSWORD
          value: ${MAILSERVER_DB_PASSWORD}
        - name: DB_NAME
          value: ${MAILSERVER_DB}
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
      volumes:
      - name: mail-persistent-storage
        persistentVolumeClaim:
          claimName: ${KUBE_PVC_NAME_MAIL}
---
apiVersion: v1
kind: Service
metadata:
  name: ${KUBE_SERVICE_NAME_MAILSERVER}
  namespace: ${KUBE_NAMESPACE}
spec:
  ports:
  - port: ${SMTP_PORT}
    targetPort: smtp
  - port: ${SMTPS_PORT}
    targetPort: smtps
  - port: ${SMTP_ALT_PORT}
    targetPort: smtp-alt
  - port: ${POP3_PORT}
    targetPort: pop3
  - port: ${POP3S_PORT}
    targetPort: pop3s
  - port: ${IMAP_PORT}
    targetPort: imap
  - port: ${IMAPS_PORT}
    targetPort: imaps
  selector:
    app: mailserver
EOF

# Deploy PostfixAdmin
kubectl apply -f - <<EOF || handle_error "Failed to deploy PostfixAdmin"
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
      - name: postfixadmin
        image: postfixadmin/postfixadmin:latest
        env:
        - name: DB_HOST
          value: mysql-service
        - name: DB_USER
          value: ${POSTFIXADMIN_DB_USER}
        - name: DB_PASSWORD
          value: ${POSTFIXADMIN_DB_PASSWORD}
        - name: DB_NAME
          value: ${POSTFIXADMIN_DB}
        ports:
        - containerPort: 80
EOF

# Verify services
echo "Verifying services..."
for deployment in mysql wordpress1 wordpress2 roundcube mailserver postfixadmin; do
  kubectl rollout status deployment/$deployment --namespace=${KUBE_NAMESPACE} || handle_error "Deployment $deployment failed to roll out"
done

# Test webmail access
echo "Testing webmail access..."
curl -I https://${WEBMAIL_DOMAIN} || handle_error "Unable to access webmail at https://${WEBMAIL_DOMAIN}"
echo "Webmail access verified at https://${WEBMAIL_DOMAIN}"

echo "Installation and setup complete."

