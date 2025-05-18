#!/bin/bash

# Option for purging disks (base images of templates)
PURGE_DISKS=false

# Helper function to get template name (similar to VMs)
get_template_name() {
    local id="$1"
    local name=""
    # qm list output: VMID NAME STATUS ...
    name=$(qm list --vmid "$id" --full --noheader --noborder 2>/dev/null | awk '{print $2}')

    if [[ -z "$name" ]] || [[ "$name" == "-" ]]; then
        # Fallback if qm list didn't provide a name
        name=$(qm config "${id}" 2>/dev/null | grep "^name:" | awk '{print $2}')
        if [[ -z "$name" ]]; then # Further fallback if needed
             name=$(qm status "${id}" --verbose yes 2>/dev/null | grep "name:" | cut -d" " -f 2)
        fi
    fi
    echo "$name"
}

# --- Main Script ---
echo "Proxmox VE Template Destruction Script"
echo "------------------------------------"

# Ask about purging disks
read -p "Do you want to completely purge associated disk images (base images)? (yes/no) [no]: " -r purge_confirm
if [[ "${purge_confirm,,}" == "yes" ]]; then # ,, converts to lowercase (bash 4.0+)
    PURGE_DISKS=true
    echo "Disk image purging ENABLED."
else
    echo "Disk image purging DISABLED (configuration will be removed, base disk images might remain on some storage types)."
fi
echo ""

read -p "Enter VMIDs of Templates to destroy, separated by spaces: " -a template_vmids_input

problems=()
valid_templates_details=() # Will store "id:name"

# Validate Template VMIDs
echo "Validating Template VMIDs..."
for vmid in "${template_vmids_input[@]}"; do
    if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
        problems+=("$vmid (not a valid numeric ID)")
        continue
    fi

    # First, check if a KVM guest with this ID exists
    if ! qm status "$vmid" > /dev/null 2>&1; then
        problems+=("$vmid (does not exist as a KVM guest or not accessible)")
        continue
    fi

    # Then, check if this KVM guest is a template
    if qm config "$vmid" 2>/dev/null | grep -qw "template: 1"; then
        name=$(get_template_name "$vmid")
        [[ -z "$name" ]] && name="<unknown_name>"
        valid_templates_details+=("$vmid:$name")
    else
        problems+=("$vmid (exists as a KVM guest, but is NOT a template)")
    fi
done

# Display summary
if [ ${#valid_templates_details[@]} -eq 0 ] && [ ${#problems[@]} -eq 0 ]; then
    echo "No Template VMIDs entered."
    exit 0
fi

echo ""
echo "--- Summary of Templates for Destruction ---"
if [ ${#valid_templates_details[@]} -gt 0 ]; then
    echo "Templates to be destroyed:"
    for detail in "${valid_templates_details[@]}"; do
        IFS=':' read -r id name <<< "$detail"
        echo "  - $name ($id)"
    done
fi

if [ ${#problems[@]} -gt 0 ]; then
    echo ""
    echo "Problems found (these IDs will be skipped or are not templates):"
    for problem in "${problems[@]}"; do
        echo "  - $problem"
    done
fi

if [ ${#valid_templates_details[@]} -eq 0 ]; then
    echo ""
    echo "No valid Templates found to destroy."
    exit 0
fi

echo ""
if $PURGE_DISKS; then
    echo "WARNING: Associated disk images (base images) WILL BE COMPLETELY PURGED."
else
    echo "Note: Associated disk images might NOT be purged depending on the storage type."
fi
read -p "Type 'DESTROY' to confirm the destruction of the listed Templates: " confirm

destroyed_successfully=()
failed_to_destroy=() # Store "name (id) (reason)"

if [ "$confirm" != "DESTROY" ]; then
    echo "Destruction aborted by user."
    exit 1
fi

echo ""
echo "--- Starting Template Destruction Process ---"

for detail in "${valid_templates_details[@]}"; do
    IFS=':' read -r vmid name <<< "$detail"
    name_for_log="$name (Template $vmid)"

    echo "Processing $name_for_log..."

    # Templates are not "running" and do not require "stopping".
    # A status check can be useful for diagnostics if deletion fails.
    current_status_output=$(qm status "$vmid" 2>/dev/null)
    rc_status=$?

    if [ $rc_status -ne 0 ]; then
        echo "  Error: Could not get status for $name_for_log. It might have been deleted already. Skipping."
        failed_to_destroy+=("$name_for_log (could not get status or already deleted)")
        continue
    fi

    destroy_cmd=("qm" "destroy" "$vmid")
    if $PURGE_DISKS; then
        destroy_cmd+=("--purge")
        destroy_cmd+=("--destroy-unreferenced-disks" "1") # For added certainty
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
done

echo ""
echo "--- Template Destruction Finished ---"
if [ ${#destroyed_successfully[@]} -gt 0 ]; then
    echo "Successfully destroyed Templates:"
    for item in "${destroyed_successfully[@]}"; do
        echo "  - $item"
    done
fi
if [ ${#failed_to_destroy[@]} -gt 0 ]; then
    echo "Failed to destroy or skipped Templates:"
    for item in "${failed_to_destroy[@]}"; do
        echo "  - $item"
    done
fi

exit 0
