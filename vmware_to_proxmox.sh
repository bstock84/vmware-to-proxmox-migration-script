#!/bin/bash
# Function to get user input
get_input() {
    read -p "$1: " input
    echo $input
}

# Check if ovftool is installed
if ! ovftool --version &> /dev/null; then
    echo "Error: ovftool is not installed or not found in PATH. Please install ovftool and try again."
    exit 1
fi

# Check if jq is installed
if ! jq --version &> /dev/null; then
    echo "Error: jq is not installed or not found in PATH. Please install jq and try again."
    exit 1
fi

# User inputs
echo "Enter the details for VM migration"
ESXI_SERVER=$(get_input "Enter the ESXi server hostname/IP")
ESXI_USERNAME=$(get_input "Enter the ESXi server username")
read -sp "Enter the ESXi server password: " ESXI_PASSWORD
echo
PROXMOX_SERVER=$(get_input "Enter the Proxmox server hostname/IP")
PROXMOX_USERNAME=$(get_input "Enter the Proxmox server username")
read -sp "Enter the Proxmox server password: " PROXMOX_PASSWORD
echo
VM_NAME=$(get_input "Enter the name of the VM to migrate")

# Export VM from VMware
function export_vmware_vm() {
    local ova_file="$VM_NAME.ova"
    if [ -f "$ova_file" ]; then
        read -p "File $ova_file already exists. Overwrite? (y/n): " choice
        if [ "$choice" != "y" ]; then
            echo "Export cancelled."
            exit 1
        fi
        rm -f "$ova_file"
    fi
    echo "Exporting VM from VMware..."
    echo $ESXI_PASSWORD | ovftool --sourceType=VI --acceptAllEulas --noSSLVerify --skipManifestCheck --diskMode=thin --name=$VM_NAME vi://$ESXI_USERNAME@$ESXI_SERVER/$VM_NAME $VM_NAME.ova
}

# Transfer VM to Proxmox
function transfer_vm() {
    echo "Transferring VM to Proxmox..."
    echo $PROXMOX_PASSWORD | ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "mkdir -p /var/vm-migration"
    echo $PROXMOX_PASSWORD | scp $VM_NAME.ova $PROXMOX_USERNAME@$PROXMOX_SERVER:/var/vm-migration/
}

# Convert VM to Proxmox format
function convert_vm() {
    echo "Converting VM to Proxmox format..."
    echo $PROXMOX_PASSWORD | ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "tar -xvf /var/vm-migration/$VM_NAME.ova -C /var/vm-migration/"
    local vmdk_file=$(ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "find /var/vm-migration -name '*.vmdk'")
    echo $PROXMOX_PASSWORD | ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qemu-img convert -f vmdk -O qcow2 $vmdk_file /var/vm-migration/$VM_NAME.qcow2"
}

# Get the next VM ID
function get_next_vm_id() {
    echo "Getting next VM ID..."
    # Get the list of VMs, sort by VM ID, get the last one, and increment by one
    NEXT_VM_ID=$(echo $PROXMOX_PASSWORD | ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "pvesh get /cluster/resources --type vm" | jq -r '.[].vmid' | sort -n | tail -1)
    let "NEXT_VM_ID++"
    echo $NEXT_VM_ID
}

# Create VM in Proxmox
function create_proxmox_vm() {
    echo "Creating VM in Proxmox..."
    VM_ID=$(get_next_vm_id)
    if ! [[ $VM_ID =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid VM ID '$VM_ID'."
        exit 1
    fi
    echo $PROXMOX_PASSWORD | ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm create $VM_ID --name $VM_NAME --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0"
}

# Main process
export_vmware_vm
transfer_vm
convert_vm
create_proxmox_vm