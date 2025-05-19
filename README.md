# Proxmox VE Management Scripts

This repository contains various Bash scripts to help automate and manage Proxmox VE environments.

## General Environment Notes
* Scripts like `create_proxmox_templates.sh`, `destroy_proxmox_guests.sh`, and `destroy_proxmox_templates.sh` are intended to be run directly on the Proxmox VE host, typically requiring `root` or `sudo` privileges.
* The `destroy_VMI.sh` script interacts with the Proxmox VE API and can be run from any machine with network access to the API. It requires `curl`, `jq`, and `sops` to be installed, but does not necessarily need `root` privileges if the configured API user has sufficient permissions.

# Index
* [create_proxmox_templates.sh](#proxmox-ve-cloud-image-template-creation-script)
* [destroy_proxmox_guests.sh](#destroy_proxmox_guestssh)
* [destroy_proxmox_templates.sh](#destroy_proxmox_templatessh)
* [destroy_VMI.sh - API-Based VM Destruction Script](#destroy_vmish---api-based-vm-destruction-script)
* [Brief Guide to Mozilla SOPS](#brief-guide-to-mozilla-sops-secrets-operations)
* [Accessing and Troubleshooting Proxmox VE VMs via Web Console](#1-accessing-the-vm-via-proxmox-web-console)
## Proxmox VE Cloud Image Template Creation Script

### Overview

This Bash script automates the creation of Proxmox VE virtual machine templates from various Linux cloud images. It downloads specified cloud images, configures them with cloud-init (setting up a user, SSH keys or password, networking, etc.), and then converts the VMs into templates ready for cloning. This allows for rapid deployment of new virtual machines.

### Acknowledgments

This script was originally based on and inspired by the great work and concepts presented in the article by apalrd: **[Creating Proxmox Cloud-Init Templates](https://www.apalrd.net/posts/2023/pve_cloud/)**.
This version incorporates several enhancements for robustness, security, and usability.

### Features

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

### Prerequisites

* A running Proxmox VE host.
* Bash shell (standard on Proxmox VE).
* The following utilities installed on the Proxmox host:
    * `wget` (for downloading images)
    * `qm` (Proxmox VE VM management tool)
    * `xz` (for decompressing `.xz` archives, if applicable)
* The script typically needs to be run as `root` or with `sudo` privileges, as `qm` commands require them.

### Configuration

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

### Usage

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

### Important Notes

* **Image URLs:** Cloud image URLs, especially for development/testing branches or newer releases, can change frequently. It's highly recommended to verify the URLs in the `images_to_create` array before each run.
* **VM IDs:** Ensure the `VM_ID`s specified are unique on your Proxmox VE system and are not already in use. The script includes a check and will skip creating templates for existing VM IDs.
* **Console Access to Cloned VMs:** After cloning a VM from a template:
    * If SSH access isn't working as expected (e.g., key mismatch, network issue), you can access the VM via the Proxmox VE web console ("Console" tab for the VM).
    * Log in with the `CI_USERNAME` and the password you set (if any). If an empty password was chosen during the setup and no valid `SSH_KEYFILE` was used, direct login for `CI_USERNAME` might not be possible without further configuration on the cloned VM.
* **Resource Usage:** Downloading images and creating templates will consume disk space and network bandwidth. Ensure your Proxmox VE host has sufficient resources.
* **Script Execution Time:** Depending on the number of images and your internet speed, the script might take a considerable amount of time to complete.

## Utility Scripts for Guest and Template Destruction

This repository also includes utility scripts to help manage and remove Proxmox VE guests (VMs/LXCs) and templates. These scripts prompt for VMIDs, confirm the targets, and then attempt to stop (if applicable) and destroy them.

**[⬆ Back to Index](#index)**

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

**[⬆ Back to Index](#index)**

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

**[⬆ Back to Index](#index)**

### `destroy_VMI.sh` - API-Based VM Destruction Script

**Purpose:**
This script provides an interactive way to destroy Proxmox VE Virtual Machines (QEMU VMs) by interacting directly with the [Proxmox VE API](https://pve.proxmox.com/pve-docs/api-viewer/). It allows for the destruction of multiple VMs, includes pre-checks, user confirmation, and an option to purge disks. Secrets (API credentials, host URL, node name) are managed using Mozilla SOPS.

**Features:**
* **API Driven:** Interacts directly with the Proxmox VE API using `curl` and `jq`.
* **Secrets Management:** Securely loads API credentials (`PVE_HOST_URL`, `APINODE`, `USERNAME`, `PASSWORD`) from a `sops`-encrypted file.
* **Interactive VMID Input:** Prompts the user to enter a space-separated list of VMIDs to target.
* **VM Validation:**
    * Checks if entered VMIDs are numeric.
    * Verifies the existence of each VM by querying its configuration via the API.
    * Retrieves and displays the name of each valid VM.
* **Summary & Confirmation:**
    * Shows a list of VMs (name and ID) that will be destroyed.
    * Reports any problematic or non-existent VMIDs.
    * Requires explicit user confirmation (typing "DESTROY") before any destructive action.
* **Disk Purge Option:** Asks the user if associated virtual disks should be completely purged.
* **Graceful Shutdown:**
    * Checks the current status of each VM.
    * If a VM is running, it attempts a graceful shutdown via an API call.
    * Waits for the shutdown to complete by polling the VM's status, with a configurable timeout.
* **Deletion:** Once a VM is confirmed to be stopped, it sends a DELETE request to the API to destroy it.
* **Reporting:** Provides a summary of successfully destroyed VMs and any VMs that failed to be destroyed or were skipped.
* **Dependency Checks:** Verifies the presence of `curl`, `jq`, `sops`, and `awk`.

**Prerequisites:**

* Proxmox VE host.
* Bash shell.
* Utilities: `curl`, `jq`, `sops`, `awk` installed on the machine where the script is run.
* A Proxmox VE user account with sufficient permissions to:
    * Read VM configuration and status.
    * Shutdown VMs.
    * Delete VMs (including purging disks if that option is used).
    * (Typically roles like `PVEVMAdmin` on the target VMs/paths, or a custom role with `VM.Audit`, `VM.PowerMgmt`, `VM.Allocate`, `VM.Config.Disk`).

**Configuration (`userPVE.secrets.env` file):**

This script requires a secrets file (e.g., `userPVE.secrets.env`) located in the directory specified by the `SCRIPTS_HOME` variable within the script. This file must be encrypted with `sops`.

The decrypted content of the secrets file should be in a `KEY=VALUE` format, with each variable on a new line. The keys are parsed case-insensitively by this script.

Example content of the **decrypted** `userPVE.secrets.env` file:

```bash
PVE_HOST_URL=https://your-proxmox-ip-or-hostname:8006
APINODE=your-proxmox-node-name
USERNAME=your-pve-username@pam_or_other_realm
PASSWORD=your-secret-password
```

* `PVE_HOST_URL`: The full base URL of your Proxmox VE API (e.g., `https://192.168.1.10:8006`).
* `APINODE`: The name of the Proxmox VE node where the VMs reside (e.g., `pve`, `homelab`).
* `USERNAME`: The Proxmox VE username, including the realm (e.g., `apiuser@pve`, `admin@pam`).
* `PASSWORD`: The password for the specified Proxmox VE user.

**Usage:**

1.  **Prepare Secrets File:** Create your `userPVE.secrets.env` file with the necessary credentials and encrypt it using `sops` (see "Brief Guide to Mozilla SOPS" below). Ensure the encrypted file is named according to the `SECRETS_FILE_NAME` variable in the script (default is `userPVE.secrets.env`).
2.  **Configure Script:** Ensure the `SCRIPTS_HOME` variable at the top of `destroy_VMI.sh` points to the directory containing your `sops`-encrypted secrets file.
3.  **Make Executable:**
```bash
chmod +x destroy_VMI.sh
```
4.  **Run the Script:**
```bash
./destroy_VMI.sh
```
    The script does not require `sudo` if the Proxmox VE user specified in the secrets file has the necessary API permissions.

5.  **Follow Prompts:** The script will guide you through the process.

**Important Notes for `destroy_VMI.sh`:**

* **Proxmox API Documenteation:** Use this URL https://pve.proxmox.com/pve-docs/api-viewer/  
* **Irreversible Action:** Destroying VMs is an irreversible action. Double-check the VMIDs and ensure you have backups if the data is critical.
* **API Rate Limiting:** While generally not an issue for a few VMs, excessive API calls could potentially be rate-limited by Proxmox VE, though this script is not designed for massive bulk operations that would typically trigger this.
* **Network Connectivity:** The machine running the script must have network access to the Proxmox VE API endpoint specified in `PVE_HOST_URL`.
* **SSL Certificates:** The script uses `curl -k` to ignore SSL certificate errors. This is common in homelab environments with self-signed certificates. For production environments, ensure proper certificate validation or remove the `-k` flag if you have valid, trusted certificates.
* **Testing:** It is **strongly recommended** to test this script on non-critical VMs first to understand its behavior and ensure it works as expected in your environment.

**[⬆ Back to Index](#index)**

### Brief Guide to Mozilla SOPS (Secrets OPerationS)

SOPS is an editor of encrypted files that supports YAML, JSON, ENV, INI, and BINARY formats and encrypts with AWS KMS, GCP KMS, Azure Key Vault, age, and PGP. It's an excellent tool for managing secrets that might be stored in Git repositories or shared securely.

**1. Installation:**

* **Linux (Debian/Ubuntu - may vary):**
    Check the [Mozilla SOPS GitHub releases page](https://github.com/getsops/sops/releases) for `DEB_PACKAGES` or official distribution packages.
```bash
# Example if available in your distribution's repository
# sudo apt update
# sudo apt install sops
```
* **macOS (using Homebrew):**
```bash
brew install sops
```
* **From GitHub Releases:** Download the appropriate binary for your system from the [Mozilla SOPS GitHub releases page](https://github.com/getsops/sops/releases) and place it in your `PATH`.

**2. `age` Key Generation (Example Master Key for SOPS):**

SOPS requires a master key for encryption. `age` is a simple, modern encryption tool that's well-supported by SOPS and easy to get started with.

* **Install `age`:**
    * Linux (Debian/Ubuntu): `sudo apt install age` (or build from source)
    * macOS (Homebrew): `brew install age`
* **Generate an `age` keypair:**
```bash
age-keygen -o key.txt
```
    This command creates a file named `key.txt`. This file contains:
    * **Public Key:** Starts with `age1...`. This is what you provide to SOPS (or list in `.sops.yaml`) to define who can decrypt the file.
    * **Private Key:** The secret part. This is what SOPS uses (when available) to actually decrypt the data. **Keep your private key extremely secure!**

    You can view the public key by opening `key.txt` or by extracting it:
```bash
cat key.txt | grep publickey | awk '{print $NF}'
# or if it's the only age1... string:
# grep -o 'age1[a-z0-9]*' key.txt
```
    Store your `age` private key securely. Common locations are `~/.config/sops/age/keys.txt` (one private key per line) or by setting the `SOPS_AGE_KEY` environment variable to the private key string itself.

**3. SOPS Usage Examples (with `age`):**

Let's assume your `age` public key is `age1ql3z7hjy5z0vtv5hrpv3h3x0rgv266jfw550ljxrs6qdrj38k2qshhrk7t` (this is an example public key).

* **Encrypting a new secrets file (`my_secrets.env`):**
    Suppose `my_secrets.env` contains your sensitive data:
```bash
API_TOKEN=verysecrettoken
DB_PASSWORD=anothersecret
```
    To encrypt this file so that only holders of the corresponding `age` private key can decrypt it:
```bash
sops --encrypt --age age1ql3z7hjy5z0vtv5hrpv3h3x0rgv266jfw550ljxrs6qdrj38k2qshhrk7t my_secrets.env > my_secrets.sops.env
```
    Now, `my_secrets.sops.env` is the encrypted version. You can safely commit this encrypted file to Git.

* **Using a `.sops.yaml` configuration file (Recommended):**
    Create a file named `.sops.yaml` in the same directory (or a parent directory) as your secrets files:
```bash
# .sops.yaml
creation_rules:
  - path_regex: .*\.secrets\.env$ # Regex to match your secret files
    # kms: # Example for AWS KMS (if you were using it)
    #   - arn: "arn:aws:kms:us-east-1:123456789012:key/your-kms-key-id"
    age: age1ql3z7hjy5z0vtv5hrpv3h3x0rgv266jfw550ljxrs6qdrj38k2qshhrk7t # Your age public key
    # pgp: # Example for PGP
    #   - "YOUR_PGP_FINGERPRINT"
```
    With `.sops.yaml` in place, SOPS can automatically determine which key(s) to use for encryption based on the filename:
```bash
# Encrypts using rules from .sops.yaml if path_regex matches
sops --encrypt my_secrets.env > my_secrets.enc.env
```
    For the script `destroy_VMI.sh`, if your encrypted file is `userPVE.secrets.env`, your `path_regex` in `.sops.yaml` might be `userPVE\.secrets\.env$`.

* **Editing an encrypted file:**
    SOPS will decrypt the file to a temporary location, open it in your default editor (`$EDITOR`), and then re-encrypt it when you save and close the editor.
```bash
# This requires your age private key to be accessible (e.g., in ~/.config/sops/age/keys.txt or SOPS_AGE_KEY env var)
sops my_secrets.sops.env
```

* **Decrypting a file (e.g., for viewing or for scripts like `destroy_VMI.sh`):**
    The `destroy_VMI.sh` script uses `sops -d <filename>` internally to get the decrypted content.
    To decrypt and print to standard output:
```bash
sops --decrypt my_secrets.sops.env
```
    To decrypt and save to a new (unencrypted) file (be careful with unencrypted secrets!):
```bash
sops --decrypt my_secrets.sops.env > my_secrets.decrypted.env
```

**Note on SOPS and the `destroy_VMI.sh` Script:**
The script expects the `sops`-encrypted file to be named according to the `SECRETS_FILE_NAME` variable (default: `userPVE.secrets.env`) and located in the directory specified by `SCRIPTS_HOME`. When `sops -d` is called by the script, it decrypts the content to standard output, which the script then parses. For this to work, the environment where the script runs must have access to the necessary decryption key (e.g., the `age` private key via `SOPS_AGE_KEY` environment variable or the `~/.config/sops/age/keys.txt` file).

**[⬆ Back to Index](#index)**

### Accessing and Troubleshooting Proxmox VE VMs via Web Console

For detailed steps on accessing the VM console and troubleshooting common login or configuration issues, especially for VMs created from templates, please refer to the dedicated guide:
[TROUBLESHOOTING_VM_CONSOLE_ACCESS.md](TROUBLESHOOTING_VM_CONSOLE_ACCESS.md)

This guide covers:
* Accessing the Proxmox VE web console.
* Logging in with cloud-init credentials.
* Troubleshooting steps like re-configuring cloud-init, using single-user mode, or booting from a live ISO.
* Quick tips for SSH issues once console access is gained.

**[⬆ Back to Index](#index)**


## Disclaimer

Please note that English is not my native language. AI tools were utilized to assist with translation and refinement of this README file to ensure clarity and accuracy.
