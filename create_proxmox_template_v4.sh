#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
# set -u
# Exit script if any command in a pipeline fails, not just the last one.
set -o pipefail

# --- CONFIGURATION ---
# Path to your public SSH key file
SSH_KEYFILE="/home/abevz/.ssh/id_rsa.pub" # IMPORTANT: Change 'youruser'
# Username for cloud-init
CI_USERNAME="abevz" # IMPORTANT: Change to your desired default username
# Proxmox storage for VM disks
STORAGE_NAME="MyStorage" # IMPORTANT: Ensure this storage exists

# --- virt-customize ---
# Set to true to use virt-customize to modify the image before import
USE_VIRT_CUSTOMIZE=true
# Package name for QEMU Guest Agent
QEMU_AGENT_PACKAGE_VIRT="qemu-guest-agent"
# Package name for cloud-init
CLOUD_INIT_PACKAGE_VIRT="cloud-init"
# Optional: Set a timezone using virt-customize, e.g., "Europe/Warsaw", "Etc/UTC"
VIRT_CUSTOMIZE_TIMEZONE="" # Example: "Europe/Warsaw"

# Password for cloud-init user (prompted if SSH_KEYFILE is not found/empty)
CI_PASSWORD=""

# --- FUNCTIONS ---

check_dependencies() {
    local missing_deps=0
    local deps_to_check="wget qm xz"
    if [ "$USE_VIRT_CUSTOMIZE" = true ]; then
        deps_to_check="$deps_to_check virt-customize"
    fi

    for cmd in $deps_to_check; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: Utility '$cmd' not found. Please install it." >&2
            if [ "$cmd" = "virt-customize" ]; then
                echo "       On Debian/Ubuntu, try: sudo apt install libguestfs-tools" >&2
                echo "       On Fedora/RHEL, try: sudo dnf install libguestfs-tools-c" >&2
            fi
            missing_deps=1
        fi
    done
    if [ "$missing_deps" -eq 1 ]; then
        exit 1
    fi
}

