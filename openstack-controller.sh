#!/usr/bin/env bash
#
##########################################
# OpenStack for Quantum in Controller Node
# Date : 2013.01.28 
# Creater : NaleeJang
##########################################
# 
# 1. Common Services
#    1.1 Operating System
#        1.1.1 Install ubuntu-cloud-keyring
#        1.1.2 Configure the network
#        1.1.3 Install Configre NTP
#    1.2 MySql
#    1.3 RabbitMQ
#    1.4 Bridge-utils
# 2. Keystone
# 3. Glance
# 4. Nova
# 5. Cinder
# 6. Quantum
# 7. Horizon
##########################################

# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

source $TOP_DIR/openstackrc

# Settings
# ========
HOST_IP=${HOST_IP:-10.4.128.26}
HOST=${HOST:-localhost}
USER=${USER:-root}
PASSWORD=${PASSWORD:-superscrete}
TOKEN=${TOKEN:-mnlopenstacktoken}

# Root Account Check
if [ `whoami` != "root" ]; then
  echo "It must access root account"
	exit 1
fi

echo "============================"
echo "Install ubuntu-cloud-keyring"
echo "============================"
apt-get install ubuntu-cloud-keyring

cloud_archive=/etc/apt/sources.list.d/cloud-archive.list
if [ ! -e $cloud_archive ]; then
	touch $cloud_archive
fi

echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/folsom main" > $cloud_archive

apt-get update && apt-get upgrade -y

#------------------------------
# 1.1.2 Configure the network
#------------------------------
cp -p /etc/sysctl.conf /etc/sysctl-org.conf.back

echo "net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.conf

service networking restart

#------------------------------
# 1.1.3 Install Configre NTP
#------------------------------
echo "Install Configure NTP"
# install time server
apt-get install -y ntp

# modify timeserver configuration
sed -e "
/^server ntp.ubuntu.com/i server 127.127.1.0
/^server ntp.ubuntu.com/i fudge 127.127.1.0 stratum 10
/^server ntp.ubuntu.com/s/^.*$/server ntp.ubutu.com iburst/;
" -i /etc/ntp.conf

# restart ntp server
service ntp restart

#----------------------
#    1.2 MySql
#----------------------


# Install MySQL
# ================

echo "==============="
echo " Install MySQL"
echo "==============="

# Seed configuration with mysql password so that apt-get install doesn't
# prompt us for a password upon install.
cat <<MYSQL_PRESEED | sudo debconf-set-selections
mysql-server-5.1 mysql-server/root_password password $PASSWORD
mysql-server-5.1 mysql-server/root_password_again password $PASSWORD
mysql-server-5.1 mysql-server/start_on_boot boolean true
MYSQL_PRESEED

# while ``.my.cnf`` is not needed for OpenStack to function, it is useful
# as it allows you to access the mysql databases via ``mysql nova`` instead
# of having to specify the username/password each time.
if [[ ! -e $HOME/.my.cnf ]]; then
    cat <<EOF >$HOME/.my.cnf
[client]
user=$USER
password=$PASSWORD
host=$HOST
EOF
    chmod 0600 $HOME/.my.cnf
fi

# Install mysql-server
apt-get install -y mysql-server python-mysqldb

# Configuring Mysql
# ==================

echo "==============================="
echo "Configuring and starting MySQL"
echo "==============================="
MY_CONF=/etc/mysql/my.cnf
MYSQL=mysql

# Update the DB to give user $MYSQL_USER full control of the all databases:
mysql -uroot -p$PASSWORD -h127.0.0.1 -e "GRANT ALL PRIVILEGES ON *.* TO '$USER'@'%' identified by '$PASSWORD';"


# Now update ``my.cnf`` for some local needs and restart the mysql service

# Change bind-address from localhost (127.0.0.1) to any (0.0.0.0)
sed -i '/^bind-address/s/127.0.0.1/0.0.0.0/g' $MY_CONF

# Set default db type to InnoDB
if sudo grep -q "default-storage-engine" $MY_CONF; then
    # Change it
    sed -i -e "/^\[mysqld\]/,/^\[.*\]/ s|^\(default-storage-engine[ \t]*=[ \t]*\).*$|\1InnoDB|" "$MY_CONF"
