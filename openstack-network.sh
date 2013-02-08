#!/usr/bin/env bash
#
##########################################
# OpenStack for Quantum in Network Node
# Date : 2013.01.28 
# Creater : NaleeJang
# Company : MNL Solution R&D Center
##########################################
#
# 1. Common Services
#    1.1 Operating System
#        1.1.1 Install ubuntu-cloud-keyring
#        1.1.2 Configure the network
#        1.1.3 Install Configre NTP
# 2. Network Services
#    2.1 Open-vSwitch
#    2.2 Quantum
# 3. Virtual Networking
#    3.1 Create Virtual Networking
#    3.2 L3 Configuration
##########################################

# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

source $TOP_DIR/openstackrc

# Settings
# ========
CONTROLER_IP=${CONTROLER_IP:-10.4.128.26}
HOST_IP=${HOST_IP:-10.4.128.27}
USER=${USER:-root}
PASSWORD=${PASSWORD:-superscrete}
TOKEN=${TOKEN:-mnlopenstacktoken}

# Root Account Check
if [ `whoami` != "root" ]; then
  echo "It must access root account"
	exit 1
fi

echo "===================================="
echo " 1.1.1 Install ubuntu-cloud-keyring"
echo "===================================="
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

apt-get install vlan bridge-utils

cp -p /etc/sysctl.conf /etc/sysctl-org.conf.back

echo "net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0" > /etc/sysctl.conf

sysctl net.ipv4.ip_forward=1
#service networking restart

#------------------------------
# 1.1.3 Install Configre NTP
#------------------------------
echo "Install Configure NTP"
# install time server
apt-get install -y ntp

# modify timeserver configuration
cp -p /etc/ntp.conf /etc/ntp.conf.orig
echo "server $CONTROLER_IP" > /etc/ntp.conf

# restart ntp server
service ntp restart

#----------------------
# 2.1 Open-vSwitch
#----------------------

echo "====================="
echo " Install OpenVswitch"
echo "====================="
kernel_version=`cat /proc/version | cut -d " " -f3`
apt-get install -y make fakeroot dkms openvswitch-switch openvswitch-datapath-dkms linux-headers-$kernel_version

# Start Open vSwitch
service openvswitch-switch start

# Create Virtual Bridging
ovs-vsctl add-br br-int
ovs-vsctl add-br br-ex
ovs-vsctl br-set-external-id br-ex bridge-id br-ex
ovs-vsctl add-port br-ex eth1
ip link set up br-ex

#-----------------
# 2.2 Quantum
#-----------------

echo "=================="
echo " Install Quantum"
echo "=================="
apt-get install -y quantum-dhcp-agent quantum-l3-agent quantum-plugin-openvswitch-agent

# Edit l3_agent.ini
cp -p /etc/quantum/l3_agent.ini /etc/quantum/l3_agent.ini.orig
sed -e "
/^auth_url =.*$/s/^.*$/auth_url = http:\/\/$CONTROLER_IP:35357\/v2.0/
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = quantum/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
/^metadata_ip =.*$/s/^.*$/metadata_ip = $CONTROLER_IP/
/^use_namespaces =.*$/s/^.*$/use_namespaces = False/
" -i /etc/quantum/l3_agent.ini

# Edit api-paste.ini
cp -p /etc/quantum/api-paste.ini /etc/quantum/api-paste.ini.orig
sed -e "
/^auth_host = 127.0.0.1/s/^.*$/auth_host = $CONTROLER_IP/
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = quantum/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
" -i /etc/quantum/api-paste.ini

# Edit quantum.conf
cp -p /etc/quantum/quantum.conf /etc/quantum/quantum.conf.orig
sed -e "
/^# auth_strategy = keystone/s/^.*$/auth_strategy = keystone/
/^# fake_rabbit = False/s/^.*$/fake_rabbit = False/
/^# rabbit_host = localhost/s/^.*$/rabbit_host = $CONTROLER_IP/
/^# rabbit_password = guest/s/^.*$/rabbit_password = $PASSWORD/
" -i /etc/quantum/quantum.conf

# Edit ovs_quantum_plugin.ini
cp -p /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini.orig
sed -e "
/^sql_connection =.*$/s/^.*$/sql_connection = mysql:\/\/quantum:$PASSWORD@$CONTROLER_IP:3306\/quantum/
/^\[OVS\]/a tenant_network_type = gre
/^\[OVS\]/a tunnel_id_ranges = 1:1000
/^\[OVS\]/a integration_bridge = br-int
/^\[OVS\]/a tunnel_bridge = br-tun
/^\[OVS\]/a local_ip = $HOST_IP
/^\[OVS\]/a enable_tunneling = True
" -i /etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini

# Edit dhcp_agent.ini
cp -p /etc/quantum/dhcp_agent.ini /etc/quantum/dhcp_agent.ini.orig
echo "use_namespaces = False" >> /etc/quantum/dhcp_agent.ini

# Start the service
service quantum-dhcp-agent restart
service quantum-l3-agent restart
service quantum-plugin-openvswitch-agent restart

# Set up env variables for testing
cat > $TOP_DIR/novarc <<EOF
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$PASSWORD
export OS_AUTH_URL="http://$CONTROLER_IP:5000/v2.0/" 
export ADMIN_PASSWORD=$PASSWORD
export SERVICE_PASSWORD=$PASSWORD
export SERVICE_TOKEN=$TOKEN
export SERVICE_ENDPOINT="http://$CONTROLER_IP:35357/v2.0"
EOF

. ./novarc

./quantum-networking.sh

 
service quantum-l3-agent restart
