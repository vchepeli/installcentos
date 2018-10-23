#!/bin/bash

## Default variables to use
INTERACTIVE=${INTERACTIVE:="true"}
PVS=${PVS:="true"}
DOMAIN=${DOMAIN:="$(hostname -f)"}
USERNAME=${USERNAME:="$(whoami)"}
PASSWORD=${PASSWORD:=p@ssw0rd}
VERSION=${VERSION:="3.10"}
IP=${IP:="$(ip route get 8.8.8.8 | awk '{print $NF; exit}')"}
API_PORT=${API_PORT:="8443"}

## Make the script interactive to set the variables
if [ "${INTERACTIVE}" = "true" ]; then
	read -rp "Domain to use: ($DOMAIN): " choice;
	if [ "$choice" != "" ] ; then
	    DOMAIN="$choice";
	fi

	read -rp "Username: ($USERNAME): " choice;
	if [ "$choice" != "" ] ; then
	    USERNAME="$choice";
	fi

	read -rp "Password: ($PASSWORD): " choice;
	if [ "$choice" != "" ] ; then
	    PASSWORD="$choice";
	fi

	read -rp "OpenShift Version: ($VERSION): " choice;
	if [ "$choice" != "" ] ; then
	    VERSION="$choice";
	fi
	read -rp "IP: ($IP): " choice;
	if [ "$choice" != "" ] ; then
	    IP="$choice";
	fi

	read -rp "API Port: ($API_PORT): " choice;
	if [ "$choice" != "" ] ; then
	    API_PORT="$choice";
	fi 

	echo
fi

echo "******"
echo "* Your domain is ${DOMAIN} "
echo "* Your IP is ${IP} "
echo "* Your username is ${USERNAME} "
echo "* Your password is ${PASSWORD} "
echo "* OpenShift version: ${VERSION} "
echo "******"

# install updates
yum update -y

# install the following base packages
yum install -y  yum-utils yum-plugin-versionlock wget git nano net-tools docker-1.13.1\
				bind-utils iptables-services \
				bridge-utils bash-completion \
				kexec-tools sos psacct openssl-devel \
				httpd-tools NetworkManager \
				python-cryptography python-devel python-passlib \
				java-1.8.0-openjdk-headless "@Development Tools"

#install epel
yum -y install epel-release

# Disable the EPEL repository globally so that is not accidentally used during later steps of the installation
yum-config-manager --disable epel

systemctl | grep "NetworkManager.*running" 
if [ $? -eq 1 ]; then
	systemctl start NetworkManager
	systemctl enable NetworkManager
fi

# install the packages for Ansible
yum -y --enablerepo=epel install pyOpenSSL zile python2-pip
curl -o ansible-2.6.5.rpm https://releases.ansible.com/ansible/rpm/release/epel-7-x86_64/ansible-2.6.5-1.el7.ans.noarch.rpm
yum -y localinstall ansible-2.6.5.rpm
yum versionlock ansible

[ ! -d openshift-ansible ] && git clone https://github.com/openshift/openshift-ansible.git
cd openshift-ansible && git fetch && git checkout release-${VERSION} && cd ..

cat <<EOD > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
${IP}		$(hostname) ${DOMAIN}
EOD

if [ -z ${DISK} ]; then
	echo "Not setting the Docker storage."
else
	cp /etc/sysconfig/docker-storage-setup /etc/sysconfig/docker-storage-setup.bk

	echo DEVS=${DISK} > /etc/sysconfig/docker-storage-setup
	echo VG=DOCKER >> /etc/sysconfig/docker-storage-setup
	echo SETUP_LVM_THIN_POOL=yes >> /etc/sysconfig/docker-storage-setup
	echo DATA_SIZE="100%FREE" >> /etc/sysconfig/docker-storage-setup

	systemctl stop docker

	rm -rf /var/lib/docker
	wipefs --all ${DISK}
	docker-storage-setup
fi

systemctl restart docker
systemctl enable docker

if [ ! -f ~/.ssh/id_rsa ]; then
	ssh-keygen -q -f ~/.ssh/id_rsa -N ""
	cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
	ssh -o StrictHostKeyChecking=no root@$IP "pwd" < /dev/null
fi

METRICS="True"
LOGGING="True"

memory=$(cat /proc/meminfo | grep MemTotal | sed "s/MemTotal:[ ]*\([0-9]*\) kB/\1/")

if [ "$memory" -lt "4194304" ]; then
	METRICS="False"
fi

if [ "$memory" -lt "16777216" ]; then
	LOGGING="False"
fi

export DOMAIN VERSION IP API_PORT METRICS LOGGING
envsubst \$DOMAIN,\$VERSION,\$IP,\$API_PORT,\$METRICS,\$LOGGING < inventory.ini > inventory.env

# add proxy in inventory.ini if proxy variables are set
if [ ! -z "${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy}}}}" ]; then
	echo >> inventory.env
	echo "openshift_http_proxy=\"${HTTP_PROXY:-${http_proxy:-${HTTPS_PROXY:-${https_proxy}}}}\"" >> inventory.env
	echo "openshift_https_proxy=\"${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy}}}}\"" >> inventory.env
	if [ ! -z "${NO_PROXY:-${no_proxy}}" ]; then
		__no_proxy="${NO_PROXY:-${no_proxy}},${IP},.${DOMAIN}"
	else
		__no_proxy="${IP},.${DOMAIN}"
	fi
	echo "openshift_no_proxy=\"${__no_proxy}\"" >> inventory.env
fi

mkdir -p /etc/origin/master/
touch /etc/origin/master/htpasswd

ansible-playbook -i inventory.env openshift-ansible/playbooks/prerequisites.yml
ansible-playbook -i inventory.env openshift-ansible/playbooks/deploy_cluster.yml

htpasswd -b /etc/origin/master/htpasswd ${USERNAME} ${PASSWORD}
oc adm policy add-cluster-role-to-user cluster-admin ${USERNAME}

if [ "${PVS}" = "true" ]; then
	for i in $(seq 1 100);
	do
		VOL_NAME=vol${i}
		VOL_DIR=/mnt/data/${VOL_NAME}
		mkdir -p ${VOL_DIR}
		chcon -Rt svirt_sandbox_file_t ${VOL_DIR}
		chmod 777 ${VOL_DIR}

        export VOL_NAME VOL_DIR
		envsubst \$VOL_NAME,\$VOL_DIR < vol.yml > vol_env.yml
		oc create -f vol_env.yml
		echo "created volume $i"
	done
	rm vol_env.yml
fi

echo "******"
echo "* Your console is https://${DOMAIN}:${API_PORT}"
echo "* Your username is ${USERNAME} "
echo "* Your password is ${PASSWORD} "
echo "*"
echo "* Login using:"
echo "*"
echo "$ oc login -u ${USERNAME} -p ${PASSWORD} https://${DOMAIN}:${API_PORT}/"
echo "******"

oc login -u ${USERNAME} -p ${PASSWORD} https://${DOMAIN}:${API_PORT}/