else
    # Add it
    sed -i -e "/^\[mysqld\]/ a \
default-storage-engine = InnoDB" $MY_CONF
fi

# Restart MySQL
echo "Restring MySQL"
/usr/sbin/service mysql restart

mysql -uroot -p$PASSWORD -h127.0.0.1 <<EOF
DROP DATABASE IF EXISTS nova;
CREATE DATABASE nova;
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$PASSWORD';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$PASSWORD';
DROP DATABASE IF EXISTS glance;
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$PASSWORD';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$PASSWORD';
DROP DATABASE IF EXISTS keystone;
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$PASSWORD';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$PASSWORD';
DROP DATABASE IF EXISTS cinder;
CREATE DATABASE cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$PASSWORD';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$PASSWORD';
DROP DATABASE IF EXISTS quantum;
CREATE DATABASE quantum;
GRANT ALL PRIVILEGES ON quantum.* TO 'quantum'@'%' IDENTIFIED BY '$PASSWORD';
GRANT ALL PRIVILEGES ON quantum.* TO 'quantum'@'localhost' IDENTIFIED BY '$PASSWORD';
EOF

echo "Done Install MySQL"

#--------------------------
# 1.3 Install RabbitMQ-Server
#--------------------------
echo "========================"
echo "Install rabbitmq-server"
echo "========================"
apt-get install -y rabbitmq-server
rabbitmqctl change_password guest $PASSWORD

#--------------------------
# 1.4 Install Bridge-utils
#--------------------------
echo "========================"
echo "Install bridge-utils"
echo "========================"
apt-get install vlan bridge-utils
sysctl net.ipv4.ip_forward=1

#-----------------
# 2. Keystone
#-----------------

echo "=================="
echo "Install Keystone"
echo "=================="
apt-get install -y keystone python-keystone python-keystoneclient

# edit keystone conf file to use templates and mysql
cp -p /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
sed -e "
/^# admin_token = ADMIN/s/^.*$/admin_token = $TOKEN/
/^# bind_host = 0.0.0.0/s/^.*$/bind_host = 0.0.0.0/
/^# public_port = 5000/s/^.*$/public_port = 5000/
/^# admin_port = 35357/s/^.*$/admin_port = 35357/
/^# compute_port = 8774/s/^.*$/compute_port = 8774/
/^# verbose = False/s/^.*$/verbose = True/
/^# debug = False/s/^.*$/debug = True/
/^connection =.*$/s/^.*$/connection = mysql:\/\/keystone:$PASSWORD@$HOST_IP\/keystone/
" -i /etc/keystone/keystone.conf

service keystone restart
keystone-manage db_sync

sleep 1

# Set up env variables for testing
cat > $TOP_DIR/novarc <<EOF
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$PASSWORD
export OS_AUTH_URL="http://$HOST_IP:5000/v2.0/" 
export ADMIN_PASSWORD=$PASSWORD
export SERVICE_PASSWORD=$PASSWORD
export SERVICE_TOKEN=$TOKEN
export SERVICE_ENDPOINT="http://$HOST_IP:35357/v2.0"
EOF

. ./novarc


# Tenant, User, Servie, Endpoint Create
./keystone-data.sh

#------------
# 3. Glance
#------------

echo "================"
echo "Install Glance"
echo "================"
apt-get install -y glance glance-api python-glanceclient glance-common

# Edit glance-api.conf
cp -p /etc/glance/glance-api.conf /etc/glance/glance-api.conf.orig
sed -e "
/^sql_connection =.*$/s/^.*$/sql_connection = mysql:\/\/glance:$PASSWORD@$HOST_IP\/glance/
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = glance/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
/^notifier_strategy = noop/s/^.*$/notifier_strategy = rabbit/
/^rabbit_password = guest/s/^.*$/rabbit_password = $PASSWORD/
" -i /etc/glance/glance-api.conf

