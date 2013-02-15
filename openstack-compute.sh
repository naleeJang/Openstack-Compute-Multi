#!/usr/bin/env bash
#
##########################################
# OpenStack for Quantum in Compute Node
# Date : 2013.01.28 
# Creater : NaleeJang
##########################################
#
# 1. Common Services
#    1.1 Operating System
#        1.1.1 Install ubuntu-cloud-keyring
#        1.1.2 Configure the network
#        1.1.3 Install Configre NTP   
# 2. Hypervisor
# 3. Nova
# 4. Quantum
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
net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.conf

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


#-------------------
# 2. Hypervisor
#-------------------

echo "===================================="
echo " Install KVM package for Hypervisor "
echo "===================================="
apt-get install -y kvm libvirt-bin pm-utils

# Edit qemu.conf
cp -p /etc/libvirt/qemu.conf /etc/libvirt/qemu.conf.orig
cat <<EOF | sudo tee -a /etc/libvirt/qemu.conf
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm", "/dev/kqemu",
    "/dev/rtc", "/dev/hpet","/dev/net/tun",
]
EOF

# Disable KVM default virtual bridge
virsh net-destroy default
virsh net-undefine default

# Edit libvirtd.conf
cp -p /etc/libvirt/libvirtd.conf /etc/libvirt/libvirtd.conf.orig
# Set up env variables for testing
cat > /etc/libvirt/libvirtd.conf <<EOF
listen_tls = 0
listen_tcp = 1
auth_tcp = "none"
EOF

# Edit libvirt-bin.conf
cp -p /etc/init/libvirt-bin.conf /etc/init/libvirt-bin.conf.orig
sed -e "
/^env libvirtd_opts=.*$/s/^.*$/env libvirtd_opts=\"-d -l\"/
" -i /etc/init/libvirt-bin.conf

# Edit libvirt-bin
cp -p /etc/default/libvirt-bin /etc/default/libvirt-bin.orig
sed -e "
/^env libvirtd_opts=.*$/s/^.*$/env libvirtd_opts=\"-d -l\"/
" -i /etc/init/libvirt-bin.conf

service libvirt-bin restart

LIBVIRT_TYPE=kvm
modprobe kvm || true
if [ ! -e /dev/kvm ]; then
    echo "WARNING: Switching to QEMU"
    LIBVIRT_TYPE=qemu
    if which selinuxenabled 2>&1 > /dev/null && selinuxenabled; then
        # https://bugzilla.redhat.com/show_bug.cgi?id=753589
        sudo setsebool virt_use_execmem on
    fi
fi

#-------------------
# 3. Nova
#-------------------

echo "============="
echo "Install Nova"
echo "============="
apt-get install -y nova-compute-kvm


# Edit /etc/nova/api-paste.ini
echo "Configure Nova"
cp -p /etc/nova/api-paste.ini /etc/nova/api-paste.ini.orig
sed -e "
/^auth_host = 127.0.0.1/s/^.*$/auth_host = $CONTROLER_IP/
/^admin_tenant_name = %SERVICE_TENANT_NAME%/s/^.*$/admin_tenant_name = service/
/^admin_user = %SERVICE_USER%/s/^.*$/admin_user = nova/
/^admin_password = %SERVICE_PASSWORD%/s/^.*$/admin_password = $PASSWORD/
" -i /etc/nova/api-paste.ini


# Edit /etc/nova/nova-compute.conf
echo "Configure Nova"
cp -p /etc/nova/nova-compute.conf /etc/nova/nova-compute.conf.orig
sed -e "
/^\[DEFAULT\]/libvirt_type=$LIBVIRT_TYPE
/^\[DEFAULT\]/libvirt_ovs_bridge=br-int
/^\[DEFAULT\]/libvirt_vif_type=ethernet
/^\[DEFAULT\]/libvirt_vif_driver=nova.virt.libvirt.vif.LibvirtHybridOVSBridgeDriver
/^\[DEFAULT\]/libvirt_use_virtio_for_bridges=True
" -i /etc/nova/nova-compute.conf

# Create nova.conf
NOVA_CONF=/etc/nova/nova.conf
if [[ -r $NOVA_CONF.orig ]]; then
	rm $NOVA_CONF.orig
fi
mv $NOVA_CONF $NOVA_CONF.orig

echo "[DEFAULT]

# MySQL Connection #
sql_connection=mysql://nova:$PASSWORD@$CONTROLER_IP/nova

# nova-scheduler #
rabbit_host=$CONTROLER_IP
rabbit_password=$PASSWORD
scheduler_driver=nova.scheduler.simple.SimpleScheduler

# nova-api #
cc_host=$CONTROLER_IP
auth_strategy=keystone
s3_host=$CONTROLER_IP
ec2_host=$CONTROLER_IP
nova_url=http://$CONTROLER_IP:8774/v1.1/
ec2_url=http://$CONTROLER_IP:8773/services/Cloud
keystone_ec2_url=http://$CONTROLER_IP:5000/v2.0/ec2tokens
api_paste_config=/etc/nova/api-paste.ini
allow_admin_api=true
use_deprecated_auth=false
ec2_private_dns_show_ip=True
dmz_cidr=169.254.169.254/32
ec2_dmz_host=$CONTROLER_IP
metadata_host=$CONTROLER_IP
metadata_listen=0.0.0.0
enabled_apis=metadata

# Networking #
network_api_class=nova.network.quantumv2.api.API
quantum_url=http://$CONTROLER_IP:9696
quantum_auth_strategy=keystone
quantum_admin_tenant_name=service
quantum_admin_username=quantum
quantum_admin_password=$PASSWORD
quantum_admin_auth_url=http://$CONTROLER_IP:35357/v2.0
libvirt_vif_driver=nova.virt.libvirt.vif.LibvirtHybridOVSBridgeDriver
linuxnet_interface_driver=nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver=nova.virt.libvirt.firewall.IptablesFirewallDriver

# Compute #
compute_driver=libvirt.LibvirtDriver
connection_type=libvirt

# Cinder #
volume_api_class=nova.volume.cinder.API
osapi_volume_listen_port=5900

# Glance #
glance_api_servers=$CONTROLER_IP:9292
image_service=nova.image.glance.GlanceImageService

# novnc #
novnc_enable=true
novncproxy_base_url=http://$CONTROLER_IP:6080/vnc_auto.html
vncserver_proxyclient_address=127.0.0.1
vncserver_listen=0.0.0.0

# Misc #
logdir=/var/log/nova
state_path=/var/lib/nova
lock_path=/var/lock/nova
root_helper=sudo nova-rootwrap /etc/nova/rootwrap.conf
verbose=true
" > $NOVA_CONF

service nova-compute restart

nova-manage service list

#-------------------
# 4. Quantum
#-------------------

echo "====================="
echo " Install OpenVswitch"
echo "====================="
kernel_version=`cat /proc/version | cut -d " " -f3`
apt-get install -y make fakeroot dkms openvswitch-switch openvswitch-datapath-dkms linux-headers-$kernel_version

service openvswitch-switch start

ovs-vsctl add-br br-int

echo "=================="
echo " Install Quantum"
echo "=================="
apt-get install -y quantum-plugin-openvswitch-agent

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

service quantum-plugin-openvswitch-agent restart
