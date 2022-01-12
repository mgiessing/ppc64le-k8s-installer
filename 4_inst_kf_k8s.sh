#!/bin/bash

echo "Installing Kubeflow..."
cd ~
wget https://ibm.box.com/shared/static/ltvuagymxq73cfdumpmf93ec4avani97.sh -O inst_kf_k8s.sh
bash inst_kf_k8s.sh