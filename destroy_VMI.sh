#!/bin/bash

# --- Configuration ---
# SCRIPTS_HOME defines where the secrets file is located.
# Update this path if your secrets file is elsewhere.
SCRIPTS_HOME="/home/abevz/scripts"      # Ensure this is the correct path to the directory of your secrets file
SECRETS_FILE_NAME="userPVE.secrets.env" # The name of your sops encrypted secrets file

# Default values if not found in secrets (though script will exit if they are missing)
PVE_HOST_URL=""
APINODE=""
USERNAME=""
PASSWORD=""

PURGE_DISKS=false
VM_SHUTDOWN_TIMEOUT_SECONDS=120 # Max time to wait for VM shutdown (in seconds)
VM_POLL_INTERVAL_SECONDS=10     # Interval to check VM status during shutdown

# --- Dependency Checks ---
command -v curl >/dev/null 2>&1 || {
  echo >&2 "Error: 'curl' is not installed. Please install it."
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo >&2 "Error: 'jq' is not installed. Please install it."
  exit 1
}
command -v sops >/dev/null 2>&1 || {
  echo >&2 "Error: 'sops' is not installed. Please install it."
  exit 1
}
command -v awk >/dev/null 2>&1 || {
  echo >&2 "Error: 'awk' is not installed. Please install it."
  exit 1
}

# --- Load Secrets and Authenticate to Proxmox VE API ---
SECRETS_FILE_PATH="$SCRIPTS_HOME/$SECRETS_FILE_NAME"
echo "Loading credentials and connecting to Proxmox VE API..."

if [[ ! -f "$SECRETS_FILE_PATH" ]]; then
  echo "Error: Secrets file '$SECRETS_FILE_PATH' not found."
  exit 1
fi

decrypted_secrets=$(sops -d "$SECRETS_FILE_PATH" 2>/dev/null)
if [[ $? -ne 0 ]]; then
  echo "Error: sops failed to decrypt the secrets file '$SECRETS_FILE_PATH'."
  exit 1
fi

# Extract secrets using awk for robustness (case-insensitive keys)
PVE_HOST_URL=$(echo "$decrypted_secrets" | awk -F= 'tolower($1)=="pve_host_url" {print $2; exit}')
APINODE=$(echo "$decrypted_secrets" | awk -F= 'tolower($1)=="apinode" {print $2; exit}')
USERNAME=$(echo "$decrypted_secrets" | awk -F= 'tolower($1)=="username" {print $2; exit}')
PASSWORD=$(echo "$decrypted_secrets" | awk -F= 'tolower($1)=="password" {print $2; exit}')

if [[ -z "$PVE_HOST_URL" ]] || [[ -z "$APINODE" ]] || [[ -z "$USERNAME" ]] || [[ -z "$PASSWORD" ]]; then
  echo "Error: One or more required variables (PVE_HOST_URL, APINODE, USERNAME, PASSWORD) not found in '$SECRETS_FILE_PATH' after decryption."
  echo "Please ensure your secrets file contains lines like:"
  echo "PVE_HOST_URL=https://your-proxmox-ip-or-hostname:8006"
  echo "APINODE=your-proxmox-node-name"
  echo "USERNAME=your-pve-username@pam"
  echo "PASSWORD=your-password"
  exit 1
fi

auth_response=$(curl -sS -k -X POST \
  -d "username=$USERNAME" \
  --data-urlencode "password=$PASSWORD" \
  "${PVE_HOST_URL}/api2/json/access/ticket")

PVEAuthCookie=$(echo "$auth_response" | jq --raw-output '.data.ticket')
CSRFPreventionToken=$(echo "$auth_response" | jq --raw-output '.data.CSRFPreventionToken')

if [[ -z "$PVEAuthCookie" ]] || [[ "$PVEAuthCookie" == "null" ]] ||
  [[ -z "$CSRFPreventionToken" ]] || [[ "$CSRFPreventionToken" == "null" ]]; then
  echo "Error: Failed to obtain PVEAuthCookie or CSRFPreventionToken."
  echo "API Response: $auth_response"
  exit 1
fi
echo "Authentication successful."
echo ""

# --- User Input ---
read -p "Do you want to completely purge associated disks? (yes/no) [no]: " -r purge_confirm
if [[ "${purge_confirm,,}" == "yes" ]]; then # ,, converts to lowercase (bash 4.0+)
  PURGE_DISKS=true
  echo "Disk purging ENABLED."
else
  echo "Disk purging DISABLED."
fi
echo ""

