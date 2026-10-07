# Minecraft Bedrock Server Management Scripts

This collection of bash scripts provides comprehensive management for a Minecraft Bedrock server on Linux, including automated updates, backups, and server control.

## Features

- **Automated Updates**: Download and install the latest Minecraft Bedrock server
- **Backup System**: Complete backups, including hidden files, before updates with configurable retention
- **Recoverable Updates**: Private staging, serialized management operations, archive validation, and rollback after failed startup
- **Screen Management**: Server runs in a screen session accessible by both `mcserver` user and root
- **Graceful Shutdown**: Player warnings before server stops
- **Configuration Preservation**: Keeps server settings and world data during updates
- **System Integration**: Optional systemd service and firewall configuration

## Scripts Overview

### `setup.sh`

Initial setup script that prepares the environment:

- Creates the `mcserver` user
- Sets up directories with proper permissions
- Uses the distribution-managed Screen socket permissions
- Creates systemd service
- Sets up firewall rules (if UFW is available)
- Creates helpful command aliases

### `config.sh.example` and local `config.sh`

The tracked example provides defaults. Setup creates an ignored local `config.sh`
for your settings and credentials; repository updates leave this local file alone.
Existing configuration is never overwritten by setup. The configuration contains:

- Server paths and directories
- Backup retention settings
- Download URLs
- User and session names

### `update-server.sh`

Downloads and installs the latest Minecraft Bedrock server:

- **Automatically detects the latest version** from minecraft.net
- Falls back to configured URL if detection fails
- Downloads and validates the archive before stopping the server
- Creates backups before updating
- Preserves world data and configuration files
- Gracefully stops/starts the server
- Keeps the previous installation until startup verification passes
- Rolls back failures and retains transaction files for inspection
- Cleans up old backups

### `check-version.sh`

Version checking utility:

- Compares installed version with latest available
- Shows detailed server information
- Supports automated version monitoring
- Useful for scripting and monitoring

### `start-server.sh`

Starts the Minecraft server in a screen session:

- Checks for existing running instances
- Starts server as `mcserver` user
- Creates a screen session root can access with `sudo -u mcserver`
- Provides connection instructions

### `stop-server.sh`

Gracefully stops the Minecraft server:

- Sends warnings to players (60s, 15s, 5s countdown)
- Saves world data before stopping
- Supports force stop option
- Shows server status after stopping

### `server-manager.sh`

Comprehensive management interface:

- Shows detailed server status
- Connects to server console
- Sends commands to running server
- Provides shortcuts for start/stop/restart operations

## Installation

1. **Clone or download the scripts** to your preferred location:

   ```bash
   cd /path/to/scripts
   ```

2. **Create and edit your local configuration**:

   ```bash
   bash ./setup.sh --init-config
   nano config.sh
   ```

3. **Run the setup script as root**:

   ```bash
   sudo bash ./setup.sh --install-dependencies
   ```

4. **Download and install the server**:

   ```bash
   sudo ./update-server.sh
   ```

5. **Start the server**:
   ```bash
   sudo ./start-server.sh
   ```

## Upgrading an existing installation

For servers installed with an older version of these scripts, use the compatibility
upgrade instead of rerunning the full setup:

1. Arrange a maintenance window. Pause automatic update jobs and stop the server
   with the **old scripts** before replacing them. If systemd manages the server,
   use `sudo systemctl stop minecraft-bedrock` so it stays stopped.
2. For the first upgrade from a release that tracked `config.sh`, back it up
   **before pulling**: Git removes the formerly tracked file in this release.
   In your existing checkout, run:

   ```bash
   config_backup=$(mktemp /tmp/minecraft-config.XXXXXXXX)
   sudo cp -- config.sh "$config_backup"
   git restore -- config.sh
   git pull --ff-only
   sudo install -m 600 "$config_backup" config.sh
   rm -- "$config_backup"
   ```

   `git restore` resets only the old tracked configuration after the backup is
   saved, allowing the pull when it contained local edits. Restore the backup
   only after a successful pull; keep it if any command fails. Use these commands
   one at a time and check each result. If deploying downloaded release files,
   likewise save and restore your local `config.sh` around deployment. Include
   `config.sh.example`, `common.sh`, `validate-archive.py`, and `migrate-settings.py`.
   Keep existing paths and credentials. Later Git pulls leave ignored `config.sh`
   alone; this backup/reset step is needed only for the tracking transition.
