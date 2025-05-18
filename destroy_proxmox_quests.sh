#!/bin/bash

# Option for purging disks
PURGE_DISKS=false

# Helper function to get guest name
get_guest_name() {
    local type_cmd="$1" # "qm" or "pct"
    local id="$2"
    local name=""

    if [[ "$type_cmd" == "qm" ]]; then
        # qm list output: VMID NAME STATUS ...
        name=$(qm list --vmid "$id" --full --noheader --noborder 2>/dev/null | awk '{print $2}')
    elif [[ "$type_cmd" == "pct" ]]; then
        # pct list output: VMID STATUS LOCK NAME
        name=$(pct list --vmid "$id" --noheader --noborder 2>/dev/null | awk '{print $NF}') # NF - last field
    fi

    # Fallback to the original script's method if the list command failed or returned no name
    if [[ -z "$name" ]] || [[ "$name" == "-" ]]; then # Sometimes the name can be "-"
        if [[ "$type_cmd" == "qm" ]]; then
            name=$(qm status "${id}" --verbose yes 2>/dev/null | grep "name:" | cut -d" " -f 2)
        elif [[ "$type_cmd" == "pct" ]]; then
            name=$(pct status "${id}" --verbose yes 2>/dev/null | grep "name:" | cut -d" " -f 2)
        fi
    fi
    echo "$name"
}


# Main script
echo "Proxmox VM/LXC Destruction Script"
echo "---------------------------------"

# Ask about purging disks
read -p "Do you want to completely purge associated disks? (yes/no) [no]: " -r purge_confirm
if [[ "${purge_confirm,,}" == "yes" ]]; then # ,, converts to lowercase (bash 4.0+)
    PURGE_DISKS=true
    echo "Disk purging ENABLED."
else
    echo "Disk purging DISABLED (configuration will be removed, disks might remain on some storage types)."
fi
echo ""


read -p "Enter VMIDs of VMs/LXCs to destroy, separated by spaces: " -a vmids_input

vms=()
lxcs=()
problems=()
valid_vmids_details=() # Will store "type:id:name"

# Validate and categorize VMIDs
echo "Validating VMIDs..."
for vmid in "${vmids_input[@]}"; do
    if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
        problems+=("$vmid (not a valid numeric ID)")
        continue
    fi

    # Check if VMID is a virtual machine
    if qm status "$vmid" > /dev/null 2>&1; then
        name=$(get_guest_name "qm" "$vmid")
        [[ -z "$name" ]] && name="<unknown_name>"
        vms+=("$vmid")
        valid_vmids_details+=("VM:$vmid:$name")
    # Check if VMID is an LXC container
    elif pct status "$vmid" > /dev/null 2>&1; then
        name=$(get_guest_name "pct" "$vmid")
        [[ -z "$name" ]] && name="<unknown_name>"
        lxcs+=("$vmid")
        valid_vmids_details+=("LXC:$vmid:$name")
    else
        problems+=("$vmid (does not exist or not accessible)")
    fi
done