read -p "Enter VMIDs of Virtual Machines (QEMU) to destroy, separated by spaces: " -a vmids_input

declare -a vms_to_process_details=() # Array for "vmid:name"
declare -a problem_vmids=()

echo "Validating VMIDs and fetching VM information..."
for vmid in "${vmids_input[@]}"; do
  if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
    problem_vmids+=("$vmid (not a number)")
    continue
  fi

  # Get VM configuration to check existence and name
  vm_config_json=$(curl -sS -k \
    -H "Cookie: PVEAuthCookie=$PVEAuthCookie" \
    -H "CSRFPreventionToken: $CSRFPreventionToken" \
    "${PVE_HOST_URL}/api2/json/nodes/${APINODE}/qemu/${vmid}/config")

  # Check for successful API request and data presence
  if echo "$vm_config_json" | jq -e '.data' >/dev/null 2>&1; then
    vm_name=$(echo "$vm_config_json" | jq -r '.data.name')
    if [[ -n "$vm_name" ]]; then
      vms_to_process_details+=("$vmid:$vm_name")
      echo "  Found VM: $vm_name ($vmid)"
    else
      # This case should ideally not happen if .data exists but name is missing
      problem_vmids+=("$vmid (could not retrieve name, VM might be malformed or access issue)")
    fi
  else
    problem_vmids+=("$vmid (not found or API error fetching config)")
  fi
done

