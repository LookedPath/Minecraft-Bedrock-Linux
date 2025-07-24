#!/bin/bash

# Minecraft Bedrock Server Configuration
# Edit these variables according to your setup

# Server configuration
SERVER_USER="mcserver"
SERVER_DIR="/home/mcserver/minecraft-server"
BACKUP_DIR="/home/mcserver/backups"
WORLD_NAME="Bedrock level"
SCREEN_SESSION_NAME="minecraft-server"

# Download configuration
# The update script will automatically try to detect the latest version from minecraft.net
# This URL is used as a fallback if automatic detection fails
DOWNLOAD_URL="https://minecraft.azureedge.net/bin-linux/bedrock-server-1.21.44.01.zip"
TEMP_DIR="/tmp/minecraft-update"

# User agent string for web requests (to avoid being blocked by websites)
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Logging
LOG_DIR="/var/log/minecraft"
LOG_FILE="$LOG_DIR/minecraft-server.log"

# Server executable name
SERVER_EXECUTABLE="bedrock_server"

# Backup retention (days)
BACKUP_RETENTION_DAYS=30

# Server properties that should be preserved during updates
PRESERVE_FILES=(
    "server.properties"
    "allowlist.json"
    "permissions.json"
    ".installed_version"
)

# World directories to preserve
WORLD_DIRS=(
    "worlds"
    "behavior_packs"
    "resource_packs"
)

# Telegram Bot Configuration
# Set TELEGRAM_ENABLED to "true" to enable Telegram notifications, "false" to disable
TELEGRAM_ENABLED="false"

# Telegram Bot API Token (get from @BotFather on Telegram)
# Example: "123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_BOT_TOKEN=""

# Telegram Chat ID(s) where notifications will be sent
# You can get your chat ID by messaging @userinfobot on Telegram
# For multiple recipients, separate with spaces: "123456789 -987654321"
TELEGRAM_CHAT_IDS=""

# Notification settings
TELEGRAM_NOTIFY_UPDATE_START="true"     # Notify when update process starts
TELEGRAM_NOTIFY_UPDATE_SUCCESS="true"   # Notify when update completes successfully
TELEGRAM_NOTIFY_UPDATE_FAILURE="true"   # Notify when update fails
TELEGRAM_NOTIFY_NO_UPDATE="false"       # Notify when no update is needed
