#!/bin/bash

ARCH=`arch`
USER=`whoami`
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NFS_SERVER=$(hostname -i)

echo -e "Installing NFS provisioner"

wget https://get.helm.sh/helm-v3.7.2-linux-ppc64le.tar.gz && tar -xvf helm* && mv linux-ppc64le/helm /usr/local/bin/helm && rm -rf helm-v* linux-ppc64le
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=${NFS_SERVER} \
    --set nfs.path=/export

kubectl patch storageclass nfs-client -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Optional 3 create dashboard:
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/aio/deploy/recommended.yaml 

# Patch and use NodePort
kubectl patch svc -n kubernetes-dashboard kubernetes-dashboard -p '{"spec":{"type": "NodePort"}}'

# Create admin account to login:

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
EOF

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

#Get Login token:
TOKEN=$(kubectl -n kubernetes-dashboard get secret $(kubectl -n kubernetes-dashboard get sa/admin-user -o jsonpath="{.secrets[0].name}") -o go-template="{{.data.token | base64decode}}")

echo -e "${ORANGE}Login to the Kubernetes Dashboard using a browser: ${BLUE}https://$(hostname -i):$(kubectl get svc -n kubernetes-dashboard | grep kubernetes-dashboard | awk '{print $5}' | cut -d ':' -f2 | cut -d '/' -f1)${NC}"
echo -e "${ORANGE}The Login Token is:${NC}\n${TOKEN}"