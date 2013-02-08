#!/usr/bin/env bash
#
# Quantum Networking
#
# Description: Create Virtual Networking for Quantum

# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

source $TOP_DIR/openstackrc

#######################
### Private Network ###
#######################

TENANT_NAME="demo"               								# The tenant this network is created for
TENANT_NETWORK_NAME="demo-net" 									# The Quantum-internal network name
FIXED_RANGE=${FIXED_RANGE:-10.4.128.0/24}			  # The IP range for the private tenant network
NETWORK_GATEWAY=${NETWORK_GATEWAY:-10.4.128.1}	# The Gateway Tenant-VMs will receive as default gw



######################
### Public Network ###
######################

# Provider Router Information - what name should 
# this provider have in Quantum?
PROV_ROUTER_NAME="provider-router"

# Name of External Network (Don't change it!)
EXT_NET_NAME="ext_net"

# External Network addressing - our official 
# Internet IP address space
EXT_NET_CIDR=${EXT_NET_CIDR:-172.24.4.224/28}
EXT_NET_LEN=${EXT_NET_CIDR#*/}

# External bridge that we have configured 
# into l3_agent.ini (Don't change it!)
EXT_NET_BRIDGE=br-ex

# IP of external bridge (br-ex) - this node's 
# IP in our official Internet IP address space:
EXT_GW_IP=${EXP_GW_IP:-172.24.4.224}

# IP of the Public Network Gateway - The 
# default GW in our official Internet IP address space:
EXT_NET_GATEWAY=${EXP_GW_IP:-172.24.4.1}

# Floating IP range
POOL_FLOATING_START=${POOL_FLOATING_START:-172.24.4.1}	# First public IP to be used for VMs
POOL_FLOATING_END=${POOL_FLOATING_START:-172.24.4.223}	# Last public IP to be used for VMs 


###############################################################

# Function to get ID :
get_id () {
        echo `$@ | awk '/ id / { print $4 }'`
}


# Create the Tenant private network :
create_net() {
    local tenant_name="$1"
    local tenant_network_name="$2"
    local prov_router_name="$3"
    local fixed_range="$4"
    local network_gateway="$5"
    local tenant_id=$(keystone tenant-list | grep " $tenant_name " | awk '{print $2}')

    tenant_net_id=$(get_id quantum net-create --tenant_id $tenant_id $tenant_network_name --provider:network_type gre --provider:segmentation_id 1)
    tenant_subnet_id=$(get_id quantum subnet-create --tenant_id $tenant_id --ip_version 4 $tenant_net_id $fixed_range --gateway $network_gateway)
    prov_router_id=$(get_id quantum router-create --tenant_id $tenant_id $prov_router_name)
    quantum router-interface-add $prov_router_id $tenant_subnet_id
}

# Create External Network :
create_ext_net() {
    local ext_net_name="$1"
    local ext_net_cidr="$2"
    local ext_net_gateway="$4"
    local pool_floating_start="$5"
    local pool_floating_end="$6"

    ext_net_id=$(get_id quantum net-create $ext_net_name -- --router:external=True --provider:network_type gre --provider:segmentation_id 2)
    quantum subnet-create --ip_version 4 --allocation-pool start=$pool_floating_start,end=$pool_floating_end \
    --gateway $ext_net_gateway $ext_net_id $ext_net_cidr -- --enable_dhcp=False
    
}

# Connect the Tenant Virtual Router to External Network :
connect_providerrouter_to_externalnetwork() {
    local prov_router_name="$1"
    local ext_net_name="$2"

    router_id=$(get_id quantum router-show $prov_router_name)
    ext_net_id=$(get_id quantum net-show $ext_net_name)
    quantum router-gateway-set $router_id $ext_net_id
    
    # Edit l3_gaent.ini - 2013.01.28 naleeJang add
    sed -e "
/^# gateway_external_network_id =.*$/s/^.*$/gateway_external_network_id = $ext_net_id/
/^# router_id =.*$/s/^.*$/router_id = $router_id/
" -i /etc/quantum/l3_agent.ini
}

create_net $TENANT_NAME $TENANT_NETWORK_NAME $PROV_ROUTER_NAME $FIXED_RANGE $NETWORK_GATEWAY
create_ext_net $EXT_NET_NAME $EXT_NET_CIDR $EXT_NET_BRIDGE $EXT_NET_GATEWAY $POOL_FLOATING_START $POOL_FLOATING_END
connect_providerrouter_to_externalnetwork $PROV_ROUTER_NAME $EXT_NET_NAME

# Configure br-ex to reach public network :
ip addr flush dev $EXT_NET_BRIDGE
ip addr add $EXT_GW_IP/$EXT_NET_LEN dev $EXT_NET_BRIDGE
ip link set $EXT_NET_BRIDGE up
