#!/bin/bash
# Author: Max Haase - maxhaase@gmail.com
##############################################################################################

# Redirect all output to a log file
exec > >(tee -i cleanup.log)
exec 2>&1

# Function to delete all resources in the namespace
delete_resources() {
    echo "Deleting all resources in the namespace $KUBE_NAMESPACE..."
    kubectl delete all --all --namespace=$KUBE_NAMESPACE
    kubectl delete pvc --all --namespace=$KUBE_NAMESPACE
    kubectl delete configmap --all --namespace=$KUBE_NAMESPACE
    kubectl delete secret --all --namespace=$KUBE_NAMESPACE
}

# Function to delete the namespace
delete_namespace() {
    echo "Deleting the namespace $KUBE_NAMESPACE..."
    kubectl delete namespace $KUBE_NAMESPACE
}

# Function to stop Minikube
stop_minikube() {
    echo "Stopping Minikube..."
    minikube stop
}

# Function to delete Minikube cluster
delete_minikube_cluster() {
    echo "Deleting Minikube cluster..."
    minikube delete
}

# Main script execution
delete_resources
delete_namespace
stop_minikube
delete_minikube_cluster

echo "Cleanup complete. The Kubernetes environment is reset."