# --- Display Summary and Request Confirmation ---
echo ""
if [ ${#vms_to_process_details[@]} -eq 0 ]; then
  echo "No valid VMs found to destroy."
  if [ ${#problem_vmids[@]} -gt 0 ]; then
    echo "Problems were encountered with the following VMIDs:"
    for problem in "${problem_vmids[@]}"; do
      echo "  - $problem"
    done
  fi
  exit 0
fi

echo "--- The following VMs will be targeted for destruction ---"
for detail in "${vms_to_process_details[@]}"; do
  IFS=':' read -r id name <<<"$detail"
  echo "  - $name ($id)"
done

if [ ${#problem_vmids[@]} -gt 0 ]; then
  echo ""
  echo "Problems with the following VMIDs (they will be skipped):"
  for problem in "${problem_vmids[@]}"; do
    echo "  - $problem"
  done
fi

echo ""
if $PURGE_DISKS; then
  echo "WARNING: Associated disks WILL BE COMPLETELY PURGED."
fi
read -p "Type 'DESTROY' to confirm the destruction of the listed VMs: " confirm

if [ "$confirm" != "DESTROY" ]; then
  echo "Destruction aborted by user."
  exit 1
fi

# --- Destruction Process ---
echo ""
echo "--- Starting VM Destruction Process ---"
declare -a destroyed_successfully=()
declare -a failed_to_destroy=()

for detail in "${vms_to_process_details[@]}"; do
  IFS=':' read -r vmid vm_name <<<"$detail"
  vm_log_name="$vm_name ($vmid)"
  echo "Processing VM: $vm_log_name"

  # 1. Get current VM status
  echo "  Fetching status for VM $vm_log_name..."
  status_response_json=$(curl -sS -k \
    -H "Cookie: PVEAuthCookie=$PVEAuthCookie" \
    -H "CSRFPreventionToken: $CSRFPreventionToken" \
    "${PVE_HOST_URL}/api2/json/nodes/${APINODE}/qemu/${vmid}/status/current")

  current_vm_status=$(echo "$status_response_json" | jq -r '.data.status')
  qmp_status=$(echo "$status_response_json" | jq -r '.data.qmpstatus') # qmpstatus can be more accurate

  if [[ -z "$current_vm_status" ]] || [[ "$current_vm_status" == "null" ]]; then
    echo "  Error: Failed to get status for VM $vm_log_name. API Response: $status_response_json"
    failed_to_destroy+=("$vm_log_name (failed to get status)")
    continue
  fi
  echo "  Current VM status: $current_vm_status (QMP: $qmp_status)"

  is_stopped=false
  if [[ "$qmp_status" == "stopped" ]] || [[ "$current_vm_status" == "stopped" ]]; then
    is_stopped=true
    echo "  VM $vm_log_name is already stopped."
  elif [[ "$qmp_status" == "running" ]] || [[ "$current_vm_status" == "running" ]]; then
    echo "  VM $vm_log_name is running. Attempting shutdown..."
    # Send shutdown command
    shutdown_post_response=$(curl -sS -k -w "\nHTTP_CODE:%{http_code}" \
      -H "Cookie: PVEAuthCookie=$PVEAuthCookie" \
      -H "CSRFPreventionToken: $CSRFPreventionToken" \
      -X POST \
      "${PVE_HOST_URL}/api2/json/nodes/${APINODE}/qemu/${vmid}/status/shutdown")

    http_code_shutdown=$(echo -e "$shutdown_post_response" | grep "HTTP_CODE:" | sed 's/HTTP_CODE://')
    response_body_shutdown=$(echo -e "$shutdown_post_response" | sed '$d') # Response body

    if [[ "$http_code_shutdown" -ne 200 ]]; then
      echo "  Error: Shutdown command for VM $vm_log_name failed (HTTP $http_code_shutdown). Response: $response_body_shutdown"
      failed_to_destroy+=("$vm_log_name (shutdown command failed)")
      continue
    else
      echo "  Shutdown command sent. Waiting for VM to stop (max $VM_SHUTDOWN_TIMEOUT_SECONDS seconds)..."
      elapsed_time=0
      while [[ $elapsed_time -lt $VM_SHUTDOWN_TIMEOUT_SECONDS ]]; do
        sleep $VM_POLL_INTERVAL_SECONDS
        elapsed_time=$((elapsed_time + VM_POLL_INTERVAL_SECONDS))

        status_check_json=$(curl -sS -k \
          -H "Cookie: PVEAuthCookie=$PVEAuthCookie" \
          -H "CSRFPreventionToken: $CSRFPreventionToken" \
          "${PVE_HOST_URL}/api2/json/nodes/${APINODE}/qemu/${vmid}/status/current")

        current_qmp_status_poll=$(echo "$status_check_json" | jq -r '.data.qmpstatus')
        echo "    Status check ($elapsed_time s): QMP status - $current_qmp_status_poll"

        if [[ "$current_qmp_status_poll" == "stopped" ]]; then
          is_stopped=true
          echo "  VM $vm_log_name stopped successfully."
          break
        fi
      done

      if ! $is_stopped; then
        echo "  Error: VM $vm_log_name did not stop within $VM_SHUTDOWN_TIMEOUT_SECONDS seconds."
        failed_to_destroy+=("$vm_log_name (shutdown timeout)")
        continue # Proceed to the next VM
      fi
    fi
  else
    echo "  Warning: VM $vm_log_name is in state '$current_vm_status' (QMP: '$qmp_status'). Deletion might not be possible without a force stop (not implemented in this script)."
    failed_to_destroy+=("$vm_log_name (unsupported state for automatic deletion)")
    continue
  fi

  # 2. Delete VM if stopped
  if $is_stopped; then
    echo "  Attempting to delete VM $vm_log_name..."
    delete_url_path="/api2/json/nodes/${APINODE}/qemu/${vmid}"
    delete_params=""
    if $PURGE_DISKS; then
      # For PVE API, DELETE parameters are typically query parameters in the URL
      delete_params="?purge=1&destroy-unreferenced-disks=1"
    fi

    delete_response=$(curl -sS -k -w "\nHTTP_CODE:%{http_code}" \
      -H "Cookie: PVEAuthCookie=$PVEAuthCookie" \
      -H "CSRFPreventionToken: $CSRFPreventionToken" \
      -X DELETE \
      "${PVE_HOST_URL}${delete_url_path}${delete_params}")

    http_code_delete=$(echo -e "$delete_response" | grep "HTTP_CODE:" | sed 's/HTTP_CODE://')
    response_body_delete=$(echo -e "$delete_response" | sed '$d')

    # Successful deletion usually returns HTTP 200 and contains a task ID.
    if [[ "$http_code_delete" -eq 200 ]]; then
      echo "  VM $vm_log_name successfully deleted. Task ID: $(echo "$response_body_delete" | jq -r '.data')"
      destroyed_successfully+=("$vm_log_name")
    else
      echo "  Error: Failed to delete VM $vm_log_name (HTTP $http_code_delete)."
      echo "  API Response: $response_body_delete"
      failed_to_destroy+=("$vm_log_name (delete failed)")
    fi
  fi
done

# --- Final Report ---
echo ""
echo "--- Destruction Process Finished ---"
if [ ${#destroyed_successfully[@]} -gt 0 ]; then
  echo "Successfully destroyed VMs:"
  for item in "${destroyed_successfully[@]}"; do
    echo "  - $item"
  done
fi
if [ ${#failed_to_destroy[@]} -gt 0 ]; then
  echo "Failed to destroy or skipped VMs:"
  for item in "${failed_to_destroy[@]}"; do
    echo "  - $item"
  done
fi

echo "Completed."
exit 0
