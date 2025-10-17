# Bakupz Interactive Backup & Restore Script

This is the repository for the **Bakupz Interactive Backup & Restore Script**, a robust Bash solution designed for backing up and restoring the contents of a working directory, specifically tailored for environments using Docker and Python virtual environments (venv).

-----

## Table of Contents

  - [Why This Script?](#why-this-script)
  - [Features](#features)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Usage](#usage)
      - [Interactive Mode](#interactive-mode)
      - [Non-Interactive Mode (for Cron)](#non-interactive-mode-for-cron)
  - [Backup Process Details](#backup-process-details)
  - [Restore Process Details](#restore-process-details)
  - [Configuration](#configuration)
  - [Dependencies](#dependencies)
  - [License](#license)

-----

## Why This Script?

In modern application development and deployment, especially with containerization and microservices, a simple `tar -czf` is often insufficient. This script addresses the complexity of backing up a project directory that contains:

1.  **Docker Volumes:** Standard backup tools often miss the data inside Docker volumes, which can be critical. This script specifically finds and archives local Docker volumes associated with projects.
2.  **System Configurations:** Crucial service settings, such as firewall rules (`ufw`) or Docker daemon configurations (`daemon.json`), need to be preserved alongside project data for a complete, working restoration.
3.  **Python Virtual Environments (Venv):** While you shouldn't typically back up the full venv directory, the script integrates an intelligent restore mechanism to recreate and populate virtual environments based on `requirements.txt`, ensuring a ready-to-run setup post-restoration.
4.  **Security and Integrity:** It employs strict shell settings (`set -euo pipefail`), uses `sha256sum` for content integrity checks, and prefixes the archive with a unique signature, making the backup file self-verifying and resistant to silent corruption.
5.  **Interactive and Automation Support:** It offers a user-friendly interactive menu for manual operations while fully supporting non-interactive mode, making it ideal for scheduled jobs via `cron`.

In short, it provides a **holistic, self-contained, and verified system snapshot**, not just a file dump.

-----

## Features

  * **System Integrity Checks:** Uses `sha256sum` and a custom signature for end-to-end archive verification during both creation and restoration.
  * **Docker Awareness:** Collects Docker metadata (networks, volumes) and uses `rsync` for incremental backup of **local** Docker volumes, minimizing backup size and time.
  * **Configuration Backup:** Archives custom system configurations (e.g., UFW, Docker daemon settings) specified in `CUSTOM_CONFIG_PATHS`.
  * **Venv Restoration:** Offers intelligent restoration of Python virtual environments post-recovery.
  * **Dry-Run Mode:** Allows pre-checking file paths and settings without creating a final archive.
  * **Log Management:** Automatically rotates log files to prevent excessive disk usage (`MAX_LOGS`).
  * **Root Requirement:** Ensures operations are run with necessary privileges for system and Docker access.

-----

## Prerequisites

  * A Linux environment (tested primarily on Debian/Ubuntu derivatives, but should work on any system with standard GNU utilities).
  * Root privileges (`sudo`).
  * The following system dependencies (the script attempts to install missing ones automatically on `apt` or `yum` based systems):
      * `docker`, `jq`, `rsync`, `xz`, `sha256sum`, `tar`, `mktemp`, `find`, `awk`, `sort`, `xargs`, `pv`, `du`.

-----

## Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/srose69/bakupz.git
    cd bakupz
    ```
2.  **Make the script executable:**
    ```bash
    chmod +x backup.sh
    ```
3.  **Run the script as root:**
    ```bash
    sudo ./backup.sh
    ```

-----

## Usage

The script must be run from the directory that contains the projects and/or Docker Compose files you wish to back up or restore, as it uses the current working directory (`CWD`) as its base.

### Interactive Mode

Simply run the script with `sudo`:

```bash
sudo ./backup.sh
```

A menu will appear:

```
========================================
    Bakupz Интерактивный Backup-менеджер
========================================
1. Создать резервную копию системы
2. Восстановить систему из резервной копии
3. Просмотреть логи
4. Выход
========================================
Выберите действие (1-4):
```

You will be prompted for project selection and confirmation for critical actions like restoration.

### Non-Interactive Mode (for Cron)

This mode is designed for scheduled tasks and requires an action and appropriate arguments.

#### Backup

To back up specific projects (`project1`, `project2`) without user intervention:

```bash
sudo ./backup.sh --non-interactive backup project1 project2
```

To back up all detected projects:

```bash
sudo ./backup.sh --non-interactive backup all
```

#### Restore

To restore the system from a specific archive file:

```bash
sudo ./backup.sh --non-interactive restore /path/to/archive.srvbak
```

**Note:** Non-interactive restore will proceed without a final confirmation prompt, so use with caution.

-----

## Backup Process Details

The `backup_system` function performs the following steps:

1.  **Dependency Check & Log Rotation:** Confirms all necessary utilities are installed and cleans up old logs.
2.  **Docker Metadata Collection:** Inspects all Docker networks and volumes, saving their configurations to `docker_metadata.json`.
3.  **Docker Volume Archiving (Incremental):**
      * Iterates through local volumes listed in the metadata.
      * Uses `rsync -aHAX --delete` to copy volume contents to a temporary directory.
      * Archives the copied volume using `tar` and compresses it with `xz`.
      * Includes a progress bar using `pv` if available.
      * Calculates a hash for the volume archive and saves it.
4.  **System Configuration Archiving:** Copies system files listed in `CUSTOM_CONFIG_PATHS` (e.g., `/etc/ufw`) and archives them into `configs.tar.xz`.
5.  **Project Copying:** Uses `rsync` to copy the selected projects into the temporary directory.
6.  **Finalization:**
      * Creates the main archive (`volumes`, `configs`, `projects`, `hashes`) using `tar -cJf`.
      * Calculates the content hash.
      * Generates a unique, verifiable signature based on the content hash and prepends it to the archive file.
      * Renames the final archive to include content and final file hash prefixes for quick verification: `vxpx_full_backup_YYYY-MM-DD_HH-MM-SS_H-xxxxxxxx_F-xxxxxxxx.srvbak`.

-----

## Restore Process Details

The `restore_system` function is a multi-step procedure to revert the system state:

1.  **Archive Selection and Verification:**
      * Allows interactive or non-interactive archive path specification.
      * Performs **three** levels of integrity checks:
          * Final file hash verification.
          * Signature verification (ensuring it's a valid VXPX backup).
          * Content hash verification (checking the main archive body).
2.  **Service Shutdown:** All Docker Compose services in the base directory are gracefully stopped (`docker-compose down`).
3.  **File Restoration:**
      * The main archive is extracted to a temporary directory.
      * Project files are copied back to `BASE_DIR` using `rsync -aHAX`.
4.  **System Configuration Restoration:**
      * Checks the integrity of the `configs.tar.xz` within the backup.
      * Extracts system configurations to the root filesystem (`/`).
      * Reloads UFW rules and restarts the Docker service.
5.  **Docker Network and Volume Restoration:**
      * Networks are recreated based on the saved metadata if they don't exist.
      * Volumes are created and their archived data is restored using a temporary Docker container to mount the volume, ensuring correct permissions and ownership.
6.  **Venv Recreation:** Prompts the user (or skips in non-interactive mode) to check for `requirements.txt` in projects and automatically recreates and installs Python virtual environments.
7.  **Service Startup:** All Docker Compose services are started up (`docker-compose up -d`).

-----

## Configuration

Key variables configurable at the top of the `backup.sh` script:

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `DEFAULT_LANG` | `"RU"` | Script output language (`RU` or `EN`). |
| `MAX_LOGS` | `10` | Maximum number of log files to keep before rotation. |
| `XZ_COMPRESSION_LEVEL` | `"-3"` | Compression level for XZ (e.g., `-9` for max compression). |
| `RSYNC_OPTS` | `"-aHAX --delete"` | Options for rsync (Archive, Hardlinks, ACLs, Extended attributes, and deletion of extraneous files in destination). |
| `CUSTOM_CONFIG_PATHS` | `("/etc/ufw", "/etc/docker/daemon.json")` | Array of critical system directories/files to include in the backup. |

-----

## Dependencies

The script relies on a number of common Linux utilities. The `check_dependencies` function attempts to install any missing tools automatically using `apt-get` or `yum`.

  * `docker`: For managing containers and volumes.
  * `jq`: For processing JSON (Docker metadata).
  * `rsync`: For efficient copying of files (volumes and projects).
  * `xz`, `tar`: For compression and archiving.
  * `sha256sum`: For calculating file hashes.
  * `pv`: (Optional) For displaying progress during volume archiving.
  * `python3-venv`: (Optional) Required for Venv creation during restore.

-----

## License

This project is licensed under the MIT License - see the `LICENSE` file for details (Note: A separate LICENSE file is required for full compliance).
