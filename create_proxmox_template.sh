#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
# set -u # You might want to uncomment this for stricter error checking
# Exit script if any command in a pipeline fails, not just the last one.
set -o pipefail

# --- CONFIGURATION ---
# Path to your public SSH key file (e.g., authorized_keys format)
# Alternatively, use /etc/pve/priv/authorized_keys if you are already authorized
# on the Proxmox system.
SSH_KEYFILE="/home/abevz/.ssh/id_rsa.pub" # IMPORTANT: Change 'youruser'
# Username to be created in the VM template by cloud-init
CI_USERNAME="abevz" # IMPORTANT: Change to your desired default username
# Proxmox storage name where VM disks will be stored
STORAGE_NAME="MyStorage" # IMPORTANT: Ensure this storage exists and is suitable for VM images

# Password for the cloud-init user (will be prompted for if SSH_KEYFILE is not found/empty)
CI_PASSWORD=""

# --- FUNCTIONS ---

# Function to check for required command-line utilities
check_dependencies() {
    local missing_deps=0
    for cmd in wget qm xz; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: Utility '$cmd' not found. Please install it." >&2
            missing_deps=1
        fi
    done
    if [ "$missing_deps" -eq 1 ]; then
        exit 1
    fi
}

# Function to create a VM template
# Arguments:
# $1: vm_id (integer)
# $2: vm_name (string)
# $3: image_filename (string, name of the image file in the current directory)
# $4: image_url (string, URL to download the image from, optional if file already downloaded)
# $5: unxz_required (integer, 1 if .xz decompression is needed, 0 otherwise)
function create_template() {
    local vm_id="$1"
    local vm_name="$2"
    local image_file_orig="$3" # Original filename, might be .xz
    local image_url="$4"
    local unxz_required="${5:-0}" # Default to 0 (no decompression)
    local image_file_final="$image_file_orig" # Actual image file to import (e.g., .qcow2 or .raw)
    local downloaded_file="$image_file_orig"  # Filename used for download/initial reference

    # Check if a VM with this ID already exists
    if qm status "$vm_id" &>/dev/null; then
        echo "Warning: VM with ID $vm_id ('$(qm config "$vm_id" | grep name | awk '{print $2}')') already exists. Skipping creation of '$vm_name'."
        # If the file was specifically downloaded for this VM, it could be removed here.
        # However, since files might be reused or specified manually, cleanup is handled later.
        return
    fi

    # Download the image if a URL is provided
    if [ -n "$image_url" ]; then
        echo "Downloading image for $vm_name..."
        if ! wget --progress=bar:force:noscroll -O "$downloaded_file" "$image_url"; then
            echo "Error: Failed to download image from $image_url for $vm_name." >&2
            rm -f "$downloaded_file" # Attempt to remove partially downloaded file
            return 1                 # Signal error
        fi
    elif [ ! -f "$downloaded_file" ]; then
        echo "Error: Image file '$downloaded_file' not found and no URL provided for $vm_name." >&2
        return 1
    fi

    # Decompress .xz archive if required
    if [ "$unxz_required" -eq 1 ] && [[ "$downloaded_file" == *.xz ]]; then
        echo "Decompressing $downloaded_file..."
        if ! xz -d -k -v "$downloaded_file"; then # -k to keep the original .xz file for now
            echo "Error: Failed to decompress $downloaded_file." >&2
            # rm -f "${downloaded_file%.xz}" # Remove partially decompressed file if any
            return 1
        fi
        image_file_final="${downloaded_file%.xz}" # Update to the name of the decompressed file
    else
        image_file_final="$downloaded_file" # If not .xz or not required, final is same as downloaded
    fi

    echo "Creating template $vm_name (ID: $vm_id) from image file $image_file_final"

    # Create new VM
    qm create "$vm_id" --name "$vm_name" --ostype l26
    # Set networking to default bridge (vmbr0)
    qm set "$vm_id" --net0 virtio,bridge=vmbr0
    # Set display to serial
    qm set "$vm_id" --serial0 socket --vga serial0
    # Set memory, cores, CPU type (adjust as needed)
    qm set "$vm_id" --memory 2048 --cores 2 --cpu host
    # Set boot device to new file, importing from the local path
    qm set "$vm_id" --scsi0 "${STORAGE_NAME}:0,import-from=$(pwd)/$image_file_final,discard=on"
    # Set SCSI hardware as default boot disk using virtio-scsi-single
    qm set "$vm_id" --boot order=scsi0 --scsihw virtio-scsi-single
    # Enable QEMU guest agent if available in the guest
    qm set "$vm_id" --agent enabled=1,fstrim_cloned_disks=1
    # Add cloud-init drive
    qm set "$vm_id" --ide2 "${STORAGE_NAME}:cloudinit"
    # Set cloud-init IP configuration (IPv6=auto for SLAAC, IPv4=dhcp)
    qm set "$vm_id" --ipconfig0 "ip6=auto,ip=dhcp"
    # Set cloud-init user
    qm set "$vm_id" --ciuser "$CI_USERNAME"

    # Set SSH key or password
    if [ -f "$SSH_KEYFILE" ] && [ -s "$SSH_KEYFILE" ]; then # Check if file exists and is not empty
        echo "Using SSH key for $CI_USERNAME: $SSH_KEYFILE"
        qm set "$vm_id" --sshkeys "$SSH_KEYFILE"
    elif [ -n "$CI_PASSWORD" ]; then
        echo "Using password for user $CI_USERNAME."
        qm set "$vm_id" --cipassword "$CI_PASSWORD"
    else
        echo "Warning: No SSH key found/specified and no password set for $vm_name."
        echo "         You may need to set credentials manually or via cloud-init reconfig after cloning."
    fi

    # Resize the disk (e.g., to 10G). Cloud images are often small.
    # If the disk is already larger, this might fail, which is usually acceptable.
    if ! qm disk resize "$vm_id" scsi0 10G; then
        echo "Info: Could not resize disk for $vm_name to 10G. It might already be larger, or another issue occurred."
        # This is not treated as a fatal error for cloud images.
    fi

    # Convert the VM to a template
    qm template "$vm_id"

    echo "Template $vm_name (ID: $vm_id) created successfully."

    # Clean up the (potentially decompressed) image file
    if [ -f "$image_file_final" ]; then
        # If image_file_final is different from downloaded_file (i.e., it was decompressed from .xz)
        # and downloaded_file was the .xz, we remove the .xz later.
        # Here, we remove the .raw or .qcow2 file.
        echo "Deleting processed image file: $image_file_final..."
        rm "$image_file_final"
    fi
}

