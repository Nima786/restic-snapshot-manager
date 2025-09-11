#!/bin/bash

# ==============================================================================
# Universal Server Snapshot Script v4.5 (The Definitive Version)
# ==============================================================================
# A professional, menu-driven script to create, manage, and restore
# full server snapshots on any Ubuntu system.
#
# v4.5 Changelog:
# - FINAL BUGFIX: Corrected the display logic to remove the redundant,
#   confusing second number from the snapshot list. The list is now
#   cleanly numbered from 1.
# ==============================================================================

# --- Configuration ---
BACKUP_DIR="/var/backups/restic-repo"
PASSWORD_FILE="/etc/restic/password"
RESTIC_EXCLUDE_FILE="/etc/restic/exclude.conf"
RSYNC_EXCLUDE_FILE="/etc/restic/rsync-exclude.conf"
# --- End Configuration ---


# --- Global Variable ---
SNAPSHOT_IDS=()


# --- Helper Functions ---
clear_screen() { clear; }
press_enter_to_continue() { echo ""; read -p "Press [Enter] to continue..."; }


# --- Core Logic Functions ---

check_and_install_dependencies() {
    local missing_packages=""
    if ! command -v restic &> /dev/null; then missing_packages+="restic "; fi
    if ! command -v rsync &> /dev/null; then missing_packages+="rsync "; fi
    if ! command -v jq &> /dev/null; then missing_packages+="jq "; fi

    if [ -n "$missing_packages" ]; then
        echo "The following required packages are not installed: $missing_packages"
        read -p "Do you want to install them now? (Y/n): " choice
        choice=${choice:-Y}
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            apt-get update && apt-get install -y $missing_packages
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

    # Restic exclude file (for BACKUP)
    mkdir -p "$(dirname "$RESTIC_EXCLUDE_FILE")"
    {
        echo "# Restic Exclude List (files/dirs to NOT back up)"
        echo "$BACKUP_DIR"
        echo "/var/cache"
        echo "/home/*/.cache"
        echo "/tmp"
        echo "/proc"
        echo "/sys"
        echo "/dev"
        echo "/run"
        echo "/mnt"
        echo "/media"
    } > "$RESTIC_EXCLUDE_FILE"

    # Rsync exclude file (for RESTORE)
    mkdir -p "$(dirname "$RSYNC_EXCLUDE_FILE")"
    {
        echo "# Rsync Exclude List (files/dirs to NOT touch during restore)"
        echo "$BACKUP_DIR"
        echo "/var/lib/docker"
        echo "/var/cache"
        echo "/proc"
        echo "/sys"
        echo "/dev"
        echo "/run"
        echo "/tmp"
        echo "/mnt"
        echo "/media"
        echo "/boot/efi"
    } > "$RSYNC_EXCLUDE_FILE"

    echo "Creating Restic repository at $BACKUP_DIR..."
    restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" init
    echo -e "\nInitialization complete!"
}

create_backup() {
    clear_screen
    echo "--- Create a New Server Snapshot ---"
    local running_containers=""
    if command -v docker &> /dev/null && docker info >/dev/null 2>&1; then
        echo "Docker detected. Stopping containers..."
        running_containers=$(docker ps -q)
        if [ -n "$running_containers" ]; then docker stop $running_containers; fi
    fi

    echo "Starting backup of / and /boot..."
    restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" backup \
        --tag "manual-snapshot" \
        --exclude-file="$RESTIC_EXCLUDE_FILE" \
        / /boot

    echo "Snapshot created successfully."

    if [ -n "$running_containers" ]; then
        echo "Restarting containers..."
        docker start $running_containers
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
    # Corrected command to only use awk for numbering
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
    
    read -p "Enter the NUMBER of the snapshot to delete (or press Enter to cancel): " choice
    if [[ -z "$choice" ]]; then echo "Deletion cancelled."; return; fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SNAPSHOT_IDS[@]} ]; then
        echo "Invalid number. Please try again."
        return
    fi

    local selected_id=${SNAPSHOT_IDS[$((choice-1))]}
    
    read -p "WARNING: Permanently delete snapshot '$selected_id'? (Y/n): " confirmation
    confirmation=${confirmation:-Y}
    if [[ "$confirmation" == "y" || "$confirmation" == "Y" ]]; then
        restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" forget "$selected_id" --prune
        echo "Snapshot deleted."
    else
        echo "Deletion cancelled."
    fi
}

restore_backup() {
    if ! populate_and_display_snapshots; then return; fi

    read -p "Enter the NUMBER of the snapshot to RESTORE (or press Enter to cancel): " choice
    if [[ -z "$choice" ]]; then echo "Restore cancelled."; return; fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SNAPSHOT_IDS[@]} ]; then
        echo "Invalid number. Please try again."
        return
    fi

    local selected_id=${SNAPSHOT_IDS[$((choice-1))]}

    clear_screen
    echo "============================ WARNING ============================"
    echo "You are about to restore the ENTIRE server to snapshot: $selected_id"
    echo "This action is IRREVERSIBLE."
    echo "================================================================="
    read -p "To confirm, please type 'PROCEED': " confirmation
    if [ "$confirmation" != "PROCEED" ]; then echo "Restore aborted."; return; fi

    local running_containers=""
    if command -v docker &> /dev/null && docker info >/dev/null 2>&1; then
        echo "Docker detected. Stopping containers..."
        running_containers=$(docker ps -q)
        if [ -n "$running_containers" ]; then docker stop $running_containers; fi
    fi

    RESTORE_TEMP_DIR="/tmp/restic_restore_$(date +%s)"
    mkdir -p "$RESTORE_TEMP_DIR"

    echo "Step 1: Restoring snapshot to '$RESTORE_TEMP_DIR'..."
    restic -r "$BACKUP_DIR" --password-file "$PASSWORD_FILE" restore "$selected_id" --target "$RESTORE_TEMP_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Restic restore failed. Aborting."
        rm -rf "$RESTORE_TEMP_DIR"
        if [ -n "$running_containers" ]; then docker start $running_containers; fi
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

    echo "Step 3: Syncing all other system files..."
    rsync -aAXv --delete \
        --exclude-from="$RSYNC_EXCLUDE_FILE" \
        "$RESTORE_TEMP_DIR/" /

    echo "Step 4: Cleaning up temporary files..."
    rm -rf "$RESTORE_TEMP_DIR"

    if [ -n "$running_containers" ]; then
        echo "Step 5: Restarting containers..."
        docker start $running_containers
        echo "Containers restarted."
    fi

    echo -e "\nRestore complete! A reboot is STRONGLY recommended."
}


# --- Main Menu & Execution ---
show_menu() {
    clear_screen
    echo "========================================"
    echo "  Universal Server Snapshot Manager v4.5"
    echo "        (The Definitive Version)"
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

if [ ! -d "$BACKUP_DIR/keys" ]; then
    echo "Backup repository not found. You must initialize it first."
    read -p "Initialize now? (Y/n): " choice
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
    read -p "Enter your choice [1-4, 0]: " choice
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