function create_template() {
    local vm_id="$1"
    local vm_name="$2"
    local image_file_orig="$3"
    local image_url="$4"
    local unxz_required="${5:-0}"
    local image_file_final="$image_file_orig"
    local downloaded_file="$image_file_orig"

    if qm status "$vm_id" &>/dev/null; then
        echo "Warning: VM with ID $vm_id ('$(qm config "$vm_id" | grep name | awk '{print $2}')') already exists. Skipping creation of '$vm_name'."
        return
    fi

    if [ -n "$image_url" ]; then
        echo "Downloading image for $vm_name from $image_url..."
        if ! wget --progress=bar:force:noscroll -O "$downloaded_file" "$image_url"; then
            echo "Error: Failed to download image from $image_url for $vm_name." >&2
            rm -f "$downloaded_file"
            return 1
        fi
    elif [ ! -f "$downloaded_file" ]; then
        echo "Error: Image file '$downloaded_file' not found and no URL provided for $vm_name." >&2
        return 1
    fi

    if [ "$unxz_required" -eq 1 ] && [[ "$downloaded_file" == *.xz ]]; then
        echo "Decompressing $downloaded_file..."
        image_file_final="${downloaded_file%.xz}"
        if ! xz -d -k -c "$downloaded_file" > "$image_file_final"; then # Keep original .xz with -k, output to new file
            echo "Error: Failed to decompress $downloaded_file to $image_file_final." >&2
            rm -f "$image_file_final"
            return 1
        fi
        echo "Decompressed to $image_file_final."
    else
        image_file_final="$downloaded_file"
    fi

    if [ "$USE_VIRT_CUSTOMIZE" = true ] && [ -f "$image_file_final" ]; then
        echo "Customizing image '$image_file_final' with virt-customize..."

        local virt_ops=()
        virt_ops+=("--install" "$QEMU_AGENT_PACKAGE_VIRT")
        virt_ops+=("--install" "$CLOUD_INIT_PACKAGE_VIRT")

        # Enable qemu-guest-agent service (best-effort for systemd/OpenRC)
        #virt_ops+=("--run-command" 'if command -v systemctl &>/dev/null; then (systemctl enable --now qemu-guest-agent.service || systemctl enable --now qemu-guest-agent) &>/dev/null; elif command -v rc-update &>/dev/null && [ -f /etc/init.d/qemu-ga ]; then rc-update add qemu-ga default &>/dev/null && rc-service qemu-ga start &>/dev/null; fi; exit 0')
        # --- Modified: Simplify qemu-guest-agent service enabling ---
        virt_ops+=("--run-command" "echo 'Attempting to enable qemu-guest-agent service for next boot...' >&2; \
            if command -v systemctl &>/dev/null; then \
                if ! systemctl enable qemu-guest-agent.service >&2 && ! systemctl enable qemu-guest-agent >&2; then \
                    echo 'Warning (Debian/systemd): systemctl enable command for qemu-guest-agent seemed to fail or service not found by that exact name. The package postinstall script should ideally handle enabling.' >&2; \
                else \
                    echo 'Info (Debian/systemd): systemctl enable for qemu-guest-agent was attempted.' >&2; \
                fi; \
            elif command -v rc-update &>/dev/null && [ -f /etc/init.d/qemu-ga ]; then \
                if ! rc-update add qemu-ga default >&2; then \
                    echo 'Warning (Alpine/OpenRC): rc-update add command for qemu-ga seemed to fail.' >&2; \
                else \
                    echo 'Info (Alpine/OpenRC): rc-update add for qemu-ga was attempted.' >&2; \
                fi; \
            else \
                echo 'Warning: Could not determine init system to enable qemu-guest-agent, or service name is different. Package installation should proceed.' >&2; \
            fi; \
            exit 0") # exit 0 ensures virt-customize itself doesn't fail here.
        # --- End of modified run-command ---

        if [ -n "$VIRT_CUSTOMIZE_TIMEZONE" ]; then
            virt_ops+=("--timezone" "$VIRT_CUSTOMIZE_TIMEZONE")
        fi

        # --- NEW: Clear machine-id for proper cloning ---
        echo "Adding virt-customize operations to clear machine-id..."
        virt_ops+=("--run-command" "echo 'Clearing /etc/machine-id for template preparation.' >&2; truncate -s 0 /etc/machine-id || true")
        virt_ops+=("--run-command" "echo 'Removing /var/lib/dbus/machine-id for template preparation.' >&2; rm -f /var/lib/dbus/machine-id || true")
        # An alternative to truncate for /etc/machine-id:
        # virt_ops+=("--run-command" "rm -f /etc/machine-id && touch /etc/machine-id")
        # --- End of machine-id clearing ---

        echo "Running: sudo virt-customize -a \"$image_file_final\" ${virt_ops[@]}"
        if sudo virt-customize -a "$image_file_final" "${virt_ops[@]}"; then
            echo "Image customization successful."
        else
            echo "Error: virt-customize failed to modify '$image_file_final'." >&2
            [ -f "$image_file_final" ] && rm -f "$image_file_final"
            if [ "$image_file_final" != "$downloaded_file" ] && [ -f "$downloaded_file" ]; then
                 rm -f "$downloaded_file"
            fi
            return 1
        fi
    fi

    echo "Creating Proxmox template $vm_name (ID: $vm_id) from image file $image_file_final"

    qm create "$vm_id" --name "$vm_name" --ostype l26
    qm set "$vm_id" --net0 virtio,bridge=vmbr0
    qm set "$vm_id" --serial0 socket --vga serial0
    qm set "$vm_id" --memory 2048 --cores 2 --cpu host
    qm set "$vm_id" --agent enabled=1,fstrim_cloned_disks=1

    qm set "$vm_id" --scsi0 "${STORAGE_NAME}:0,import-from=$(pwd)/$image_file_final,discard=on"
    qm set "$vm_id" --boot order=scsi0 --scsihw virtio-scsi-single

    qm set "$vm_id" --ide2 "${STORAGE_NAME}:cloudinit"
    qm set "$vm_id" --ciuser "$CI_USERNAME"
    if [ -f "$SSH_KEYFILE" ] && [ -s "$SSH_KEYFILE" ]; then
        echo "Using SSH key for $CI_USERNAME: $SSH_KEYFILE"
        qm set "$vm_id" --sshkeys "$SSH_KEYFILE"
    elif [ -n "$CI_PASSWORD" ]; then
        echo "Using password for user $CI_USERNAME."
        qm set "$vm_id" --cipassword "$CI_PASSWORD"
    else
        echo "Warning: No SSH key found/specified and no password set for $vm_name."
    fi
    qm set "$vm_id" --ipconfig0 "ip6=auto,ip=dhcp"

    if ! qm disk resize "$vm_id" scsi0 10G; then
        echo "Info: Could not resize disk for $vm_name to 10G."
    fi

    qm template "$vm_id"
    echo "Template $vm_name (ID: $vm_id) created successfully."

    if [ -f "$image_file_final" ]; then
        echo "Deleting processed image file: $image_file_final..."
        rm "$image_file_final"
    fi
    if [ "$image_file_final" != "$downloaded_file" ] && [ -f "$downloaded_file" ] && [[ "$downloaded_file" == *.xz ]]; then
        echo "Deleting original downloaded archive: $downloaded_file..."
        rm "$downloaded_file"
    fi
}

# --- MAIN SCRIPT BLOCK ---
# (Остальная часть скрипта (MAIN SCRIPT BLOCK) остается без изменений)

check_dependencies

if [ ! -f "$SSH_KEYFILE" ] || [ ! -s "$SSH_KEYFILE" ]; then
    echo "SSH key file '$SSH_KEYFILE' not found or is empty."
    while true; do
        read -s -r -p "Enter password for user '$CI_USERNAME' (leave empty for no password): " CI_PASSWORD
        echo
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
            break
        fi
    done
else
    echo "Using SSH key from file: $SSH_KEYFILE"
fi

echo "--- Starting template creation process ---"

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

    if create_template "$vm_id" "$vm_name" "$filename" "$url" "$unxz"; then
        echo "Successfully processed $vm_name."
    else
        echo "Error processing $vm_name. Check messages above."
    fi
done

echo -e "\n--- Template creation process finished ---"