# Edit glance-registry.conf
cp -p /etc/glance/glance-registry.conf /etc/glance/glance-registry.conf.orig
sed -e "
/^sql_connection =.*$/s/^.*$/sql_connection = mysql:\/\/glance:$PASSWORD@$HOST_IP\/glance/
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = glance/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
" -i /etc/glance/glance-registry.conf

# Restart Glance 
service glance-api restart && service glance-registry restart

# Create Glance tables
glance-manage db_sync

# Upload Ubuntu OS Image to Glance
glance image-create \
--location http://uec-images.ubuntu.com/releases/12.04/release/ubuntu-12.04-server-cloudimg-amd64-disk1.img \
--is-public true --disk-format qcow2 --container-format bare --name "Ubuntu 12.04"

glance image-list

#-----------------
# 4. Nova
#-----------------

echo "============="
echo "Install Nova"
echo "============="
apt-get install -y nova-api nova-cert nova-common \
nova-scheduler python-nova python-novaclient nova-consoleauth novnc \
nova-novncproxy


# Edit /etc/nova/api-paste.ini
echo "Configure Nova"
cp -p /etc/nova/api-paste.ini /etc/nova/api-paste.ini.orig
sed -e "
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = nova/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
" -i /etc/nova/api-paste.ini

# Create nova.conf
NOVA_CONF=/etc/nova/nova.conf
if [[ -r $NOVA_CONF.orig ]]; then
	rm $NOVA_CONF.orig
fi
mv $NOVA_CONF $NOVA_CONF.orig

echo "[DEFAULT]

# MySQL Connection #
sql_connection=mysql://nova:$PASSWORD@$HOST_IP/nova

# nova-scheduler #
rabbit_password=$PASSWORD
scheduler_driver=nova.scheduler.simple.SimpleScheduler

# nova-api #
cc_host=$HOST_IP
auth_strategy=keystone
s3_host=$HOST_IP
ec2_host=$HOST_IP
nova_url=http://$HOST_IP:8774/v1.1/
ec2_url=http://$HOST_IP:8773/services/Cloud
keystone_ec2_url=http://$HOST_IP:5000/v2.0/ec2tokens
api_paste_config=/etc/nova/api-paste.ini
allow_admin_api=true
use_deprecated_auth=false
ec2_private_dns_show_ip=True
dmz_cidr=169.254.169.254/32
ec2_dmz_host=$HOST_IP
metadata_host=$HOST_IP
metadata_listen=0.0.0.0
enabled_apis=ec2,osapi_compute,metadata

# Networking #
network_api_class=nova.network.quantumv2.api.API
quantum_url=http://$HOST_IP:9696
quantum_auth_strategy=keystone
quantum_admin_tenant_name=service
quantum_admin_username=quantum
quantum_admin_password=$PASSWORD
quantum_admin_auth_url=http://$HOST_IP:35357/v2.0
libvirt_vif_driver=nova.virt.libvirt.vif.LibvirtHybridOVSBridgeDriver
linuxnet_interface_driver=nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver=nova.virt.libvirt.firewall.IptablesFirewallDriver

# Cinder #
volume_api_class=nova.volume.cinder.API
osapi_volume_listen_port=5900

# Glance #
glance_api_servers=$HOST_IP:9292
image_service=nova.image.glance.GlanceImageService

# novnc #
novnc_enable=true
novncproxy_base_url=http://$HOST_IP:6080/vnc_auto.html
vncserver_proxyclient_address=127.0.0.1
vncserver_listen=0.0.0.0

# Misc #
logdir=/var/log/nova
state_path=/var/lib/nova
lock_path=/var/lock/nova
root_helper=sudo nova-rootwrap /etc/nova/rootwrap.conf
verbose=true
" > $NOVA_CONF

# Create Nova tables
echo "DB sync"
nova-manage db sync

# Restart Nova services
echo "Restart Nova Service"
service nova-api restart
service nova-cert restart
service nova-consoleauth restart
service nova-scheduler restart
service nova-novncproxy restart

sleep 1
nova-manage service list

#-----------------
# 5. Cinder
#-----------------