3. Run the upgrade from that directory:

   ```bash
   sudo bash ./setup.sh --upgrade --install-dependencies
   ```

   This installs required packages using apt, dnf, yum, pacman, or zypper. Package
   installation is optional: if the dependencies are already installed, run
   `sudo bash ./setup.sh --upgrade`. On other distributions, install Python 3,
   GNU coreutils and util-linux manually first, alongside the existing requirements.
4. Reload aliases with `source /etc/profile.d/minecraft.sh`. Start with
   `sudo systemctl start minecraft-bedrock` when using systemd, or
   `sudo ./start-server.sh` otherwise. Restore your automatic update schedule.

The upgrade can be run repeatedly. It creates the shared management lock,
reapplies the distribution's Screen runtime permissions, repairs the configured
user's private Screen socket directory, disables legacy `multiuser on` and
`acladd root` settings, and adds `sudo` to the existing start/stop/restart aliases.
Custom Screen settings and unrelated aliases are preserved. Modified settings
files get a one-time `.pre-hardening` backup. Existing backup archives become
root-owned with mode 600 and the backup directory uses mode 700.

Server binaries, worlds, `config.sh`, cron jobs, systemd unit overrides, and
firewall rules are preserved. The migration refuses to run while the server or
its Screen session is running. It does not download or update Minecraft.
Older configuration files remain supported: `MAX_EXTRACTED_BYTES` defaults to
4 GiB if absent, and the legacy `TEMP_DIR` value is ignored by the updater.

A read-only prerequisite check is also available:

```bash
sudo bash ./setup.sh --check
```

This checks dependencies and configuration; it does not apply migration changes
or certify that the Screen runtime permissions have already been repaired.
If a dependency is missing, it prints the compatibility upgrade command.

Screen repair uses the distribution's existing tmpfiles policy via
`systemd-tmpfiles --create --prefix=/run/screen`. It does not delete sockets.
If the old world-writable permissions remain or the runtime directory is missing,
the upgrade stops and gives package-reinstallation instructions. Reinstall the
Screen package (for example, `sudo apt-get install --reinstall screen` on
Debian/Ubuntu) and rerun the upgrade. It will not guess shared directory permissions.

## Configuration

Run `bash ./setup.sh --init-config` to create `config.sh` from the example if it
is missing, then edit `config.sh` to customize. The initialization command preserves
an existing file and creates a new file with mode 600. Normal setup also creates a
missing configuration and exits so you can review it before rerunning setup.
`--upgrade` and `--check` require an existing local configuration and never create
one. Runtime scripts report an actionable error if it is absent.

Edit `config.sh` to customize:

```bash
# Server configuration
SERVER_USER="mcserver"                          # User to run the server
SERVER_DIR="/home/mcserver/minecraft-server"    # Server installation directory
BACKUP_DIR="/home/mcserver/backups"             # Root-controlled backup directory
SCREEN_SESSION_NAME="minecraft-server"          # Screen session name

# Download URL (update this for newer versions)
DOWNLOAD_URL="https://minecraft.azureedge.net/bin-linux/bedrock-server-1.21.44.01.zip"

# Backup retention
BACKUP_RETENTION_DAYS=30                        # Keep backups for 30 days

# Telegram Bot Configuration (optional)
TELEGRAM_ENABLED="false"                        # Enable/disable Telegram notifications
TELEGRAM_BOT_TOKEN=""                           # Bot token from @BotFather
TELEGRAM_CHAT_IDS=""                            # Chat ID(s) for notifications
TELEGRAM_NOTIFY_UPDATE_START="true"             # Notify when update starts
TELEGRAM_NOTIFY_UPDATE_SUCCESS="true"           # Notify when update succeeds
TELEGRAM_NOTIFY_UPDATE_FAILURE="true"           # Notify when update fails
TELEGRAM_NOTIFY_NO_UPDATE="false"               # Notify when no update needed
```

