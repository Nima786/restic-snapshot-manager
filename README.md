# Restic Snapshot Manager

A professional, menu-driven Bash script for creating, managing, and restoring full server snapshots on Ubuntu systems using the power of `restic` and `rsync`.

This tool provides a simple, interactive interface for performing full system backups, making it easy to roll back your entire server to a previous state. It's particularly useful for recovering from failed updates, misconfigurations, or security incidents.

---

### 🚀 Quick Setup

For a one-line installation and execution, run the following command:

    bash <(curl -fsSL https://raw.githubusercontent.com/Nima786/restic-snapshot-manager/main/snapshot-manager.sh)

### ✨ Features

* **Menu-Driven:** An easy-to-use interactive menu for all operations.
* **Dependency Check:** Automatically checks for and offers to install required packages (`restic`, `rsync`, `jq`).
* **Full System Snapshots:** Creates complete backups of `/` and `/boot`.
* **Smart Configuration:** Automatically generates necessary password and exclude files on first run.
* **Docker Aware:** Safely stops running Docker containers before a backup or restore and restarts them afterward.
* **Safe Restore:** Uses a multi-step restore process (restore to temp -> atomic data swap -> rsync) to ensure system integrity.
* **Snapshot Management:** Easily list all available snapshots or delete specific ones to free up space.

---

### 📋 Prerequisites

* An **Ubuntu**-based Linux distribution.
* The script must be run as the **root** user.
* The following packages are required: `restic`, `rsync`, `jq`. The script will prompt you to install them if they are missing.

---

### 🚀 Installation & Usage

1.  **Clone the repository:**
    ```bash
    git clone [https://github.com/Nima786/restic-snapshot-manager.git](https://github.com/Nima786/restic-snapshot-manager.git)
    cd restic-snapshot-manager
    ```

2.  **Make the script executable:**
    ```bash
    chmod +x snapshot-manager.sh
    ```

3.  **Run the script:**
    ```bash
    sudo ./snapshot-manager.sh
    ```

4.  **First-Time Setup:**
    On the first run, the script will detect that a backup repository hasn't been created. It will prompt you to initialize one. This process will automatically:
    * Create a backup directory at `/var/backups/restic-repo`.
    * Generate a secure password file at `/etc/restic/password`.
    * Create default exclude lists for `restic` and `rsync` at `/etc/restic/`.

    You can customize these paths by editing the configuration variables at the top of the script.

---

### ⚠️ **IMPORTANT WARNING**

The **Restore** function is a destructive operation that will overwrite your current system files with the data from the selected snapshot. This action is **irreversible**. Always be certain you want to proceed before confirming a restore. A system reboot is strongly recommended after a full restore.