echo "=============="
echo "Install Cinder"
echo "=============="
apt-get install -y cinder-api cinder-scheduler cinder-volume iscsitarget \
open-iscsi iscsitarget-dkms python-cinderclient linux-headers-`uname -r`

# Edit targets.conf
sed -e "
/^include /etc/tgt/conf.d/*.conf/s/^.*$/include /etc/tgt/conf.d/cinder_tgt.conf/
" -i /etc/tgt/targets.conf

# Configure iscsi services
sed -i 's/false/true/g' /etc/default/iscsitarget

# start the iscsi services
service iscsitarget start
service open-iscsi start

# Edit cinder.conf
cp -p /etc/cinder/cinder.conf /etc/cinder/cinder.conf.orig
if ! egrep sql_connection /etc/cinder/cinder.conf; then
	sed -e "
/^\[DEFAULT\]/a sql_connection = mysql://cinder:$PASSWORD@$HOST_IP:3306/cinder
/^\[DEFAULT\]/a rabbit_password = $PASSWORD
" -i /etc/cinder/cinder.conf
fi

# Edit api-paste.ini
cp -p /etc/cinder/api-paste.ini /etc/cinder/api-paste.ini.orig
sed -e "
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = cinder/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
" -i /etc/cinder/api-paste.ini

# Create cinder-volumes
VOLUME_NAME=cinder-volume
CINDER_BACKING_FILE=/var/lib/cinder/volumes/cinder-volume-backing-file

if [ ! -d $CINDER_BACKING_FILE ]; then
	touch $CINDER_BACKING_FILE
fi
if ! vgs $VOLUME_NAME; then
	truncate -s 103000M $CINDER_BACKING_FILE
	DEV=`losetup -f --show $CINDER_BACKING_FILE`
	if ! vgs $VOLUME_NAME; then vgcreate $VOLUME_NAME $DEV; fi
fi

if ! vgs $VOLUME_NAME; then
	exit 1
fi

# Create Cinder table
cinder-manage db sync

# Restart Service
service cinder-api restart
service cinder-scheduler restart
service cinder-volume restart

#-----------------
# 6. Quantum
#-----------------

echo "================"
echo "Install Quantum"
echo "================"
apt-get install -y quantum-server quantum-plugin-openvswitch

# Edit quantum.conf
cp -p /etc/quantum/quantum.conf /etc/quantum/quantum.conf.orig
sed -e "
/^# auth_strategy = keystone/s/^.*$/auth_strategy = keystone/
/^# fake_rabbit = False/s/^.*$/fake_rabbit = False/
/^# rabbit_password = guest/s/^.*$/rabbit_password = $PASSWORD/
" -i /etc/quantum/quantum.conf

# Edit ovs_quantum_plugin.ini
cp -p /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini.orig
sed -e "
/^sql_connection =.*$/s/^.*$/sql_connection = mysql:\/\/quantum:$PASSWORD@$HOST_IP\/quantum/
/^\[OVS\]/a tenant_network_type = gre
/^\[OVS\]/a tunnel_id_ranges = 1:1000
/^\[OVS\]/a enable_tunneling = True
" -i /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini

# Edit api-paste.ini
cp -p /etc/quantum/api-paste.ini /etc/quantum/api-paste.ini.orig
sed -e "
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = quantum/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
" -i /etc/quantum/api-paste.ini

# Start the service
service quantum-server restart


#-----------------
# 7. Horizon
#-----------------

echo "================"
echo "Install Horizon"
echo "================"
apt-get install -y apache2 libapache2-mod-wsgi openstack-dashboard \
memcached python-memcache

sed -e "
/^try:/s/^.*$/#try:/
/^    from ubuntu_theme import */s/^.*$/#    from ubuntu_theme import */
/^except ImportError:/s/^.*$/#except ImportError:/
/^    pass/s/^.*$/#    pass/
" -i /etc/openstack-dashboard/local_settings.py

service apache2 restart; service memcached restart

echo "========================================"
echo " Done Install Openstack Controller Node "
echo "========================================"
echo " Horizon URL : http://$HOST_IP/horizon"
echo " User ID/PW : admin / $PASSWORD "
