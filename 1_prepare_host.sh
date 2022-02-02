#!/bin/bash

ARCH=`arch`
USER=`whoami`
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${ORANGE}Make sure these requirements are given: \n- Being root user \n- ppc64le architecture \n- RHEL/CentOS8 OS \n-CAUTION: THIS IS CURRENTLY DEVELOPED FOR IBM CECC - BE CAREFUL USING SOMEWHERE ELSE\nContinue?${NC}"

select choice in "Yes" "No"
do
    break
done

if test $REPLY == 2
then
    exit
fi

if test "${USER}" != "root"
then
    echo "Please start the installation as root user!"
    exit
fi

if test "${ARCH}" != "ppc64le"
then
    echo -e "This installation routine is intended for IBM Power Architecture.\nExiting..."
    exit
fi

echo -e "Checking SELinux..."

if test "$(cat /etc/selinux/config | grep "^SELINUX=" | cut -d '=' -f2)" != "disabled"
then
    echo "SELinux is not disabled! Please change this in /etc/selinux/config and reboot!"
    exit
fi

echo -e "Preparing host system..."
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm
dnf install -y @virt virt-install && systemctl enable --now libvirtd

#Patching qemu-kvm
if test -f "/usr/libexec/qemu-kvm.bin"
then
    echo -e "${GREEN}QEMU-kvm already patched - nothing to do here!${NC}"
else
    mv /usr/libexec/qemu-kvm /usr/libexec/qemu-kvm.bin
    wget https://ibm.box.com/shared/static/b4y3f56dz5ywrrg6sptp2mnsdy9kds32 -O /usr/libexec/qemu-kvm
    restorecon -vR /usr/libexec
    chmod +x /usr/libexec/qemu-kvm  
fi

echo -e "${ORANGE}This will install dhcp on the host and provide available IP addresses in the host net - IF YOU ARE NOT USING SYSTEMS IN IBM CECC YOU MUST DO THIS MANUALLY${NC}"

select choice in "I'm using IBM CECC systems (P8 / P9) - do this automatically for me" "I already installed DHCP and created a bridge based on my network conditions"
do
    break
done

if test $REPLY == 1
then

INTERFACE_NAME=$(ip a | grep -B2 $(hostname -i) | head -n1 | awk '{print $2}' | cut -d ':' -f1)
STARTRANGE="$(hostname -i)"
SUBNET="$(hostname -i | cut -d '.' -f1).$(hostname -i | cut -d '.' -f2).$(hostname -i | cut -d '.' -f3).$(expr $(hostname -i | cut -d '.' -f4) - 1)"
ENDRANGE="$(hostname -i | cut -d '.' -f1).$(hostname -i | cut -d '.' -f2).$(hostname -i | cut -d '.' -f3).$(expr $(hostname -i | cut -d '.' -f4) + 5)"
HOSTNM_SHORT=$(hostname -s | cut -d '-' -f1)
MAC_ADDR=$(ip a | grep -B1 $(hostname -i) | head -n1 | awk '{print $2}')

if test ${INTERFACE_NAME} == "bridge0"
then
    echo -e "${GREEN}Bridge network already exists - nothing to do here!${NC}"
else

cat << EOF > /etc/sysconfig/network-scripts/ifcfg-${INTERFACE_NAME}
# Created by cloud-init on instance boot automatically, do not edit.
#
DEVICE=${INTERFACE_NAME}
HWADDR=${MAC_ADDR}
MTU=1500
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
NAME="System ${INTERFACE_NAME}"
BRIDGE=bridge0
EOF

cat << EOF > /etc/sysconfig/network-scripts/ifcfg-bridge0
STP=no
TYPE=Bridge
PROXY_METHOD=none
BROWSER_ONLY=no
BOOTPROTO=none
IPADDR=${STARTRANGE}
PREFIX=29
GATEWAY=${ENDRANGE}
DNS1=129.40.242.1
DNS2=129.40.242.2
DOMAIN=${HOSTNM_SHORT}.cecc.ihost.com
DEFROUTE=yes
IPV4_FAILURE_FATAL=no
IPV6INIT=no
NAME=bridge0
DEVICE=bridge0
ONBOOT=yes
AUTOCONNECT_SLAVES=yes
EOF

systemctl restart NetworkManager

if [ -x "$(command -v docker)" ]; then
    echo "${GREEN}Detected docker, will configure iptables${NC}"
    iptables -I FORWARD -i bridge0 -o bridge0 -j ACCEPT
fi

fi

#DHCP settings for CECC
dnf install -y dhcp-server

