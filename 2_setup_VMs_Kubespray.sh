
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
    sed -i '/IPS=/d' ${HOME}/.bashrc 
    echo "IPS=\"$IPS\"" >> ${HOME}/.bashrc
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

#check for firewall - this does not end the script if an active firewall is found!
echo -e "Check if firewall daemon is active and open ports"
for i in $IPS
do
ssh root@$i 'if [ `systemctl is-active firewalld` = "active" ]; then firewall-cmd --permanent --add-port=6443/tcp \
   && firewall-cmd --permanent --add-port=2379-2380/tcp \
   && firewall-cmd --permanent --add-port=10250/tcp \
   && firewall-cmd --permanent --add-port=10251/tcp \
   && firewall-cmd --permanent --add-port=10252/tcp \
   && firewall-cmd --permanent --add-port=10255/tcp \
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
ssh root@$i "dnf install iptables -y && iptables -P FORWARD ACCEPT && mkdir -p /root/.docker"
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
mkdir -p /export && chown -R nobody: /export
dnf install nfs-utils -y && systemctl enable --now nfs-server.service

#This is insecure and should be fixed by changing database permissions inside the container (e.g. MySQL) and then set to 'root_squash'...
sed -i '/\/export/d' /etc/exports
echo "/export *(rw,sync,no_root_squash)" >> /etc/exports
exportfs -a
#################
fi

rm -rf /opt/kubespray
git clone -b v2.19.0 https://github.com/kubernetes-sigs/kubespray.git /opt/kubespray && cd /opt/kubespray

## Only on Ansible/Master node:
if ! command -v ansible &> /dev/null
then
    dnf install wget git python3-netaddr -y
    cd ${HOME}
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-$(uname -m).sh && bash Miniconda3-latest-Linux-$(uname -m).sh -b
    rm -rf Miniconda3-latest*.sh
    export PATH="${HOME}/miniconda3/bin:${PATH}"
    conda create --name py38 python=3.8 -y
    conda init bash
    echo "conda activate py38" >> ${HOME}/.bashrc
    source ${HOME}/.bashrc

    conda install -y cryptography=2.8 jinja2=2.11.3 pbr=5.4.4 ruamel.yaml.clib=0.2.6 pyyaml=6.0 MarkupSafe=1.1.1
    cd /opt/kubespray && pip3 install -r requirements-2.9.txt 
fi

#yq used to replace containerd while it is not officially released for ppc (will come with 1.7.0)
wget https://github.com/mikefarah/yq/releases/download/v4.26.1/yq_linux_ppc64le -O /usr/bin/yq && chmod +x /usr/bin/yq
yq -i '.containerd_version = "1.7.0-alpha.ppctest"' roles/download/defaults/main.yml
yq -i '.containerd_download_url = "https://github.com/dmcgowan/containerd/releases/download/v{{ containerd_version }}/containerd-{{ containerd_version }}-linux-{{ image_arch }}.tar.gz"' roles/download/defaults/main.yml
yq -i '.containerd_archive_checksums.ppc64le += {"1.7.0-alpha.ppctest": "d9e84c97f48f57e7d8ca38741af078951da4e36c88f17e2835e0fb982f4968bc"}' roles/download/defaults/main.yml


sed -i "s/kube_version: .*/kube_version: v1.21.11/g" inventory/sample/group_vars/k8s_cluster/k8s-cluster.yml
sed -i "s/kube_version: .*/kube_version: v1.21.11/g" roles/kubespray-defaults/defaults/main.yaml

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

