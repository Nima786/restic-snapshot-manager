#!/bin/bash

# ==============================================================================
# Universal Server Snapshot Script v7.4 (The Definitive, Final Version)
# ==============================================================================
# A professional, menu-driven script to create, manage, and restore
# full server snapshots on any Ubuntu system.
#
# v7.4 Changelog:
# - FINAL POLISH: Added a clear header to the post-backup summary to make it
#   easier for the user to see what was processed and how much data was added.
# ==============================================================================

# --- Configuration ---
BACKUP_DIR="/var/backups/restic-repo"
PASSWORD_FILE="/etc/restic/password"
RESTORE_TEMP_DIR_BASE="/restic_restore_temp"
MIN_FREE_SPACE_GB=5
# --- End Configuration ---


# --- Global Variable ---
SNAPSHOT_IDS=()


# --- Helper Functions ---
clear_screen() { clear; }
press_enter_to_continue() { echo ""; read -r -p "Press [Enter] to continue..."; }


# --- Core Logic Functions ---

check_and_install_dependencies() {
    local -a missing_packages=()
    if ! command -v restic &> /dev/null; then missing_packages+=("restic"); fi
    if ! command -v rsync &> /dev/null; then missing_packages+=("rsync"); fi
    if ! command -v jq &> /dev/null; then missing_packages+=("jq"); fi
    if ! command -v bc &> /dev/null; then missing_packages+=("bc"); fi

    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "The following required packages are not installed: ${missing_packages[*]}"
        read -r -p "Do you want to install them now? (Y/n): " choice
        choice=${choice:-Y}
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            apt-get update && apt-get install -y "${missing_packages[@]}"
        else
            echo "Installation aborted."; exit 1
        fi
    fi
}

initialize_repo() {
    clear_screen
    echo "--- Initialize Backup Repository ---"
    if [ -d "$BACKUP_DIR" ]; then echo "Error: Backup directory '$BACKUP_DIR' already exists."; return; fi

    mkdir -p "$(dirname "$PASSWORD_FILE")"
    openssl rand -base64 32 > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"

    echo "Creating Restic repository at $BACKUP_DIR..."
    restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" init
    echo -e "\nInitialization complete!"
}