cat << EOF > /etc/dhcp/dhcpd.conf
#
# DHCP Server Configuration file.
#   see /usr/share/doc/dhcp-server/dhcpd.conf.example
#   see dhcpd.conf(5) man page
#
max-lease-time 7200;
ddns-update-style none;
authoritative;
subnet ${SUBNET} netmask 255.255.255.248 {
range ${STARTRANGE} ${ENDRANGE};
option routers ${STARTRANGE};
option subnet-mask 255.255.255.248;
option domain-name-servers 129.40.242.1, 129.40.242.2;
}
EOF

systemctl enable --now dhcpd

# Download sample CentOS8.4 qcow2 image with default password "123456"

if test -f "/var/lib/libvirt/qcow2/node.qcow2"
then
    echo -e "${GREEN}CentOS image already exists. No need to download${NC}"
else
    mkdir -p /var/lib/libvirt/qcow2
    wget https://ibm.box.com/shared/static/ydj96baknh3fsj73f1qui6ofsxfj7ebz.qcow2 -O /var/lib/libvirt/qcow2/node.qcow2
    qemu-img resize /var/lib/libvirt/qcow2/node.qcow2 100G
fi

echo -e "${ORANGE}How many VMs do you want to create? (min 1, max 4)${NC}"
read number

while ((number < 1 || number > 4))
do
    echo -e "Not valid, value must be between 1 and 5\nNext try..."
    read number
done

for ((i=1;i<=number;i++))
do
if [ -f "/var/lib/libvirt/qcow2/node$i.qcow2" ]; then echo -e "${RED}Existing image 'node$i.qcow2' found at '/var/lib/libvirt/qcow2', please clean up any old environment!${NC}";exit; fi
done

echo -e "${GREEN}Will create $number VMs...${NC}"

echo "" > /var/lib/dhcpd/dhcpd.leases && systemctl restart dhcpd
rm -rf /root/.ssh/known_hosts
ip neigh flush all

for ((i=1;i<=number;i++))
do
    cp /var/lib/libvirt/qcow2/node.qcow2 /var/lib/libvirt/qcow2/node$i.qcow2
    echo -e "${GREEN}Installing VM $i...${NC}"
    virt-install --name node$i --memory 16384 --vcpus 16 --disk /var/lib/libvirt/qcow2/node$i.qcow2,bus=scsi,size=100 --import --os-variant centos8 --noautoconsole
done

fi

echo -e "${ORANGE}It might take up to 3 minutes until the VMs are up and got IPs${NC}"

IPS=""
for ((i=1;i<=number;i++))
do
    MAC=$(virsh domiflist node${i} | grep bridge | awk '{print $5}')
    while test "$(ip neigh | grep ${MAC})" == ""
    do
        echo -e "Wating until VM is up and got an IP assigned...\nSleeping 5 seconds..."
        sleep 5
    done
    echo -e "${GREEN}VM 'node$i' is up and running!${NC}"

    S_IP=$(ip neigh | grep $(virsh domiflist node$i | grep -i bridge | awk '{print $5}') | awk '{print $1}')
    if [ -z "$IPS" ]; then IPS="$S_IP"; else IPS="$IPS $S_IP"; fi
done

sed -i '/IPS=/d' /root/.bashrc 
echo "IPS=\"$IPS\"" >> /root/.bashrc

echo -e "${GREEN}Done! The IPs of your $number nodes are: $IPS${NC}"

dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm
dnf install -y sshpass

ITER=1
for i in ${IPS};
do
sshpass -p 123456 ssh-copy-id -o "StrictHostKeyChecking no" root@${i}
ssh -o StrictHostKeyChecking=no root@${i}  << EOF
echo IPS=\\"${IPS}\\" >> ~/.bashrc
echo node${ITER} > /proc/sys/kernel/hostname
growpart /dev/sda 2
xfs_growfs -d /
EOF
ITER=$(expr $ITER + 1)
done

#Enable passwordless SSH from the ansible/master host:
ssh -o StrictHostKeyChecking=no root@$(echo $IPS | cut -d ' ' -f1) << EOF
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm
dnf install -y sshpass pssh
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa <<< y
for i in \${IPS}
do
sshpass -p 123456 ssh-copy-id -o "StrictHostKeyChecking no" root@\${i}
done
EOF



echo -e "${GREEN}Done! You can copy the other scripts to the ansible/master node and then access it with with ${BLUE}'scp * root@$(echo $IPS | cut -d ' ' -f1):/root/ && ssh root@$(echo $IPS | cut -d ' ' -f1)${NC}'"
echo -e "${GREEN}Root password is ${BLUE}'123456'${NC}${GREEN}, however passwordless SSH access should be enabled${NC}"