# --- MAIN SCRIPT BLOCK ---

check_dependencies

# Prompt for password if SSH_KEYFILE does not exist or is empty
if [ ! -f "$SSH_KEYFILE" ] || [ ! -s "$SSH_KEYFILE" ]; then # Check if file doesn't exist OR is empty
    echo "SSH key file '$SSH_KEYFILE' not found or is empty."
    # Loop until a password is provided or the user explicitly enters nothing
    while true; do
        read -s -r -p "Enter password for user '$CI_USERNAME' (leave empty for no password, not recommended): " CI_PASSWORD
        echo # Newline after read -s
        if [ -n "$CI_PASSWORD" ]; then
            read -s -r -p "Confirm password: " CI_PASSWORD_CONFIRM
            echo
            if [ "$CI_PASSWORD" == "$CI_PASSWORD_CONFIRM" ]; then
                break
            else
                echo "Passwords do not match. Please try again."
            fi
        else
            echo "Warning: No password provided. SSH key is also not available."
            echo "         The template will be created without pre-configured password access for '$CI_USERNAME'."
            break # Allow empty password if user intends
        fi
    done
else
    echo "Using SSH key from file: $SSH_KEYFILE"
fi

echo "--- Starting template creation process ---"

# Define the list of images to create templates from.
# Format for each entry: "VM_ID;TEMPLATE_NAME;LOCAL_FILENAME;DOWNLOAD_URL;UNXZ_REQUIRED(1/0)"
# Ensure VM_IDs are unique on your Proxmox system.
# Always check for the latest image URLs from the official distribution websites.

