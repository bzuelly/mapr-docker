#!/bin/bash

# Disable SELINUX
sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0

yum -y install wget screen createrepo bc epel-release jq
yum -y install sshpass

###install docker required packages
sudo yum -y install yum-utils device-mapper-persistent-data lvm2

sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

sudo yum -y install docker-ce
sudo systemctl enable docker && sudo systemctl start docker

# Download desired MapR Core and MEP versions
# build_all_versions will build docker images for every combination of Core and MEP
curl -O http://package.mapr.com/releases/MEP/MEP-6.2.0/redhat/mapr-mep-v6.2.0.201905272218.rpm.tgz
curl -O http://package.mapr.com/releases/v6.1.0/redhat/mapr-v6.1.0GA.rpm.tgz



#remove versions folder
rm -rf versions/*

#SYSCTLFILE=/usr/lib/sysctl.d/60-aml-mapr-docker.conf
SYSCTLFILE=/etc/sysctl.conf
echo '# With more than mapr docker nodes, mfs.log-3 starts showing' >> $SYSCTLFILE
echo '# ERROR IOMgr iodispatch.cc:117 io-setup failed, -11' >> $SYSCTLFILE
echo '# Increment 8x from 256K to 2M' >> $SYSCTLFILE
echo 'fs.aio-max-nr = 2097152' >> $SYSCTLFILE
sudo sysctl -p $SYSCTLFILE

# AMI should have /dev/xvdz or /dev/sdz available for /var/lib/docker
# If docker volumes are used rather than block devices for docker instances, the 
# docker volumes will be in /var/lib/docker/...

BLOCKDEV=$(ls /dev/*dz)
if [[ -b $BLOCKDEV ]]; then
  mkfs -t xfs $BLOCKDEV
  mkdir /var/lib/docker
  bash -c "echo '$BLOCKDEV /var/lib/docker xfs defaults 0 0' >> /etc/fstab"
  mount -a
  chmod 755 /var/lib/docker 
fi


sed -i -e "s/^OPTIONS='--selinux-enabled /OPTIONS='/" /etc/sysconfig/docker

./build_all_versions.sh 2>&1 | tee build_all_versions.out

