#!/bin/bash
set -e

# MIT License
#
# Copyright (c) 2020 Kasper Stad
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Script Basename
BASENAME=$(basename $0)

# Help meassage
function get_help()
{
    echo
    echo "Usage: $BASENAME <parameters> ..."
    echo
    echo "Parameters:"
    echo "    -c, --cores             CPU Cores that will be assigned to the VM (default: 1)"
    echo "    --disk-size             Size of the VM disk in GB (default: 20)"
    echo "    --dns-server            DNS Server for deployment (default: 8.8.8.8)"
    echo "    --domain                Domain for deployment (default: cloud.local)"
    echo "    --gateway               Default Gateway, if not specified it will be constructed (eg. 192.168.1.1)"
    echo "    -h, --help              Show this help message."
    echo "    -i, --ip-address        (required) IP Address of this VM in CIDR format (eg. 192.168.1.2/24)"
    echo "    --id                    Custom VM ID (if undefined, next available ID in cluster is used)"
    echo "    -m, --memory            Memory that will be allocated to the VM in MB (default: 1024)"
    echo "    -n, --name              (required) Name of the VM without spaces, dots and other ambiguous characters"
    echo "    --no-start              Don't start after VM is created (if you need to append user-data)"
    echo "    --username              Override default username (default: ubuntu)"
    echo "    --vlan                  VLAN for the primary network interface (Set to 0 if no VLAN)"
    echo
    exit 1
}

# This script needs root permissions to run, check that
if [ "$EUID" -ne 0 ]; then
    echo -e "[$BASENAME]: \033[0;31mError: You must run this script as root\033[0m"
    exit 1
fi

# Get Help if you don't specify any arguments...
if [ ${#} -eq 0 ]; then
    get_help
fi

# Parse all parameters
while [ ${#} -gt 0 ]; do
    case "${1}" in
        -c|--cores)
            VM_CORES=$2
            shift
            shift
            ;;
        --disk-size)
            VM_DISK_SIZE="$2"
            shift
            shift
            ;;
        --dns-server)
            VM_DNS_SERVER="$2"
            shift
            shift
            ;;
        --domain)
            VM_DOMAIN="$2"
            shift
            shift
            ;;
        --gateway)
            VM_GATEWAY="$2"
            shift
            shift
            ;;
        -h|--help)
            get_help
            ;;
        -i|--ip-address)
            VM_IP_ADDRESS="$2"
            shift
            shift
            ;;
        --id)
            VMID=$2
            shift
            shift
            ;;
        -m|--memory)
            VM_MEMORY=$2
            shift
            shift
            ;;
        -n|--name)
            VM_NAME="$2"
            if [[ $VM_NAME == *['!'@#\$%^\&*()\_+\']* ]];then
                echo -e "[$BASENAME]: \033[0;31mError: Specified hostname is invalid\033[0m"
                exit 1
            fi
            shift
            shift
            ;;
        --no-start)
            VM_NO_START_CREATED=1
            shift
            ;;
        --username)
            VM_USERNAME="$2"
            shift
            shift
            ;;
        --vlan)
            VM_NET_VLAN=$2
            shift
            shift
            ;;
        *)
            get_help
            ;;
    esac
done

# Ubuntu Cloud Image Variables
VM_CLOUDIMG_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
VM_CLOUDIMG_SUMS="https://cloud-images.ubuntu.com/focal/current/MD5SUMS"

# Default values if they wasn't defined as parameters
# CHANGE THESE VALUES AS NEEDED IF YOU LIKE!
VM_CORES=${VM_CORES:-1}
VM_DISK_SIZE=${VM_DISK_SIZE:-20}
VM_DNS_SERVER=${VM_DNS_SERVER:-"8.8.8.8"}
VM_DOMAIN=${VM_DOMAIN:-"cloud.local"}
VM_GATEWAY=${VM_GATEWAY:-""}
VM_MEMORY=${VM_MEMORY:-1024}
VM_NET_BRIDGE=${VM_NET_BRIDGE:-"vmbr0"}
VM_NET_VLAN=${VM_NET_VLAN:-2}
VM_SNIPPETS_STORAGE_NAME=${VM_SNIPPETS_STORAGE_NAME:-"local"}
VM_SNIPPETS_STORAGE_PATH=${VM_SNIPPETS_STORAGE_PATH:-"/var/lib/vz/snippets"}
VM_SSH_KEYFILE=${VM_SSH_KEYFILE:-"${HOME}/.ssh/id_rsa.pub"}
VM_STORAGE=${VM_STORAGE:-"local-lvm"}
VM_USERNAME=${VM_USERNAME:-""}
VMID=${VMID:-""}