declare -a images_to_create=(
    # Debian
    "901;tpl-debian-11;debian-11-genericcloud-amd64.qcow2;https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2;0"
    "902;tpl-debian-12;debian-12-genericcloud-amd64.qcow2;https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2;0"
    # "903;tpl-debian-13-daily;debian-13-genericcloud-amd64-daily.qcow2;https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2;0"
    # "909;tpl-debian-sid;debian-sid-genericcloud-amd64-daily.qcow2;https://cloud.debian.org/images/cloud/sid/daily/latest/debian-sid-genericcloud-amd64-daily.qcow2;0"

    # Ubuntu
    "910;tpl-ubuntu-2004-lts;ubuntu-20.04-server-cloudimg-amd64.img;https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img;0"
    "911;tpl-ubuntu-2204-lts;ubuntu-22.04-server-cloudimg-amd64.img;https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img;0"
    "912;tpl-ubuntu-2404-lts;ubuntu-24.04-server-cloudimg-amd64.img;https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img;0"

    # Fedora (Uses .qcow2 directly. Check fedoraproject.org/cloud/download for latest versions)
    # Example for Fedora 40. Update version number and URL as new Fedora releases become available.
    "920;tpl-fedora-40;Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2;https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2;0"
    # Example for a .raw.xz image (older Fedora releases or other distros might use this)
    # "921;tpl-fedora-old-example;Fedora-Cloud-Base-XX-Y.Z.x86_64.raw.xz;URL_TO_FEDORA_RAW_XZ_IMAGE;1"

    # Rocky Linux
    "930;tpl-rocky-8;Rocky-8-GenericCloud.latest.x86_64.qcow2;https://dl.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2;0"
    "931;tpl-rocky-9;Rocky-9-GenericCloud.latest.x86_64.qcow2;https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2;0"

    # Alpine Linux (Check alpinelinux.org/cloud/ for latest versions and correct filenames)
    # Filename example: nocloud-alpine-VERSION-ARCH-bios-cloudinit-r0.qcow2
    "940;tpl-alpine-3.20;nocloud_alpine-3.20.0-x86_64-bios-cloudinit-r0.qcow2;https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.0-x86_64-bios-cloudinit-r0.qcow2;0"
    # "941;tpl-alpine-latest;alpine-latest.qcow2;URL_TO_LATEST_ALPINE_QCOW2;0" # Replace with actual latest URL & filename
)

for image_data in "${images_to_create[@]}"; do
    IFS=';' read -r vm_id vm_name filename url unxz <<< "$image_data"
    
    echo -e "\n--- Processing: $vm_name (ID: $vm_id) ---"
    
    original_download_filename="$filename" # This is the name from the array, potentially an .xz file

    if create_template "$vm_id" "$vm_name" "$filename" "$url" "$unxz"; then
        echo "Successfully processed $vm_name."
    else
        echo "Error processing $vm_name. Check messages above."
        # Attempt to clean up the downloaded file if create_template failed before cleanup
        if [ -f "$original_download_filename" ]; then
            echo "Attempting to delete residual downloaded file: $original_download_filename..."
            rm -f "$original_download_filename"
        fi
        # If decompression happened and failed, the uncompressed file might also exist
        if [ "$unxz" -eq 1 ] && [ -f "${original_download_filename%.xz}" ]; then
             echo "Attempting to delete residual uncompressed file: ${original_download_filename%.xz}..."
             rm -f "${original_download_filename%.xz}"
        fi
    fi

    # After successful create_template, the decompressed file (image_file_final) is removed inside the function.
    # If an .xz file was downloaded and unxz_required was 1, the original .xz might still be present
    # (because of `xz -d -k`). Let's clean it up.
    if [ "$unxz" -eq 1 ] && [[ "$original_download_filename" == *.xz ]] && [ -f "$original_download_filename" ]; then
        echo "Deleting original downloaded archive: $original_download_filename..."
        rm -f "$original_download_filename"
    elif [ "$unxz" -eq 0 ] && [ -f "$original_download_filename" ] && [ "$original_download_filename" != "${original_download_filename%.xz}" ]; then
        # This case is less likely given the logic, but as a fallback for downloaded non-xz files
        # that might not have been cleaned up if `create_template` had an early exit before its own rm.
        # However, `create_template` now removes `image_file_final` which would be `original_download_filename` if unxz=0
        : # Usually handled within create_template for unxz=0
    fi
done

echo -e "\n--- Template creation process finished ---"
