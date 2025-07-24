# Minecraft Bedrock Server Management Scripts

This collection of bash scripts provides comprehensive management for a Minecraft Bedrock server on Linux, including automated updates, backups, and server control.

## Features

- **Automated Updates**: Download and install the latest Minecraft Bedrock server
- **Backup System**: Automatic backups before updates with configurable retention
- **Screen Management**: Server runs in a screen session accessible by both `mcserver` user and root
- **Graceful Shutdown**: Player warnings before server stops
- **Configuration Preservation**: Keeps server settings and world data during updates
- **System Integration**: Optional systemd service and firewall configuration

## Scripts Overview

## Scripts Overview

### `setup.sh`

Initial setup script that prepares the environment:

- Creates the `mcserver` user
- Sets up directories with proper permissions
- Configures screen for multi-user access
- Creates systemd service
- Sets up firewall rules (if UFW is available)
- Creates helpful command aliases

### `config.sh`

Configuration file containing all customizable settings:

- Server paths and directories
- Backup retention settings
- Download URLs
- User and session names

### `update-server.sh`

Downloads and installs the latest Minecraft Bedrock server:

- **Automatically detects the latest version** from minecraft.net
- Falls back to configured URL if detection fails
- Downloads the latest server version
- Creates backups before updating
- Preserves world data and configuration files
- Gracefully stops/starts the server
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
- Creates screen session accessible by root
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

2. **Edit the configuration** in `config.sh` if needed:

   ```bash
   nano config.sh
   ```

3. **Run the setup script as root**:

   ```bash
   sudo ./setup.sh
   ```

4. **Download and install the server**:

   ```bash
   sudo ./update-server.sh
   ```

5. **Start the server**:
   ```bash
   ./start-server.sh
   ```

## Configuration

Edit `config.sh` to customize:

```bash
# Server configuration
SERVER_USER="mcserver"                          # User to run the server
SERVER_DIR="/home/mcserver/minecraft-server"    # Server installation directory
BACKUP_DIR="/home/mcserver/backups"             # Backup storage directory
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
./start-server.sh
```

### Stopping the Server

```bash
# Graceful stop (with player warnings)
./stop-server.sh

# Force stop (immediate)
./stop-server.sh --force

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
./server-manager.sh start
./server-manager.sh stop
./server-manager.sh restart
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

The update script now automatically detects the latest Minecraft Bedrock server version using multiple methods:

1. **Official Website Scraping**: Downloads the Minecraft server page and extracts the latest version number
2. **Azure CDN Testing**: Tests likely version patterns against the download server
3. **Fallback URL**: Uses the configured URL from `config.sh` if automatic detection fails

The system validates all URLs before attempting downloads and provides clear error messages if detection fails.

## Screen Session Management

The server runs in a screen session that can be accessed by both the `mcserver` user and root:

- **Attach to console**: `screen -r minecraft-server`
- **Detach from console**: Press `Ctrl+A`, then `D`
- **Kill session**: `screen -S minecraft-server -X quit`

### Multi-user Screen Access

The screen configuration allows root to attach to the `mcserver` user's screen session:

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

- **Location**: `$BACKUP_DIR/minecraft-backup-YYYYMMDD-HHMMSS.tar.gz`
- **Retention**: Configurable in `config.sh` (default: 30 days)
- **Contents**: Complete server directory including worlds and configuration

### Manual Backup

```bash
# Force an update (which creates a backup)
sudo ./update-server.sh
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
├── config.sh
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

Add a cron job to run backups periodically:

```bash
# Daily backup at 3 AM
0 3 * * * /path/to/scripts/update-server.sh > /dev/null 2>&1
```

## Security Considerations

- The `mcserver` user has limited privileges
- Screen sessions are configured for specific user access
- Backups are stored with appropriate permissions
- Log files are accessible but not world-writable

## Requirements

- Linux (64-bit recommended)
- bash
- wget
- unzip
- screen
- tar
- sudo
- systemd (optional)
- UFW (optional, for automatic firewall configuration)
- Internet connection (for downloads and Telegram notifications)

## License

These scripts are provided as-is for managing Minecraft Bedrock servers. Use at your own risk and ensure you comply with Minecraft's terms of service.