check_disk_space_for_backup() {
    echo "Checking for available disk space..."
    local available_kb
    available_kb=$(df -k --output=avail "$BACKUP_DIR" | tail -n 1)
    local available_gb=$((available_kb / 1024 / 1024))

    local total_snapshots
    total_snapshots=$(restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" snapshots --json | jq 'length')

    if [ "$total_snapshots" -eq 0 ]; then
        echo "This is the first backup. Calculating required space..."
        local used_kb
        used_kb=$(du -skx --exclude='/var/cache' --exclude='/var/tmp' --exclude='/tmp' --exclude='/home/*/.cache' --exclude='/var/log' --exclude='/proc' --exclude='/sys' --exclude='/dev' --exclude='/run' --exclude='/mnt' --exclude='/media' --exclude='/snap' --exclude='/swap.img' --exclude="$BACKUP_DIR" --exclude="$RESTORE_TEMP_DIR_BASE" / /boot | awk '{s+=$1} END {print s}')
        local required_kb=$((used_kb * 110 / 100)) # 10% buffer
        local required_gb=$((required_kb / 1024 / 1024))

        echo "-> Required: ~${required_gb} GB | Available: ${available_gb} GB"

        if [ "$available_kb" -lt "$required_kb" ]; then
            echo "============================ ERROR ============================"
            echo "Not enough disk space for the first backup."
            echo "==============================================================="
            return 1
        fi
    else
        echo "Checking for minimum free space for subsequent backup..."
        local min_free_kb=$((MIN_FREE_SPACE_GB * 1024 * 1024))
        
        echo "-> Required: ~${MIN_FREE_SPACE_GB} GB | Available: ${available_gb} GB"

        if [ "$available_kb" -lt "$min_free_kb" ]; then
            echo "============================ ERROR ============================"
            echo "Not enough free disk space for a new backup."
            echo "==============================================================="
            return 1
        fi
    fi
    echo "Disk space check passed."
    return 0
}

create_backup() {
    clear_screen
    echo "--- Create a New Server Snapshot ---"

    if ! check_disk_space_for_backup; then
        return 1
    fi

    local -a running_containers=()
    if command -v docker &> /dev/null && docker info >/dev/null 2>&1; then
        echo "Docker detected. Stopping containers..."
        mapfile -t running_containers < <(docker ps -q)
        if [ ${#running_containers[@]} -gt 0 ]; then
            docker stop "${running_containers[@]}"
        fi
    fi

    echo "Starting backup of / and /boot..."
    echo "--------------------------- BACKUP SUMMARY ---------------------------"
    restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" backup \
        --tag "manual-snapshot" \
        --exclude='/var/cache' --exclude='/var/tmp' --exclude='/tmp' \
        --exclude='/home/*/.cache' --exclude='/var/log' --exclude='/proc' \
        --exclude='/sys' --exclude='/dev' --exclude='/run' --exclude='/mnt' \
        --exclude='/media' --exclude='/snap' --exclude='/swap.img' \
        --exclude="$BACKUP_DIR" --exclude="$RESTORE_TEMP_DIR_BASE" \
        / /boot
    echo "----------------------------------------------------------------------"
    echo "Snapshot created successfully."

    if [ ${#running_containers[@]} -gt 0 ]; then
        echo "Restarting containers..."
        docker start "${running_containers[@]}"
    fi
}

populate_and_display_snapshots() {
    clear_screen
    echo "--- Available Snapshots ---"
    
    local snapshot_json
    snapshot_json=$(restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" snapshots --json)
    
    mapfile -t SNAPSHOT_IDS < <(echo "$snapshot_json" | jq -r '.[].short_id')

    if [ ${#SNAPSHOT_IDS[@]} -eq 0 ]; then
        echo "No snapshots found."
        return 1
    fi

    echo " #  ID         Timestamp           Host    Tags               Paths"
    echo "--- ---------- ------------------- ------- ------------------ -----------------"
    echo "$snapshot_json" | jq -r '.[] | "\(.short_id) \(.time | split(".")[0] | gsub("T";" ")) \(.hostname) \(.tags | join(",")) \(.paths | join(" "))"' | \
    sed 's/manual-snapshot/manual-snapshot /' | \
    awk '{printf "%-3s %s\n", NR, $0}'

    echo "--------------------------------------------------------------------------------"
    return 0
}

list_backups() {
    populate_and_display_snapshots
}

delete_backup() {
    if ! populate_and_display_snapshots; then return; fi
    
    read -r -p "Enter the NUMBER of the snapshot to delete (or press Enter to cancel): " choice
    if [[ -z "$choice" ]]; then echo "Deletion cancelled."; return; fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SNAPSHOT_IDS[@]} ]; then
        echo "Invalid number. Please try again."
        return
    fi

    local selected_id=${SNAPSHOT_IDS[$((choice-1))]}
    
    read -r -p "WARNING: Permanently delete snapshot '$selected_id'? (Y/n): " confirmation
    confirmation=${confirmation:-Y}
    if [[ "$confirmation" == "y" || "$confirmation" == "Y" ]]; then
        restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" forget "$selected_id" --prune
        echo "Snapshot deleted."
    else
        echo "Deletion cancelled."
    fi
}

check_disk_space_for_restore() {
    local snapshot_id=$1
    echo "Checking for available disk space for restore..."
    
    local available_kb
    available_kb=$(df -k --output=avail / | tail -n 1)
    local available_gb=$((available_kb / 1024 / 1024))
    
    echo "Calculating true snapshot size (this may take a moment)..."
    local required_bytes
    required_bytes=$(restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" ls -l "$snapshot_id" | awk '!/^Total:/ {s+=$5} END {print s}')

    local required_kb=$((required_bytes * 105 / 100 / 1024))
    local required_gb=$((required_kb / 1024 / 1024))

    echo "-> Required: ~${required_gb} GB | Available: ${available_gb} GB"

    if [ "$available_kb" -lt "$required_kb" ]; then
        echo "============================ ERROR ============================"
        echo "Not enough disk space on the main partition to perform the restore."
        echo "==============================================================="
        return 1
    fi
    echo "Disk space check passed."
    return 0
}

restore_backup() {
    if ! populate_and_display_snapshots; then return; fi

    read -r -p "Enter the NUMBER of the snapshot to RESTORE (or press Enter to cancel): " choice
    if [[ -z "$choice" ]]; then echo "Restore cancelled."; return; fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SNAPSHOT_IDS[@]} ]; then
        echo "Invalid number. Please try again."
        return
    fi

    local selected_id=${SNAPSHOT_IDS[$((choice-1))]}

    if ! check_disk_space_for_restore "$selected_id"; then
        return 1
    fi

    clear_screen
    echo "============================ WARNING ============================"
    echo "You are about to restore the ENTIRE server to snapshot: $selected_id"
    echo "This action is IRREVERSIBLE."
    echo "================================================================="
    read -r -p "To confirm, please type 'PROCEED': " confirmation
    if [ "$confirmation" != "PROCEED" ]; then echo "Restore aborted."; return; fi

    local -a running_containers=()
    if command -v docker &> /dev/null && docker info >/dev/null 2>&1; then
        echo "Docker detected. Stopping containers..."
        mapfile -t running_containers < <(docker ps -q)
        if [ ${#running_containers[@]} -gt 0 ]; then
            docker stop "${running_containers[@]}"
        fi
    fi

    local RESTORE_TEMP_DIR
    RESTORE_TEMP_DIR="${RESTORE_TEMP_DIR_BASE}_$(date +%s)"
    
    trap 'echo -e "\n\nInterruption detected. Cleaning up temporary directory..."; rm -rf "$RESTORE_TEMP_DIR"; exit 1' INT TERM

    mkdir -p "$RESTORE_TEMP_DIR"

    echo "Step 1: Restoring snapshot to '$RESTORE_TEMP_DIR'..."
    if ! restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" restore "$selected_id" --target "$RESTORE_TEMP_DIR"; then
        echo "Error: Restic restore failed. Aborting."
        rm -rf "$RESTORE_TEMP_DIR"
        if [ ${#running_containers[@]} -gt 0 ]; then docker start "${running_containers[@]}"; fi
        trap - INT TERM
        return
    fi

    echo "Step 2: Performing atomic swap of Docker data..."
    if [ -d "$RESTORE_TEMP_DIR/var/lib/docker" ]; then
        rm -rf /var/lib/docker
        mv "$RESTORE_TEMP_DIR/var/lib/docker" /var/lib/
        echo "Docker data swapped successfully."
    else
        echo "Warning: No Docker data found in backup, skipping swap."
    fi

    echo "Step 3: Performing safe, targeted sync of system directories..."
    local -a sync_dirs_delete=("etc" "home" "root" "opt" "srv" "var/www" "var/spool" "usr/local")
    for dir in "${sync_dirs_delete[@]}"; do
        if [ -d "$RESTORE_TEMP_DIR/$dir" ]; then
            echo "-> Syncing /$dir (with deletions)..."
            rsync -aAXv --delete "$RESTORE_TEMP_DIR/$dir/" "/$dir/"
        fi
    done

    local -a sync_dirs_no_delete=("usr" "bin" "sbin" "lib" "lib64")
    for dir in "${sync_dirs_no_delete[@]}"; do
        if [ -d "$RESTORE_TEMP_DIR/$dir" ]; then
            echo "-> Syncing /$dir (additions/updates only)..."
            rsync -aAXv "$RESTORE_TEMP_DIR/$dir/" "/$dir/"
        fi
    done

    if [ -d "$RESTORE_TEMP_DIR/boot" ]; then
        echo "-> Syncing /boot..."
        rsync -aAXv --delete --exclude='/efi' "$RESTORE_TEMP_DIR/boot/" "/boot/"
    fi

    echo "Step 4: Cleaning up temporary files..."
    rm -rf "$RESTORE_TEMP_DIR"

    trap - INT TERM

    if [ ${#running_containers[@]} -gt 0 ]; then
        echo "Step 5: Restarting containers..."
        docker start "${running_containers[@]}"
        echo "Containers restarted."
    fi

    echo -e "\nRestore complete! A reboot is STRONGLY recommended."
}


# --- Main Menu & Execution ---
show_menu() {
    clear_screen
    echo "========================================"
    echo "  Universal Server Snapshot Manager v7.4"
    echo "      (The Definitive, Final Version)"
    echo "========================================"
    echo " 1) Create a Backup Snapshot"
    echo " 2) List All Snapshots"
    echo " 3) Delete a Specific Snapshot"
    echo " 4) Restore From a Snapshot"
    echo "----------------------------------------"
    echo " 0) Quit"
    echo "========================================"
}

if [ "$EUID" -ne 0 ]; then echo "This script must be run as root."; exit 1; fi

check_and_install_dependencies

if ! restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" cat config >/dev/null 2>&1; then
    echo "Backup repository not found or not accessible. You must initialize it first."
    read -r -p "Initialize now? (Y/n): " choice
    choice=${choice:-Y}
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        initialize_repo
        press_enter_to_continue
    else
        echo "Cannot proceed. Exiting."; exit 1
    fi
fi

while true; do
    show_menu
    read -r -p "Enter your choice [1-4, 0]: " choice
    case $choice in
        1) create_backup; press_enter_to_continue ;;
        2) list_backups; press_enter_to_continue ;;
        3) delete_backup; press_enter_to_continue ;;
        4) restore_backup; press_enter_to_continue ;;
        0) break ;;
        *) echo "Invalid option."; sleep 1 ;;
    esac
done

echo "Exiting Snapshot Manager."