# Display summary
if [ ${#valid_vmids_details[@]} -eq 0 ] && [ ${#problems[@]} -eq 0 ]; then
    echo "No VMIDs entered."
    exit 0
fi

echo ""
echo "--- Summary of Guests for Destruction ---"
if [ ${#vms[@]} -gt 0 ]; then
    echo "VMs to be destroyed:"
    for detail in "${valid_vmids_details[@]}"; do
        IFS=':' read -r type id name <<< "$detail"
        if [[ "$type" == "VM" ]]; then
            echo "  - $name ($id)"
        fi
    done
fi

if [ ${#lxcs[@]} -gt 0 ]; then
    echo "LXCs to be destroyed:"
    for detail in "${valid_vmids_details[@]}"; do
        IFS=':' read -r type id name <<< "$detail"
        if [[ "$type" == "LXC" ]]; then
            echo "  - $name ($id)"
        fi
    done
fi

if [ ${#problems[@]} -gt 0 ]; then
    echo ""
    echo "Problems found (these IDs will be skipped):"
    for problem in "${problems[@]}"; do
        echo "  - $problem"
    done
fi

if [ ${#valid_vmids_details[@]} -eq 0 ]; then
    echo ""
    echo "No valid VMs or LXCs found to destroy."
    exit 0
fi

echo ""
if $PURGE_DISKS; then
    echo "WARNING: Associated disks WILL BE COMPLETELY PURGED."
else
    echo "Note: Associated disks might NOT be purged depending on the storage type."
fi
read -p "Type 'DESTROY' to confirm the destruction of the listed guests: " confirm

destroyed_successfully=()
failed_to_destroy=() # Store "id (reason)"

if [ "$confirm" != "DESTROY" ]; then
    echo "Destruction aborted by user."
    exit 1
fi

echo ""
echo "--- Starting Destruction Process ---"

# Process VMs
for vmid in "${vms[@]}"; do
    name_for_log=$(get_guest_name "qm" "$vmid")
    [[ -z "$name_for_log" ]] && name_for_log="VM $vmid" || name_for_log="$name_for_log (VM $vmid)"
    echo "Processing $name_for_log..."
    is_stopped=false
    current_status_output=$(qm status "$vmid" 2>/dev/null)
    rc_status=$?

    if [ $rc_status -ne 0 ]; then
        echo "  Error: Could not get status for $name_for_log. Skipping."
        failed_to_destroy+=("$name_for_log (could not get status)")
        continue
    fi

    if [[ "$current_status_output" == "status: running" ]]; then
        echo "  $name_for_log is running. Attempting to stop (timeout 60s)..."
        if qm stop "$vmid" --timeout 60; then
            echo "  $name_for_log stopped successfully."
            is_stopped=true
        else
            echo "  Error: Failed to stop $name_for_log. Skipping destruction."
            failed_to_destroy+=("$name_for_log (failed to stop)")
            continue
        fi
    elif [[ "$current_status_output" == "status: stopped" ]]; then
        is_stopped=true
        echo "  $name_for_log is already stopped."
    else
        echo "  Warning: $name_for_log is in state: '$current_status_output'. Not 'running' or 'stopped'. Skipping destruction."
        failed_to_destroy+=("$name_for_log (state '$current_status_output' not processed)")
        continue
    fi

    if $is_stopped; then
        destroy_cmd=("qm" "destroy" "$vmid")
        if $PURGE_DISKS; then
            destroy_cmd+=("--purge")
            destroy_cmd+=("--destroy-unreferenced-disks" "1") # To be sure
        fi
        # Optional: add --skiplock true if lock issues occur, but be careful
        # destroy_cmd+=("--skiplock" "true")

        echo "  Destroying $name_for_log (${destroy_cmd[*]}) ..."
        if "${destroy_cmd[@]}"; then
            echo "  $name_for_log destroyed successfully."
            destroyed_successfully+=("$name_for_log")
        else
            echo "  Error: Failed to destroy $name_for_log!"
            failed_to_destroy+=("$name_for_log (failed to destroy)")
        fi
    fi
done

# Process LXCs
for vmid in "${lxcs[@]}"; do
    name_for_log=$(get_guest_name "pct" "$vmid")
    [[ -z "$name_for_log" ]] && name_for_log="LXC $vmid" || name_for_log="$name_for_log (LXC $vmid)"
    echo "Processing $name_for_log..."
    is_stopped=false
    current_status_output=$(pct status "$vmid" 2>/dev/null)
    rc_status=$?

    if [ $rc_status -ne 0 ]; then
        echo "  Error: Could not get status for $name_for_log. Skipping."
        failed_to_destroy+=("$name_for_log (could not get status)")
        continue
    fi

    if [[ "$current_status_output" == "status: running" ]]; then
        echo "  $name_for_log is running. Attempting to stop (timeout 60s)..."
        if pct stop "$vmid" --timeout 60; then
            echo "  $name_for_log stopped successfully."
            is_stopped=true
        else
            echo "  Error: Failed to stop $name_for_log. Skipping destruction."
            failed_to_destroy+=("$name_for_log (failed to stop)")
            continue
        fi
    elif [[ "$current_status_output" == "status: stopped" ]]; then
        is_stopped=true
        echo "  $name_for_log is already stopped."
    else
        echo "  Warning: $name_for_log is in state: '$current_status_output'. Not 'running' or 'stopped'. Skipping destruction."
        failed_to_destroy+=("$name_for_log (state '$current_status_output' not processed)")
        continue
    fi

    if $is_stopped; then
        destroy_cmd=("pct" "destroy" "$vmid")
        if $PURGE_DISKS; then
            destroy_cmd+=("--purge")
        fi
        # Optional: add --force 1 if containers are stubborn, but be cautious
        # destroy_cmd+=("--force" "1")

        echo "  Destroying $name_for_log (${destroy_cmd[*]}) ..."
        if "${destroy_cmd[@]}"; then
            echo "  $name_for_log destroyed successfully."
            destroyed_successfully+=("$name_for_log")
        else
            echo "  Error: Failed to destroy $name_for_log!"
            failed_to_destroy+=("$name_for_log (failed to destroy)")
        fi
    fi
done

echo ""
echo "--- Destruction Finished ---"
if [ ${#destroyed_successfully[@]} -gt 0 ]; then
    echo "Successfully destroyed:"
    for item in "${destroyed_successfully[@]}"; do
        echo "  - $item"
    done
fi
if [ ${#failed_to_destroy[@]} -gt 0 ]; then
    echo "Failed to destroy or skipped:"
    for item in "${failed_to_destroy[@]}"; do
        echo "  - $item"
    done
fi

exit 0