## Telegram Bot Notifications

The scripts support optional Telegram bot notifications to keep you informed about server updates and status changes. This feature allows you to receive real-time notifications on your phone or computer whenever the server is updated, encounters errors, or when maintenance is performed.

### Features

- **Real-time Notifications**: Get instant updates about server status
- **Multiple Recipients**: Send notifications to multiple users or groups
- **Configurable Events**: Choose which events trigger notifications
- **Rich Formatting**: Messages include emojis, timestamps, and server details
- **Error Resilience**: Script continues even if Telegram notifications fail

### Setting Up Telegram Notifications

#### 1. Create a Telegram Bot

1. Open Telegram and search for `@BotFather`
2. Start a chat and send `/start`
3. Send `/newbot` to create a new bot
4. Follow the prompts to name your bot and choose a username
5. Save the API token provided (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

#### 2. Get Your Chat ID

**For personal notifications:**
1. Search for `@userinfobot` in Telegram
2. Start a chat and send any message
3. Note the Chat ID from the response (e.g., `123456789`)

**For group notifications:**
1. Add your bot to the group and make it an admin
2. Send a message mentioning your bot: `@yourbotname hello`
3. Visit `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
4. Find the "chat" object and note the "id" field (negative for groups: `-987654321`)

#### 3. Configure the Scripts

Edit `config.sh` and update the Telegram settings:

```bash
# Enable Telegram notifications
TELEGRAM_ENABLED="true"

# Your bot token from BotFather
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"

# Chat ID(s) where notifications will be sent
# For multiple recipients, separate with spaces: "123456789 -987654321"
TELEGRAM_CHAT_IDS="123456789"

# Choose which events to be notified about
TELEGRAM_NOTIFY_UPDATE_START="true"     # When update process begins
TELEGRAM_NOTIFY_UPDATE_SUCCESS="true"   # When update completes successfully
TELEGRAM_NOTIFY_UPDATE_FAILURE="true"   # When update fails or errors occur
TELEGRAM_NOTIFY_NO_UPDATE="false"       # When script runs but no update needed
```

### Notification Types

The script sends formatted messages for different events:

- **🔄 Update Start**: Notifies when the update process begins, including current version
- **✅ Update Success**: Confirms successful update with version change details
- **❌ Update Failure**: Alerts about errors with troubleshooting information
- **ℹ️ No Update Needed**: Confirms server is already up to date (optional)

### Example Notification

```
✅ Minecraft Server Update Completed

📅 Time: 2025-07-24 14:30:15
🖥️ Server: minecraft-server
📦 Updated: 1.21.44.01 → 1.21.50.07

🎮 Server is ready to play!
```

### Testing Your Configuration

1. Enable notifications in `config.sh`
2. Temporarily set `TELEGRAM_NOTIFY_NO_UPDATE="true"`
3. Run the update script when no update is available
4. You should receive a "no update needed" notification

### Troubleshooting Telegram

**Bot doesn't send messages:**
- Verify `TELEGRAM_ENABLED="true"`
- Check bot token is correct and complete
- Ensure chat ID is accurate
- Confirm you've started a chat with the bot (`/start`)

**Messages not received:**
- Check internet connectivity to `api.telegram.org`
- For groups, ensure bot has permission to send messages
- Verify bot is not blocked or restricted

**Check logs for details:**
```bash
tail -f /var/log/minecraft/minecraft-server.log
```

### Security Notes

- Keep your bot token secure and never share it publicly
- Set restrictive file permissions on `config.sh`
- Consider using environment variables for tokens in production
- The bot can only send to chats where it's been explicitly added

## Usage

### Starting the Server

```bash
sudo ./start-server.sh
```

### Stopping the Server

```bash
# Graceful stop (with player warnings)
sudo ./stop-server.sh

# Force stop (immediate)
sudo ./stop-server.sh --force

# Check status only
./stop-server.sh --status
```

### Connecting to Server Console

```bash
# Using the manager script
./server-manager.sh connect

# Direct screen connection
screen -r minecraft-server

# As root user
sudo -u mcserver screen -r minecraft-server
```

### Server Management

```bash
# Show comprehensive status
./server-manager.sh status

# Send command to server
./server-manager.sh command "say Hello players!"

# Quick start/stop/restart
sudo ./server-manager.sh start
sudo ./server-manager.sh stop
sudo ./server-manager.sh restart
```

### Updating the Server

```bash
sudo ./update-server.sh
```

### Checking for Updates

```bash
# Check current vs latest version
./check-version.sh

# Show detailed server information
./check-version.sh --detailed

# Just compare versions (for scripting)
./check-version.sh --check-only
```

## Automatic Version Detection

The updater attempts the official Minecraft download-links API, then website scraping, then the configured fallback URL. Keep the fallback URL current; it does not establish what the latest release is. Downloads must use HTTPS.

The system validates all URLs before attempting downloads and provides clear error messages if detection fails.

## Screen Session Management

The server runs in a screen session that can be accessed by both the `mcserver` user and root:

- **Attach to console**: `screen -r minecraft-server`
- **Detach from console**: Press `Ctrl+A`, then `D`
- **Kill session**: `screen -S minecraft-server -X quit`

### Multi-user Screen Access

Root attaches by running Screen as the server user. Multiuser Screen mode is disabled, and the scripts leave shared socket-directory permissions to the distribution:

```bash
# As mcserver user
screen -r minecraft-server

# As root user
sudo -u mcserver screen -r minecraft-server
```

## Systemd Integration

The setup script creates a systemd service for automatic startup:

```bash
# Enable auto-start on boot
sudo systemctl enable minecraft-bedrock

# Start/stop via systemd
sudo systemctl start minecraft-bedrock
sudo systemctl stop minecraft-bedrock

# Check service status
sudo systemctl status minecraft-bedrock
```

## Backup System

Backups are automatically created before each update:

- **Location**: `$BACKUP_DIR/minecraft-backup-YYYYMMDD-HHMMSS-RANDOM.tar.gz`
- **Retention**: Configurable in `config.sh` (default: 30 days)
- **Contents**: Complete server directory including hidden files, worlds, and configuration
- **Permissions**: Root owns the backup directory; archives use mode 600
- **Retention safety**: The backup created by the current update is never expired during that update

### Manual Backup

```bash
# Stop before archiving so the world is consistent
sudo ./stop-server.sh
sudo tar -czf /path/to/backup.tar.gz -C /home/mcserver minecraft-server
sudo ./start-server.sh
```

## File Structure

After setup, your file structure will look like:

```
/home/mcserver/
├── minecraft-server/           # Server installation
│   ├── bedrock_server         # Server executable
│   ├── server.properties      # Server configuration
│   ├── worlds/                # World data
│   └── ...                    # Other server files
├── backups/                   # Backup storage
│   ├── minecraft-backup-20231201-120000.tar.gz
│   └── ...
└── .screenrc                  # Screen configuration

/var/log/minecraft/            # Log files
├── minecraft-server.log

/path/to/scripts/              # Management scripts
├── config.sh.example          # Tracked defaults
├── config.sh                  # Ignored local settings
├── setup.sh
├── update-server.sh
├── start-server.sh
├── stop-server.sh
└── server-manager.sh
```

## Firewall Configuration

The setup script automatically configures UFW if available:

```bash
# Manual firewall setup (if UFW not used)
# Open port 19132/UDP for Minecraft Bedrock
sudo ufw allow 19132/udp

# For other firewalls, ensure port 19132/UDP is open
```

## Troubleshooting

### Server Won't Start

1. Check if server executable exists and is executable:

   ```bash
   ls -la /home/mcserver/minecraft-server/bedrock_server
   ```

2. Check logs:

   ```bash
   tail -f /var/log/minecraft/minecraft-server.log
   ```

3. Verify user permissions:
   ```bash
   sudo -u mcserver ls -la /home/mcserver/minecraft-server/
   ```

### Screen Session Issues

1. Check running screen sessions:

   ```bash
   screen -list
   sudo -u mcserver screen -list
   ```

2. Kill stuck sessions:
   ```bash
   screen -S minecraft-server -X quit
   ```

### Permission Issues

1. Fix ownership:

   ```bash
   sudo chown -R mcserver:mcserver /home/mcserver/
   ```

2. Fix script permissions:
   ```bash
   chmod +x *.sh
   ```

## Customization

### Adding Custom Commands

Edit `server-manager.sh` to add custom management commands.

### Changing Update URL

Update the `DOWNLOAD_URL` in `config.sh` when new server versions are released.

### Custom Backup Schedule

The updater creates a backup only when an update is required. Running it daily does not provide daily backups. A cron job can check for updates:

```bash
# Daily update check at 3 AM
0 3 * * * /path/to/scripts/update-server.sh > /dev/null 2>&1
```

## Security Considerations

- The `mcserver` user has limited privileges
- Screen sessions are configured for specific user access
- Backups are root-controlled and readable only by root
- Log files are accessible but not world-writable

## Requirements

- Linux (64-bit recommended)
- bash
- wget
- Python 3 (standard library only)
- GNU coreutils (`realpath`, `timeout`, `stat`)
- util-linux (`flock`)
- screen
- tar
- sudo
- systemd (optional)
- UFW (optional, for automatic firewall configuration)
- Internet connection (for downloads and Telegram notifications)

## License

These scripts are provided as-is for managing Minecraft Bedrock servers. Use at your own risk and ensure you comply with Minecraft's terms of service.

## Update safety and recovery

Start, stop, and update mutations require root and share a non-blocking lock in
`/run/lock/minecraft-bedrock`. Only one management operation can run at a time.
Update child scripts inherit the lock; the server process does not keep it open.

The updater downloads into a private directory, rejects unsafe ZIP paths, links,
special files, excessive extracted sizes, and invalid server binaries, then stops
the server and makes a complete backup. `MAX_EXTRACTED_BYTES` in `config.sh`
limits uncompressed archive contents (default 4 GiB). The server remains offline
only for backup, staging, directory promotion, and startup verification.

A replacement is assembled beside the installation on the same filesystem. The
previous directory is retained until the replacement's process and Screen session
remain running for 15 seconds. This checks startup survival, not gameplay or
world compatibility. An error or INT/TERM signal triggers rollback and attempts
to restore the previous running state. A stopped server stays stopped. Success
notifications are sent after startup verification, when a restart was required.

Failed transaction directories (`.minecraft-install.*` beside `SERVER_DIR`) are
retained for inspection. Logs identify these directories and the backup archive.
If the replacement cannot stop, recovery leaves both installations in place and
reports the failure. Restore manually after stopping the server; never overwrite
a running world. SIGKILL, power loss, and machine crashes cannot run cleanup:
inspect retained transaction directories and backups before starting again.
Directory promotion uses two renames and therefore has a brief interval with no
`SERVER_DIR`; external tooling must respect the management lock.

Configuration paths must be absolute, canonical, and disjoint from the server
installation. Symlinked directories and preservation entries containing traversal
are rejected. Preserved data must not contain symlinks. Keep the scripts,
`common.sh`, `validate-archive.py`, `migrate-settings.py`, and `config.sh` writable only by trusted
administrators: sourcing configuration executes shell code as root. Install these
files outside the game server's writable directory. Prefer a root-controlled
parent for backups so the game server user cannot rename the backup directory.

## Development checks

```bash
for script in *.sh config.sh.example; do bash -n "$script" || exit 1; done
python3 -m unittest discover -s tests -v
```

The regression tests use disposable fixtures and mocked network/server commands.
Linux CI additionally verifies process identity and selective signaling with
`/proc`. No test downloads Minecraft or operates a live server.
