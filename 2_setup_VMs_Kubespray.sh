
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
    echo "Enter the IPs of your servers (including this) seperated by space (e.g. '10.10.10.1 10.10.10.2')"
    read IPS
    sed -i '/IPS=/d' /root/.bashrc 
    echo "IPS=\"$IPS\"" >> /root/.bashrc
else
    echo "${GREEN}Found the following IPs: ${IPS}${NC}"
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

#Nach Docker Cred fragen
echo -e "${ORANGE}Your docker.io account is needed to avoid 'pull rate limit' problems...${NC}"

DOCKER_USER=""
echo "docker.io user name:"
read DOCKER_USER

DOCKER_PW=""
echo "docker.io password (input hidden):"
read -s DOCKER_PW

echo -e "${ORANGE}Do you want an NFS server installed on this node?${NC}"
select choice in "Yes, please install an NFS server on this node" "No, I'm going to do that manually/provide my own"
do
    break
done

if test $REPLY == 1
then
mkdir /export && chown -R nobody: /export
dnf install nfs-utils -y && systemctl enable --now nfs-server.service

#This is insecure and should be fixed by changing database permissions inside the container (e.g. MySQL) and then set to 'root_squash'...
sed -i '/\/export/d' /etc/exports
echo "/export *(rw,sync,no_root_squash)" >> /etc/exports
exportfs -a
#################
fi

dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm

dnf install pssh -y

# Prepare pssh file with cecuser
rm -rf /root/.pssh_hosts_files
for i in ${IPS};
do
cat << EOF >> /root/.pssh_hosts_files
root@${i}
EOF
done


# 2 Use PSSH to do prepartion requred on ALL HOSTS [EXECUTED ON FIRST MASTER]

#For CECC systems we need to fake centos distro (RHEL is installed but with private IBM repo)
pssh -i -t 0 -h ~/.pssh_hosts_files "sudo sed -i 's/ID=\"rhel\"/ID=\"centos\"/g' /etc/os-release"

echo -e "${ORANGE}Installing required packages on all servers${NC}"
#Prepare all servers (gpgcheck sometimes fails with pssh, you can try to pssh install with gpgcheck)
pssh -i -h ~/.pssh_hosts_files "dnf --nogpgcheck install -y yum-utils device-mapper-persistent-data lvm2 iproute-tc"

echo -e "${ORANGE}Configure SELinux on all servers${NC}"
#Configure SELinux - ToCheck: Is this done via kubespray?
pssh -i -h ~/.pssh_hosts_files "sudo setenforce 0 && \
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/g' /etc/selinux/config"

echo -e "Configure swap on all servers"
#Configure swap - ToCheck: Is this done via kubespray?
pssh -i -h ~/.pssh_hosts_files "sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab && \
sudo swapoff -a"

#Configure IPv4 forwarding & sysctl - ToCheck: Is this done via kubespray?
pssh -i -h ~/.pssh_hosts_files "sudo modprobe overlay && sudo modprobe br_netfilter && \
sudo tee /etc/sysctl.d/kubernetes.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system"

echo -e "${ORANGE}Installing docker on all servers. This might take a bit...${NC}"
#Install docker
pssh -i -t 0 -h ~/.pssh_hosts_files "sudo dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo && \
sudo dnf --nogpgcheck install docker-ce docker-ce-cli -y && \
sudo sudo systemctl enable --now docker"

#Login to overcome pull-rate-limit
pssh -i -h ~/.pssh_hosts_files "sudo docker login docker.io -u ${DOCKER_USER} -p ${DOCKER_PW}"

## Only on Ansible/Master node:
dnf install wget git python3-netaddr -y
cd /root
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-ppc64le.sh && bash Miniconda3-latest-Linux-ppc64le.sh -b
export PATH="/root/miniconda3/bin:${PATH}"
export IBM_POWERAI_LICENSE_ACCEPT=yes
conda config --prepend channels https://public.dhe.ibm.com/ibmdl/export/pub/software/server/ibm-ai/conda/
conda config --prepend channels https://ftp.osuosl.org/pub/open-ce/current
conda config --prepend channels https://opence.mit.edu
conda create --name py38 python=3.8 -y
conda init bash
echo "conda activate py38" >> /root/.bashrc
rm -rf Miniconda3-latest-Linux-ppc64le.sh
source /root/.bashrc

conda install -c conda-forge -y ruamel.yaml==0.16.10 jmespath==0.9.5 pbr==5.4.4 netaddr==0.7.19 jinja2==2.11.3 cryptography==2.8 && pip3 install ansible==2.9.27 requests

cd ~
rm -rf /root/kubespray
git clone -b v2.15.1 https://github.com/kubernetes-sigs/kubespray.git
wget https://ibm.box.com/shared/static/d9olpybowici8d0kbamblo1wv2tq7gfh.patch -O kubespray/ppc64le.patch
cd kubespray && git apply ppc64le.patch

echo "Installing yq..."
wget https://github.com/mikefarah/yq/releases/download/v4.24.5/yq_linux_ppc64le -O /usr/bin/yq && chmod +x /usr/bin/yq

echo "Updating Kubernetes hashes..."
cd /root/kubespray/scripts && python3 download_hash.py 1.21.11
cd /root/kubespray && yq -i '.crictl_supported_versions += {"v1.21": "v1.21.0"}' roles/download/defaults/main.yml && \
   yq -i '.crictl_checksums.ppc64le += {"v1.21.0": "0770100d30d430dbb67a58119ffed459856163ba01b6d71ac6fd4be7336253cf"}' roles/download/defaults/main.yml 
 
cd /root/kubespray

#sed -i "s/kube_version:.*/kube_version: v1.21.11/g" inventory/sample/group_vars/k8s-cluster/k8s-cluster.yml
#sed -i "s/kube_version:.*/kube_version: v1.21.11/g" roles/kubespray-defaults/defaults/main.yaml

###
# vi roles/network_plugin/calico/defaults/main.yml & edit calico_iptables_backend: "Legacy" zu "NFT"
###

#Legacy iptables is not working anymore on RHEL/CentOS8, therefore change to NFT or Auto
sed -i "s/calico_iptables_backend: \"Legacy\"/calico_iptables_backend: \"NFT\"/g" roles/network_plugin/calico/defaults/main.yml

#For Kubeflow this change is needed https://github.com/kubeflow/manifests/issues/959
sed -i '/kube_kubeadm_apiserver_extra_args/d' roles/kubernetes/master/defaults/main/main.yml
cat << EOF >> roles/kubernetes/master/defaults/main/main.yml
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

sed -i "s/kube_version:.*/kube_version: v1.21.11/g" /root/kubespray/inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml

echo "alias oc='kubectl'" >> /root/.bashrc
echo "alias ocproject='kubectl config set-context --current --namespace'" >> /root/.bashrc
source /root/.bashrc

echo -e "${GREEN}Done!${NC} Kubespray initialized with default settings. You can review and change cluster parameters under:\ncat inventory/mycluster/group_vars/all/all.yml\ncat inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml"
echo -e "If everything looks fine run the playbook with ${BLUE}'source /root/.bashrc && cd /root/kubespray && ansible-playbook -i inventory/mycluster/hosts.yaml  --become --become-user=root cluster.yml'${NC}"
echo -e "This might take 10-15 minutes to complete. You can then run the next script to install the nfs-provisioner and the k8s-dashboard"