# Get Help if you don't specify required parameters (yes I know I'm a little demanding ;) )...
if [[ -z $VM_NAME || -z $VM_IP_ADDRESS || -z $VM_SSH_KEYFILE ]]; then
    get_help
fi

# Cloudimage base variables
VM_CLOUDIMG_NAME=$(basename $VM_CLOUDIMG_URL)
VM_CLOUDIMG_FULL_PATH="/tmp/${VM_CLOUDIMG_NAME}"

# Download image if not found in /tmp directory OR if image on web is newer
if [ -f $VM_CLOUDIMG_FULL_PATH ]; then
    VM_CLOUDIMG_SUM=$(md5sum $VM_CLOUDIMG_FULL_PATH | awk '{print $1}')
    VM_CLOUDIMG_SUM_NEWEST=$(wget -qO- $VM_CLOUDIMG_SUMS | grep "${VM_CLOUDIMG_NAME}" | awk '{print $1}')
    if [ "${VM_CLOUDIMG_SUM_NEWEST}" != "${VM_CLOUDIMG_SUM}" ]; then
        echo -e "[$BASENAME]: \033[1;32mdownloading image...\033[0m"
        wget --show-progress -o /dev/null -O $VM_CLOUDIMG_FULL_PATH $VM_CLOUDIMG_URL
    fi
else
    echo -e "[$BASENAME]: \033[1;32mdownloading image...\033[0m"
    wget --show-progress -o /dev/null -O $VM_CLOUDIMG_FULL_PATH $VM_CLOUDIMG_URL
fi

# Fetch the next available VM ID, if not provided
if [ -z $VMID ]; then
    VMID=$(pvesh get /cluster/nextid)
fi

# Create the new VM
qm create $VMID --name $VM_NAME --cores $VM_CORES --memory $VM_MEMORY -ostype l26

# Import the image to the storage
qm importdisk $VMID $VM_CLOUDIMG_FULL_PATH $VM_STORAGE | egrep -v '^transferred'

# Attach the disk to scsi0 bus
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $VM_STORAGE:vm-$VMID-disk-0,discard=on

# Resize the imported disk
qm resize $VMID scsi0 ${VM_DISK_SIZE}G

# Set the default boot disk to be the newly imported disk
qm set $VMID --boot c --bootdisk scsi0

# Add a cloud-init drive
qm set $VMID --ide2 $VM_STORAGE:cloudinit

# Add the SSH Keys to the server
qm set $VMID --sshkey $VM_SSH_KEYFILE

# Set the VM to use serial0 as the default vga device
qm set $VMID --serial0 socket --vga serial0

# Attach network interface to a bridge, and optionally set VLAN tag
if [[ ! -z $VM_NET_VLAN ]] && [[ $VM_NET_VLAN -ne 0 ]]; then
    qm set $VMID --net0 virtio,bridge=$VM_NET_BRIDGE,tag=$VM_NET_VLAN
else
    qm set $VMID --net0 virtio,bridge=$VM_NET_BRIDGE
fi

# If no default gateway is defined, we're creating one
if [ -z "${VM_GATEWAY}" ]; then
    VM_GATEWAY="$(echo ${VM_IP_ADDRESS} | cut -d '.' -f -3).1"
fi

if [ ! -z "${VM_USERNAME}" ]; then
    qm set $VMID --ciuser="${VM_USERNAME}"
fi

# Setup the network, DNS server and domain
qm set $VMID --ipconfig0 ip=$VM_IP_ADDRESS,gw=$VM_GATEWAY
qm set $VMID --nameserver $VM_DNS_SERVER --searchdomain $VM_DOMAIN

# If we want the QEMU Guest agent enabled and installed, then we dump the proxmox generated user-data and append to the cicustom
# We'll show a warning about that removes the availability to modify user-data through the WebUI
VM_CICUSTOM_USER_DATA="${VM_SNIPPETS_STORAGE_PATH}/${VMID}.yml"
echo -e "[$BASENAME]: \033[1;33mThis script creates a custom cloud-init user-data file\033[0m"
echo -e "[$BASENAME]: \033[1;33mThis means that you cannot modify user-data through Proxmox WebUI, but can edit this file directly instead:\033[0m"
echo -e "[$BASENAME]: \033[1;33m  ${VM_CICUSTOM_USER_DATA}\033[0m"; sleep 1

cat > $VM_CICUSTOM_USER_DATA << EOF
$(qm cloudinit dump $VMID user)
apt_reboot_if_required: True
timezone: Europe/Copenhagen
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl restart qemu-guest-agent
EOF

qm set $VMID --agent 1 --cicustom user="${VM_SNIPPETS_STORAGE_NAME}:snippets/${VMID}.yml"

# if --no-start wasn't spedified, start the VM after it's created
if [ -z $VM_NO_START_CREATED ]; then qm start $VMID; fi
