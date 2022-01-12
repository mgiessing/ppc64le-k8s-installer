# k8s-installer

## Repository to install Kubernetes on IBM Power using Kubespray

- The first script will setup a KVM system in IBM CECC (S822LC / AC922) that can host VMs which act as the cluster nodes (this is optional if you already got VMs provisioned)

- The second script prepares the VMs and installs Kubernetes (v1.19.9) using Kubespray (v2.15.1)

- The third script will configure a default storage class and deploy the Kubernetes Dashboard

- The fourth script will install Kubeflow
