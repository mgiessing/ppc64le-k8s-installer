#!/bin/bash

ARCH=`arch`
USER=`whoami`
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${ORANGE}CAUTION: This script must run on the ansible/master node, NOT THE KVM HOST!${NC}"
echo -e "${ORANGE}Also, make sure you have passwordless SSH to all your nodes before going on!\nContinue?${NC}"

select choice in "Yes" "No"
do
    break
done

if test $REPLY == 2
then
    exit
fi

#Nach den IPs fragen, falls keine CECC Maschine
if [ -z "$IPS" ]
then
    echo -e "Enter the IPs of your servers (including this) seperated by space (e.g. '10.10.10.1 10.10.10.2')"
    read IPS
    sed -i '/IPS=/d' ${HOME}/.bashrc 
    echo "IPS=\"$IPS\"" >> ${HOME}/.bashrc
else
    echo -e "${GREEN}Found the following IPs: ${IPS}${NC}"
fi

echo -e "Checking if passwordless ssh is working..."
for i in $IPS
do
ssh -o PasswordAuthentication=no root@$i /bin/true
if [ $(echo $?) == 0 ]
then
    echo -e "${GREEN}Passwordless SSH to $i works!${NC}"
else
    echo -e "${RED}Cannot login to $i without password!${NC}"
    echo -e "You can try to copy the key with ${BLUE}'ssh-copy-id root@$i'${NC}\nExiting..."
    exit
fi
done

#Check for GPU Nodes
echo -e "Checking if there are any GPU nodes available..."
GPU_NODES=""
for i in $IPS
do
    var=$(ssh root@$i 'if ! command -v lspci &> /dev/null; then dnf install -y pciutils; fi && if [ -z "$(lspci | grep -i nvidia)" ]; then echo "no_gpu"; else echo "gpu"; fi')
    if [ "$var" = "gpu" ]
    then
        echo "Found GPU on node $i!"
        GPU_NODES="$GPU_NODES $i"
    fi
done

#Check if nvidia is installed on GPU Nodes
for i in $GPU_NODES
do
    var=$(ssh root@$i 'if ! command -v nvidia-smi &> /dev/null; then echo "not_installed"; fi')
if [ "$var" = "not_installed" ]
then
    echo "Nvidia drivers are not installed on node $i, please do this first!"
    exit
fi
done

#check for firewall - this does not end the script if an active firewall is found!
echo -e "Check if firewall daemon is active and open ports"
for i in $IPS
do
echo -e "Open ports on $i..."
ssh root@$i 'if [ `systemctl is-active firewalld` = "active" ]; then firewall-cmd --permanent --add-port=6443/tcp \
   && firewall-cmd --permanent --add-port=2379-2380/tcp \
   && firewall-cmd --permanent --add-port=10250/tcp \
   && firewall-cmd --permanent --add-port=10251/tcp \
   && firewall-cmd --permanent --add-port=10252/tcp \
   && firewall-cmd --permanent --add-port=10255/tcp \
   && firewall-cmd --zone=public --add-masquerade --permanent \
   && firewall-cmd --zone=public --add-port=443/tcp \
   && firewall-cmd --reload; fi'
done

#Nach Docker Cred fragen
echo -e "${ORANGE}Your docker.io account is needed to avoid 'pull rate limit' problems...${NC}"

DOCKER_USER=""
echo "docker.io user name:"
read DOCKER_USER

DOCKER_PW=""
echo "docker.io password (input hidden):"
read -s DOCKER_PW
echo "Saving credentials..."

AUTH="$(echo -n $DOCKER_USER:$DOCKER_PW  | base64)"

cat << EOF > docker_config.json
{
    "auths": {
        "https://index.docker.io/v1/": {
            "auth": "${AUTH}"
        }
    }
}
EOF

#configure iptables
for i in $IPS
do
ssh root@$i "if ! command -v iptables &> /dev/null; then dnf install -y iptables; fi  && iptables -P FORWARD ACCEPT && mkdir -p /root/.docker"
done

#save docker credentials
for i in $IPS
do
scp docker_config.json root@$i:/root/.docker/config.json
done
rm -rf docker_config.json

echo -e "${ORANGE}Do you want an NFS server installed on this node?${NC}"
select choice in "Yes, please install an NFS server on this node" "No, I'm going to do that manually/provide my own"
do
    break
done

if test $REPLY == 1
then
if [ `systemctl is-active firewalld` = "active" ]; then firewall-cmd --permanent --add-service nfs && firewall-cmd --reload && systemctl restart nfs-server; fi
mkdir -p /export && chown -R nobody: /export
dnf install nfs-utils -y && systemctl enable --now nfs-server.service


#This is insecure and should be fixed by changing database permissions inside the container (e.g. MySQL) and then set to 'root_squash'...
sed -i '/\/export/d' /etc/exports
echo "/export *(rw,sync,no_root_squash)" >> /etc/exports
exportfs -a
#################
fi

dnf install python3 python3-netaddr git -y
pip3 install --upgrade pip

rm -rf /opt/kubespray
git clone -b v2.20.0 https://github.com/kubernetes-sigs/kubespray.git /opt/kubespray && cd /opt/kubespray

## Only on Ansible/Master node:
ANSIBLE_VERSION=2.11
pip3 install --extra-index-url=https://repo.fury.io/mgiessing -r requirements-$ANSIBLE_VERSION.txt

#sed -i "s/kube_version: .*/kube_version: v1.21.11/g" inventory/sample/group_vars/k8s_cluster/k8s-cluster.yml
#sed -i "s/kube_version: .*/kube_version: v1.21.11/g" roles/kubespray-defaults/defaults/main.yaml

#For Kubeflow this change is needed https://github.com/kubeflow/manifests/issues/959
sed -i '/kube_kubeadm_apiserver_extra_args/d' roles/kubernetes/control-plane/defaults/main/main.yml
cat << EOF >> roles/kubernetes/control-plane/defaults/main/main.yml
kube_kubeadm_apiserver_extra_args: {
  service-account-issuer: kubernetes.default.svc,
  service-account-signing-key-file: /etc/kubernetes/ssl/sa.key
}
EOF

cp -rfp inventory/sample inventory/mycluster

echo $IPS

bash << EOF
declare -a IPS=(echo $IPS)
EOF

CONFIG_FILE=inventory/mycluster/hosts.yaml python3 contrib/inventory_builder/inventory.py ${IPS[@]}

echo "alias oc='kubectl'" >> ${HOME}/.bashrc
echo "alias ocproject='kubectl config set-context --current --namespace'" >> ${HOME}/.bashrc
source ${HOME}/.bashrc

echo -e "${GREEN}Done!${NC} Kubespray initialized with default settings. You can review and change cluster parameters under:\ncat /opt/kubespray/inventory/mycluster/group_vars/all/all.yml\ncat /opt/kubespray/inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml"
echo -e "If everything looks fine run the playbook with ${BLUE}'source ${HOME}/.bashrc && cd /opt/kubespray && ansible-playbook -i inventory/mycluster/hosts.yaml  --become --become-user=root cluster.yml'${NC}"
echo -e "This might take 45-60 minutes to complete. You can then run the next script to install the nfs-provisioner and the k8s-dashboard"

## ToDo's:
#nerdctl login -u <user>
