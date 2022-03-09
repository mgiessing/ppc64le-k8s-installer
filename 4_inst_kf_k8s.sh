#!/bin/bash

echo "Installing Kubeflow..."
cd ~
KUBEFLOW_VERSION=main
wget https://raw.githubusercontent.com/lehrig/kubeflow-ppc64le-manifests/${KUBEFLOW_VERSION}/install_kubeflow.sh
source install_kubeflow.sh
