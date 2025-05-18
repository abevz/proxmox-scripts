# Proxmox VE Cloud Image Template Creation Script

## Overview

This Bash script automates the creation of Proxmox VE virtual machine templates from various Linux cloud images. It downloads specified cloud images, configures them with cloud-init (setting up a user, SSH keys or password, networking, etc.), and then converts the VMs into templates ready for cloning. This allows for rapid deployment of new virtual machines.

## Acknowledgments

This script was originally based on and inspired by the great work and concepts presented in the article by apalrd: **[Creating Proxmox Cloud-Init Templates](https://www.apalrd.net/posts/2023/pve_cloud/)**.
This version incorporates several enhancements for robustness, security, and usability.

## Features

* Automated download of cloud images from official sources.
* Creation of Proxmox VE templates using `qm` commands.
* Cloud-init setup for:
    * User creation.
    * SSH key or password-based authentication.
    * Network configuration (DHCP for IPv4, SLAAC for IPv6).
    * QEMU Guest Agent enablement.
* Support for various Linux distributions (e.g., Debian, Ubuntu, Fedora, Rocky Linux, Alpine Linux).
* Configurable image list via a Bash array for easy management and addition of new images.
* Improved interactive password prompt with confirmation if an SSH key is not provided or found (allows for empty password with warning).
* Error handling (`set -e`, `set -o pipefail`) to stop on errors.
* Dependency checks for required utilities (`wget`, `qm`, `xz`).
* Checks for pre-existing VM IDs to prevent conflicts, skipping those already present.
* Automatic cleanup of downloaded and processed image files.

## Prerequisites

* A running Proxmox VE host.
* Bash shell (standard on Proxmox VE).
* The following utilities installed on the Proxmox host:
    * `wget` (for downloading images)
    * `qm` (Proxmox VE VM management tool)
    * `xz` (for decompressing `.xz` archives, if applicable)
* The script typically needs to be run as `root` or with `sudo` privileges, as `qm` commands require them.

## Configuration

Before running the script, you **must** review and potentially customize a few settings directly within the script file:

1.  **Core Variables (at the top of the script):**
    * `SSH_KEYFILE`: Path to your public SSH key file (e.g., `"/home/youruser/.ssh/id_rsa.pub"`). **Important:** Change `youruser` to your actual username or provide the correct path. This key will be added to the `CI_USERNAME` for SSH access.
    * `CI_USERNAME`: The default username to be created in the templates (e.g., `"adminuser"`). Change this to your desired default username.
    * `STORAGE_NAME`: The Proxmox VE storage where the VM disks will be created and stored (e.g., `"local-lvm"`). Ensure this storage exists on your Proxmox host and is configured to store VM images.

2.  **Password Authentication:**
    * If the `SSH_KEYFILE` (as defined by the variable) is not found, or if the file exists but is empty (zero size), the script will interactively prompt you to enter and confirm a password for the `CI_USERNAME`.
    * You can choose to leave the password empty during the prompt, but this is generally not recommended unless you have other means of access (like a pre-configured SSH key that will be injected by other means) or specific reasons for a passwordless user. A warning will be displayed if an empty password is set without a valid `SSH_KEYFILE` being used.

3.  **Image List (`images_to_create` array):**
    * This array in the script defines which Linux distributions and versions will be turned into templates. Each line in the array represents one template.
    * The format for each entry is a semicolon-separated string:
        `"VM_ID;TEMPLATE_NAME;LOCAL_FILENAME;DOWNLOAD_URL;UNXZ_REQUIRED(1_for_yes/0_for_no)"`
        * **`VM_ID`**: A unique numerical ID for the Proxmox VM/template.
        * **`TEMPLATE_NAME`**: The desired name for the template in Proxmox VE (e.g., `tpl-debian-12`).
        * **`LOCAL_FILENAME`**: The filename under which the image will be saved locally during processing. If `UNXZ_REQUIRED` is `1`, this should be the name of the `.xz` file.
        * **`DOWNLOAD_URL`**: The direct URL to download the cloud image.
        * **`UNXZ_REQUIRED`**: Set to `1` if the downloaded image is a `.raw.xz` or `.img.xz` file that needs decompression using `xz`. Set to `0` if it's a direct `.qcow2` or `.img` file.
    * **Example entry from the script:**
        `"902;tpl-debian-12;debian-12-genericcloud-amd64.qcow2;https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2;0"`
    * You can add, remove, or modify entries in this array. **Always verify that the `DOWNLOAD_URL`s are current** by checking the respective distribution's official website, as these links can change, especially for non-LTS or daily builds.

## Usage

1.  **Save the Script:**
    * Copy the script code and save it to a file on your Proxmox VE host (e.g., `create_proxmox_templates.sh`).
2.  **Make it Executable:**
    * Open a terminal on your Proxmox host and run:
        ```bash
        chmod +x create_proxmox_templates.sh
        ```
3.  **Run the Script:**
    * Execute the script (usually as `root` or with `sudo`):
        ```bash
        sudo ./create_proxmox_templates.sh
        ```
        Or, if you are already logged in as `root`:
        ```bash
        ./create_proxmox_templates.sh
        ```
4.  **Follow Prompts:**
    * If an SSH key is not configured or found (and is not empty), the script will prompt you for a password (and confirmation) for the cloud-init user.
5.  **Check Proxmox VE:**
    * Once the script completes, you will find the new templates listed in your Proxmox VE web interface (usually with a specific icon indicating they are templates). These are now ready to be cloned into new VMs.

## Important Notes

* **Image URLs:** Cloud image URLs, especially for development/testing branches or newer releases, can change frequently. It's highly recommended to verify the URLs in the `images_to_create` array before each run.
* **VM IDs:** Ensure the `VM_ID`s specified are unique on your Proxmox VE system and are not already in use. The script includes a check and will skip creating templates for existing VM IDs.
* **Console Access to Cloned VMs:** After cloning a VM from a template:
    * If SSH access isn't working as expected (e.g., key mismatch, network issue), you can access the VM via the Proxmox VE web console ("Console" tab for the VM).
    * Log in with the `CI_USERNAME` and the password you set (if any). If an empty password was chosen during the setup and no valid `SSH_KEYFILE` was used, direct login for `CI_USERNAME` might not be possible without further configuration on the cloned VM.
* **Resource Usage:** Downloading images and creating templates will consume disk space and network bandwidth. Ensure your Proxmox VE host has sufficient resources.
* **Script Execution Time:** Depending on the number of images and your internet speed, the script might take a considerable amount of time to complete.

## Utility Scripts for Guest and Template Destruction

This repository also includes utility scripts to help manage and remove Proxmox VE guests (VMs/LXCs) and templates. These scripts prompt for VMIDs, confirm the targets, and then attempt to stop (if applicable) and destroy them.

### `destroy_proxmox_guests.sh`

* **Purpose:** Destroys specified Proxmox VE Virtual Machines (VMs) and Linux Containers (LXCs).
* **Features:**
    * Prompts for space-separated VMIDs of guests to destroy.
    * Validates if VMIDs are numeric and correspond to existing VMs or LXCs.
    * Displays a summary of guests (VMs and LXCs separately with their names and VMIDs) that will be targeted for destruction.
    * Reports any problematic or non-existent VMIDs.
    * Asks for an explicit confirmation (`DESTROY`) before proceeding.
    * Offers an option to purge associated disks (this attempts to remove the disk images from storage).
    * For each valid guest:
        * Checks if it's running. If so, attempts to stop it (with a timeout).
        * If the guest is stopped (or successfully stopped), it proceeds to destroy it.
        * Reports success or failure for each operation.
    * Provides a final summary of successfully destroyed and failed/skipped guests.
* **Usage:**
    ```bash
    sudo ./destroy_proxmox_guests.sh
    ```
    Follow the on-screen prompts.

### `destroy_proxmox_templates.sh`

* **Purpose:** Destroys specified Proxmox VE virtual machine templates.
* **Features:**
    * Prompts for space-separated VMIDs of templates to destroy.
    * Validates if VMIDs are numeric.
    * Verifies that each existing KVM guest with a given VMID is indeed a template (checks for `template: 1` in its configuration).
    * Displays a summary of templates (with names and VMIDs) targeted for destruction.
    * Reports any problematic VMIDs (e.g., not found, not a template).
    * Asks for an explicit confirmation (`DESTROY`) before proceeding.
    * Offers an option to purge associated disk images (the template's base images).
    * For each valid template, it proceeds to destroy it (templates are inherently in a non-running state, so no "stop" operation is needed).
    * Reports success or failure for each destruction.
    * Provides a final summary of successfully destroyed and failed/skipped templates.
* **Usage:**
    ```bash
    sudo ./destroy_proxmox_templates.sh
    ```
    Follow the on-screen prompts.

**Important Note for Destruction Scripts:**
* **Irreversible Action:** Destruction of VMs, LXCs, or templates is irreversible. Ensure you have backups if the data is critical.
* **Permissions:** These scripts typically require `root` or `sudo` privileges to execute `qm` and `pct` commands for guest management. Alternatively, specific Proxmox VE user permissions can be configured to allow a non-root user to perform these actions.

## Disclaimer

Please note that English is not my native language. AI tools were utilized to assist with translation and refinement of this README file to ensure clarity and accuracy.
