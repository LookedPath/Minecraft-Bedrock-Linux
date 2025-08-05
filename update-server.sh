#!/bin/bash

# Minecraft Bedrock Server Updater Script
# This script downloads the latest Minecraft Bedrock server, backs up the old installation,
# and updates the server while preserving world data and configuration files.

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        DEBUG) echo -e "${BLUE}[DEBUG]${NC} $message" ;;
    esac
    
    # Also log to file if log directory exists
    if [[ -d "$LOG_DIR" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root"
        exit 1
    fi
}

# Check system requirements for the updater
check_requirements() {
    log DEBUG "Checking system requirements..."
    
    # Check for required commands
    local required_commands=("wget" "unzip" "tar" "grep")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log ERROR "Required command not found: $cmd"
            log ERROR "Please install $cmd and try again"
            exit 1
        fi
    done
    
    # Check wget version and capabilities with timeout
    log DEBUG "Checking wget capabilities..."
    if timeout 5 wget --help 2>/dev/null | grep -q "spider" 2>/dev/null; then
        log DEBUG "wget supports --spider option"
    else
        log WARN "wget doesn't support --spider option or check timed out, some version detection may be limited"
    fi
    
    # Check internet connectivity with a quick test
    log DEBUG "Testing internet connectivity..."
    # Use a more reliable endpoint that doesn't block wget requests
    if timeout 10 wget --spider --timeout=5 --user-agent="$USER_AGENT" -q "https://www.google.com" 2>/dev/null; then
        log DEBUG "Internet connectivity confirmed"
    else
        log WARN "No internet connection detected or connection test failed"
        log WARN "Automatic version detection may fail - will fall back to configured URL if needed"
    fi
    
    log DEBUG "System requirements check completed"
}

# Send Telegram notification
send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-}"
    
    # Check if Telegram notifications are enabled
    if [[ "$TELEGRAM_ENABLED" != "true" ]]; then
        log DEBUG "Telegram notifications are disabled"
        return 0
    fi
    
    # Check if bot token and chat IDs are configured
    if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
        log WARN "Telegram bot token not configured, skipping notification"
        return 1
    fi
    
    if [[ -z "$TELEGRAM_CHAT_IDS" ]]; then
        log WARN "Telegram chat IDs not configured, skipping notification"
        return 1
    fi
    
    log DEBUG "Sending Telegram notification..."
    
    # Prepare the API URL
    local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    
    # Send message to each chat ID - use read to safely handle the chat IDs
    local chat_ids_array
    read -ra chat_ids_array <<< "$TELEGRAM_CHAT_IDS"
    local success_count=0
    local total_count=${#chat_ids_array[@]}
    
    if [[ $total_count -eq 0 ]]; then
        log WARN "No chat IDs configured for Telegram notifications"
        return 1
    fi
    
    log DEBUG "Sending to $total_count chat ID(s): ${chat_ids_array[*]}"
    
    for chat_id in "${chat_ids_array[@]}"; do
        log DEBUG "Sending message to chat ID: $chat_id"
        
        # Prepare POST data
        local post_data="chat_id=${chat_id}&text=${message}"
        if [[ -n "$parse_mode" ]]; then
            post_data="${post_data}&parse_mode=${parse_mode}"
        fi
        
        # Send the message with timeout
        local response=$(timeout 30 wget --timeout=15 --tries=2 \
            --post-data="$post_data" \
            --header="Content-Type: application/x-www-form-urlencoded" \
            --user-agent="$USER_AGENT" \
            -q -O - "$api_url" 2>/dev/null)
        
        if [[ $? -eq 0 ]] && echo "$response" | grep -q '"ok":true'; then
            log DEBUG "Message sent successfully to chat ID: $chat_id"
            ((success_count++))
        else
            log WARN "Failed to send message to chat ID: $chat_id"
            log DEBUG "Response: $response"
        fi
    done
    
    if [[ $success_count -eq $total_count ]]; then
        log DEBUG "Telegram notification sent successfully to all recipients"
        return 0
    elif [[ $success_count -gt 0 ]]; then
        log WARN "Telegram notification sent to $success_count out of $total_count recipients"
        return 0
    else
        log ERROR "Failed to send Telegram notification to any recipient"
        return 1
    fi
}

# Send update start notification
notify_update_start() {
    local current_version="${1:-$INSTALLED_VERSION}"
    
    if [[ "$TELEGRAM_NOTIFY_UPDATE_START" == "true" ]]; then
        log DEBUG "Preparing update start notification..."
        local hostname=$(hostname)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local message="🔄 *Minecraft Server Update Started*%0A%0A"
        message+="📅 Time: $timestamp%0A"
        message+="🖥️ Server: $hostname%0A"
        message+="📦 Current version: $current_version%0A%0A"
        message+="⏳ Update is in progress..."
        
        log DEBUG "Sending Telegram notification with message length: ${#message}"
        if send_telegram_message "$message" "Markdown"; then
            log DEBUG "Update start notification sent successfully"
        else
            log WARN "Failed to send update start notification, but continuing with update"
        fi
    else
        log DEBUG "Update start notifications are disabled"
    fi
    log DEBUG "notify_update_start function completed"
}

# Send update success notification
notify_update_success() {
    local old_version="$1"
    local new_version="$2"
    
    if [[ "$TELEGRAM_NOTIFY_UPDATE_SUCCESS" == "true" ]]; then
        local hostname=$(hostname)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local message="✅ *Minecraft Server Update Completed*%0A%0A"
        message+="📅 Time: $timestamp%0A"
        message+="🖥️ Server: $hostname%0A"
        message+="📦 Updated: $old_version → $new_version%0A%0A"
        message+="🎮 Server is ready to play!"
        
        send_telegram_message "$message" "Markdown"
    fi
}

# Send update failure notification
notify_update_failure() {
    local error_message="$1"
    
    if [[ "$TELEGRAM_NOTIFY_UPDATE_FAILURE" == "true" ]]; then
        local hostname=$(hostname)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local message="❌ *Minecraft Server Update Failed*%0A%0A"
        message+="📅 Time: $timestamp%0A"
        message+="🖥️ Server: $hostname%0A"
        message+="⚠️ Error: ${error_message:-Unknown error}%0A%0A"
        message+="🔧 Manual intervention may be required."
        
        send_telegram_message "$message" "Markdown"
    fi
}

# Send no update needed notification
notify_no_update() {
    local current_version="$1"
    
    if [[ "$TELEGRAM_NOTIFY_NO_UPDATE" == "true" ]]; then
        local hostname=$(hostname)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local message="ℹ️ *Minecraft Server Check Complete*%0A%0A"
        message+="📅 Time: $timestamp%0A"
        message+="🖥️ Server: $hostname%0A"
        message+="📦 Version: $current_version%0A%0A"
        message+="✅ Server is already up to date!"
        
        send_telegram_message "$message" "Markdown"
    fi
}

# Create necessary directories
setup_directories() {
    log INFO "Setting up directories..."
    
    # Create directories with proper permissions
    mkdir -p "$SERVER_DIR" "$BACKUP_DIR" "$TEMP_DIR" "$LOG_DIR"
    
    # Set ownership and permissions
    chown -R "$SERVER_USER:$SERVER_USER" "$SERVER_DIR" "$BACKUP_DIR"
    chmod 755 "$SERVER_DIR" "$BACKUP_DIR"
    chmod 755 "$LOG_DIR"
    
    log INFO "Directories created and configured"
}

# Get currently installed version
get_installed_version() {
    if [[ -f "$SERVER_DIR/$SERVER_EXECUTABLE" ]]; then
        # Try to read version from our stored version file first
        local version_file="$SERVER_DIR/.installed_version"
        local version=""
        
        if [[ -f "$version_file" ]]; then
            # Extract version from our version file
            version=$(grep "^VERSION=" "$version_file" 2>/dev/null | cut -d'=' -f2 || echo "")
            if [[ -n "$version" ]]; then
                INSTALLED_VERSION="$version"
                return
            fi
        fi
        
        # Fallback methods if version file doesn't exist or is invalid
        
        # Try to extract version from release notes (legacy method)
        local release_notes="$SERVER_DIR/release-notes.txt"
        if [[ -f "$release_notes" ]]; then
            version=$(grep -oP "Version\s+\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "$release_notes" 2>/dev/null | head -1 || echo "")
        fi
        
        # If still no version, use modification date as fallback
        if [[ -z "$version" ]]; then
            local mod_date=$(stat -c %Y "$SERVER_DIR/$SERVER_EXECUTABLE" 2>/dev/null || echo "")
            if [[ -n "$mod_date" ]]; then
                version="installed-$(date -d @$mod_date +%Y%m%d)"
            else
                version="unknown"
            fi
        fi
        
        INSTALLED_VERSION="$version"
    else
        INSTALLED_VERSION="not-installed"
    fi
}

# Check if update is needed
check_update_needed() {
    local installed="$1"
    local latest="$2"
    
    log INFO "Checking if update is needed..."
    log INFO "Installed version: $installed"
    log INFO "Latest version:    $latest"
    
    if [[ "$installed" == "not-installed" ]]; then
        log INFO "Server is not installed, proceeding with fresh installation"
        return 0  # Update needed (fresh install)
    elif [[ "$latest" == "unknown" ]]; then
        log WARN "Could not determine latest version"
        log WARN "Skipping update - manual intervention may be required"
        return 1  # No update (unknown latest version)
    elif [[ "$installed" == "$latest" ]]; then
        log INFO "✓ Server is already up to date!"
        return 1  # No update needed
    else
        # Try version comparison if both are proper version numbers
        if [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1 | grep -q "^$installed$"; then
                if [[ "$installed" != "$latest" ]]; then
                    log INFO "⚠ Server update available: $installed → $latest"
                    return 0  # Update needed
                fi
            else
                log WARN "⚠ Installed version ($installed) appears newer than detected latest ($latest)"
                log WARN "This might indicate a detection issue, skipping update"
                return 1  # No update (installed version newer)
            fi
        else
            log WARN "⚠ Cannot reliably compare versions (non-standard format)"
            log INFO "Proceeding with update as a safety measure"
            return 0  # Update needed (can't compare, so update to be safe)
        fi
    fi
    
    return 1  # Default to no update
}
get_latest_download_url() {
    log INFO "Detecting latest Minecraft Bedrock server version using official API..."
    
    local download_url=""
    local latest_version=""
    
    # Method 1: Use the official Minecraft API
    log DEBUG "Fetching download links from official Minecraft API..."
    local api_url="https://net-secondary.web.minecraft-services.net/api/v1.0/download/links"
    local temp_json="$TEMP_DIR/minecraft_api.json"
    
    # Download the API response with timeout
    if timeout 30 wget --timeout=15 --tries=2 --user-agent="$USER_AGENT" -q -O "$temp_json" "$api_url" 2>/dev/null; then
        log DEBUG "Successfully fetched API response"
        
        # Check if we have jq available for better JSON parsing
        if command -v jq &>/dev/null; then
            # Use jq for robust JSON parsing
            download_url=$(jq -r '.result.links[] | select(.downloadType=="serverBedrockLinux") | .downloadUrl' "$temp_json" 2>/dev/null || echo "")
            # Clean the URL and validate it
            download_url=$(echo "$download_url" | tr -d '\r\n' | sed 's/[[:space:]]*$//')
            if [[ -n "$download_url" && "$download_url" != "null" && "$download_url" =~ ^https?:// ]]; then
                # Extract version from the URL
                latest_version=$(echo "$download_url" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "")
                log INFO "Found latest version using jq: $latest_version"
            else
                log DEBUG "Invalid or empty download URL from jq: '$download_url'"
                download_url=""
            fi
        else
            # Fallback to grep/sed parsing if jq is not available
            log DEBUG "jq not available, using grep/sed for JSON parsing"
            
            # Look for serverBedrockLinux entry and extract the downloadUrl
            local linux_entry=$(grep -o '"downloadType":"serverBedrockLinux","downloadUrl":"[^"]*"' "$temp_json" 2>/dev/null || echo "")
            if [[ -n "$linux_entry" ]]; then
                download_url=$(echo "$linux_entry" | sed 's/.*"downloadUrl":"//;s/".*//' 2>/dev/null || echo "")
                # Clean the URL of any potential invisible characters
                download_url=$(echo "$download_url" | tr -d '\r\n' | sed 's/[[:space:]]*$//')
                if [[ -n "$download_url" && "$download_url" =~ ^https?:// ]]; then
                    # Extract version from the URL
                    latest_version=$(echo "$download_url" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "")
                    log INFO "Found latest version using grep/sed: $latest_version"
                else
                    log DEBUG "Invalid or empty download URL extracted: '$download_url'"
                    download_url=""
                fi
            fi
        fi
        
        rm -f "$temp_json"
    else
        log WARN "Failed to fetch from official Minecraft API (timeout or connection error)"
    fi
    
    # Method 2: Fallback to web scraping if API fails
    if [[ -z "$download_url" ]]; then
        log DEBUG "API method failed, falling back to website scraping..."
        local temp_page="$TEMP_DIR/minecraft_page.html"
        
        if timeout 30 wget --timeout=15 --tries=2 --user-agent="$USER_AGENT" -q -O "$temp_page" "https://www.minecraft.net/en-us/download/server/bedrock" 2>/dev/null; then
            # Extract version from the download link
            latest_version=$(grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$temp_page" 2>/dev/null | head -1 || echo "")
            
            if [[ -n "$latest_version" ]]; then
                download_url="https://minecraft.azureedge.net/bin-linux/bedrock-server-${latest_version}.zip"
                log INFO "Found latest version from website scraping: $latest_version"
            else
                log DEBUG "No version found in website content"
            fi
            
            rm -f "$temp_page"
        else
            log WARN "Failed to fetch version from official website (timeout or connection error)"
        fi
    fi
    
    # Method 3: Fallback to configured URL if all detection methods fail
    if [[ -z "$download_url" ]]; then
        log WARN "Could not automatically detect latest version using any method"
        log INFO "Falling back to configured URL from config.sh"
        
        # Extract version from configured URL if possible
        local config_version=$(echo "$DOWNLOAD_URL" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "unknown")
        if [[ "$config_version" != "unknown" ]]; then
            log INFO "Using configured version: $config_version"
        fi
        
        download_url="$DOWNLOAD_URL"
    fi
    
    # Validate the final URL
    if [[ -z "$download_url" ]]; then
        log ERROR "Failed to determine download URL"
        exit 1
    fi
    
    # Test the final URL with timeout
    log DEBUG "Validating download URL: $download_url"
    log DEBUG "URL length: ${#download_url} characters"
    log DEBUG "URL starts with: $(echo "$download_url" | head -c 50)..."
    
    if ! timeout 15 wget --spider --timeout=10 --user-agent="$USER_AGENT" -q "$download_url" 2>/dev/null; then
        log ERROR "Download URL is not accessible: $download_url"
        log ERROR "Please check your internet connection or update the URL manually in config.sh"
        log DEBUG "Trying wget with verbose output for debugging..."
        timeout 15 wget --spider --timeout=10 --user-agent="$USER_AGENT" -v "$download_url" 2>&1 | head -5 || true
        exit 1
    fi
    
    log INFO "Using download URL: $download_url"
    if [[ -n "$latest_version" ]]; then
        log INFO "Latest version: $latest_version"
    fi
    
    # Set global variable instead of returning via echo
    DETECTED_DOWNLOAD_URL="$download_url"
}

# Download the latest server
download_server() {
    local download_url="$1"
    local filename="bedrock-server-latest.zip"
    
    log INFO "Downloading Minecraft Bedrock Server from: $download_url"
    
    cd "$TEMP_DIR"
    
    # Download with progress bar
    if ! wget --progress=bar:force:noscroll --user-agent="$USER_AGENT" -O "$filename" "$download_url"; then
        log ERROR "Failed to download server from $download_url"
        notify_update_failure "Failed to download server from $download_url"
        exit 1
    fi
    
    log INFO "Download completed successfully"
    DOWNLOADED_FILE="$TEMP_DIR/$filename"
}

# Extract server files
extract_server() {
    local zip_file="$1"
    local extract_dir="$TEMP_DIR/extracted"
    
    log INFO "Extracting server files..."
    
    mkdir -p "$extract_dir"
    
    if ! unzip -q "$zip_file" -d "$extract_dir"; then
        log ERROR "Failed to extract server files"
        exit 1
    fi
    
    log INFO "Server files extracted successfully"
    EXTRACTED_DIR="$extract_dir"
}

# Check if server is running
is_server_running() {
    log DEBUG "Checking if server is running (user: $SERVER_USER, session: $SCREEN_SESSION_NAME)"
    
    # Check if the user exists
    if ! id "$SERVER_USER" &>/dev/null; then
        log DEBUG "User $SERVER_USER does not exist"
        return 1
    fi
    
    # Check if screen command is available
    if ! command -v screen &>/dev/null; then
        log DEBUG "Screen command not available"
        return 1
    fi
    
    # Use a more robust approach to check for running screen sessions
    local screen_output=""
    if screen_output=$(sudo -u "$SERVER_USER" screen -list 2>/dev/null); then
        log DEBUG "Screen list output: $screen_output"
        if echo "$screen_output" | grep -q "$SCREEN_SESSION_NAME"; then
            log DEBUG "Server screen session found"
            return 0
        else
            log DEBUG "Server screen session not found"
            return 1
        fi
    else
        log DEBUG "Failed to get screen list or no screen sessions found"
        return 1
    fi
}

# Stop the server gracefully using the stop-server script
stop_server() {
    log DEBUG "Attempting to stop server..."
    if is_server_running; then
        log INFO "Stopping Minecraft server using stop-server.sh..."
        log DEBUG "This may take up to 2 minutes for graceful shutdown..."
        
        # Use timeout to prevent hanging indefinitely
        # Allow up to 3 minutes (180 seconds) for graceful shutdown
        local stop_exit_code=0
        timeout 180 "$SCRIPT_DIR/stop-server.sh" || stop_exit_code=$?
        
        if [[ $stop_exit_code -eq 0 ]]; then
            log INFO "Server stopped successfully"
            
            # Double-check that the server actually stopped
            local retry_count=0
            while is_server_running && [[ $retry_count -lt 10 ]]; do
                log DEBUG "Waiting for server to fully stop... (attempt $((retry_count + 1)))"
                sleep 2
                ((retry_count++))
            done
            
            if is_server_running; then
                log WARN "Server may not have stopped completely, but continuing with update"
            else
                log DEBUG "Server confirmed stopped"
            fi
        else
            if [[ $stop_exit_code -eq 124 ]]; then
                log ERROR "Server stop operation timed out after 3 minutes"
                log ERROR "Attempting to force stop the server..."
                
                # Try to force stop if graceful stop failed
                if sudo -u "$SERVER_USER" screen -S "$SCREEN_SESSION_NAME" -X quit 2>/dev/null; then
                    log WARN "Server force-stopped using screen quit"
                    sleep 5
                else
                    log ERROR "Failed to force stop server"
                fi
            else
                log ERROR "Failed to stop server gracefully (exit code: $stop_exit_code)"
            fi
            
            # Check if server is still running after force stop attempt
            if is_server_running; then
                log ERROR "Server is still running - this may prevent safe updating"
                log ERROR "Manual intervention may be required"
                return 1
            else
                log WARN "Server stopped (possibly forced), continuing with update"
            fi
        fi
    else
        log INFO "Server is not running"
    fi
}

# Start the server using the start-server script
start_server() {
    log INFO "Starting Minecraft server using start-server.sh..."
    if "$SCRIPT_DIR/start-server.sh"; then
        log INFO "Server started successfully"
    else
        log ERROR "Failed to start server"
        log ERROR "You may need to start it manually using: $SCRIPT_DIR/start-server.sh"
    fi
}

# Create backup of current server
backup_server() {
    if [[ ! -d "$SERVER_DIR" ]]; then
        log INFO "No existing server directory found, skipping backup"
        return 0
    fi
    
    local backup_name="minecraft-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    log INFO "Creating backup: $backup_name"
    
    # Create backup directory
    mkdir -p "$backup_path"
    
    # Copy server files (preserve permissions and timestamps)
    if ! cp -rp "$SERVER_DIR"/* "$backup_path/"; then
        log ERROR "Failed to create backup"
        exit 1
    fi
    
    # Compress backup
    log INFO "Compressing backup..."
    cd "$BACKUP_DIR"
    if ! tar -czf "$backup_name.tar.gz" "$backup_name"; then
        log ERROR "Failed to compress backup"
        exit 1
    fi
    
    # Remove uncompressed backup
    rm -rf "$backup_path"
    
    # Set ownership
    chown "$SERVER_USER:$SERVER_USER" "$backup_name.tar.gz"
    
    log INFO "Backup created successfully: $backup_name.tar.gz"
}

# Clean old backups
cleanup_old_backups() {
    log INFO "Cleaning up old backups (older than $BACKUP_RETENTION_DAYS days)..."
    
    find "$BACKUP_DIR" -name "minecraft-backup-*.tar.gz" -type f -mtime +$BACKUP_RETENTION_DAYS -delete
    
    log INFO "Old backups cleaned up"
}

# Preserve important files during update
preserve_files() {
    local extract_dir="$1"
    local preserve_dir="$TEMP_DIR/preserve"
    
    log INFO "Preserving configuration files and world data..."
    
    mkdir -p "$preserve_dir"
    
    # Preserve configuration files
    for file in "${PRESERVE_FILES[@]}"; do
        if [[ -f "$SERVER_DIR/$file" ]]; then
            cp "$SERVER_DIR/$file" "$preserve_dir/"
            log DEBUG "Preserved: $file"
        fi
    done
    
    # Preserve world directories
    for dir in "${WORLD_DIRS[@]}"; do
        if [[ -d "$SERVER_DIR/$dir" ]]; then
            cp -r "$SERVER_DIR/$dir" "$preserve_dir/"
            log DEBUG "Preserved: $dir"
        fi
    done
    
    PRESERVED_DIR="$preserve_dir"
}

# Install new server
install_server() {
    local extract_dir="$1"
    local preserve_dir="$2"
    
    log INFO "Installing new server files..."
    
    # Remove old server files (but keep directory structure)
    if [[ -d "$SERVER_DIR" ]]; then
        find "$SERVER_DIR" -mindepth 1 -delete
    fi
    
    # Copy new server files
    cp -r "$extract_dir"/* "$SERVER_DIR/"
    
    # Restore preserved files
    if [[ -d "$preserve_dir" ]]; then
        cp -r "$preserve_dir"/* "$SERVER_DIR/"
        log INFO "Restored preserved files and world data"
    fi
    
    # Store version information for future reference
    store_version_info
    
    # Set executable permissions on server binary
    chmod +x "$SERVER_DIR/$SERVER_EXECUTABLE"
    
    # Set ownership
    chown -R "$SERVER_USER:$SERVER_USER" "$SERVER_DIR"
    
    log INFO "New server installed successfully"
}

# Store version information to a file for future reference
store_version_info() {
    local version_file="$SERVER_DIR/.installed_version"
    local install_date=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Extract version from the download URL if possible
    local installed_version=""
    if [[ -n "$DETECTED_DOWNLOAD_URL" ]]; then
        installed_version=$(echo "$DETECTED_DOWNLOAD_URL" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "")
    fi
    
    if [[ -z "$installed_version" ]]; then
        installed_version="unknown-$(date +%Y%m%d-%H%M%S)"
    fi
    
    # Create version file with installation details
    cat > "$version_file" << EOF
# Minecraft Bedrock Server Version Information
# This file is automatically generated by update-server.sh
VERSION=$installed_version
INSTALL_DATE=$install_date
DOWNLOAD_URL=$DETECTED_DOWNLOAD_URL
EOF
    
    # Set proper ownership
    chown "$SERVER_USER:$SERVER_USER" "$version_file"
    chmod 644 "$version_file"
    
    log INFO "Stored version information: $installed_version"
}

# Cleanup temporary files
cleanup_temp() {
    if [[ -d "$TEMP_DIR" ]]; then
        log INFO "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# Main update process
main() {
    log INFO "Starting Minecraft Bedrock Server update process..."
    
    # Check prerequisites
    check_root
    check_requirements
    
    # Setup directories
    setup_directories
    
    # Get current and latest versions first
    log INFO "Checking current installation and available updates..."
    get_installed_version
    local installed_version="$INSTALLED_VERSION"
    
    get_latest_download_url
    local download_url="$DETECTED_DOWNLOAD_URL"
    
    # Extract latest version from download URL
    local latest_version=""
    if [[ -n "$download_url" ]]; then
        latest_version=$(echo "$download_url" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "unknown")
    else
        latest_version="unknown"
    fi
    
    # Check if update is actually needed
    if ! check_update_needed "$installed_version" "$latest_version"; then
        log INFO "No update required. Exiting."
        notify_no_update "$installed_version"
        exit 0
    fi
    
    # If we get here, an update is needed
    log INFO "Update required, proceeding with server update..."
    notify_update_start "$installed_version"
    
    log DEBUG "Starting update process after notification sent"
    
    # Check if server is currently running (only now that we know we need to update)
    log DEBUG "About to check if server is running..."
    local server_was_running=false
    if is_server_running; then
        server_was_running=true
        log INFO "Server is currently running and will be restarted after update"
    else
        log INFO "Server is not currently running"
    fi
    
    log DEBUG "Server running check completed, proceeding to stop server if needed..."
    
    # Stop server if running (only if update is needed)
    # Temporarily disable ERR trap to handle stop_server failures gracefully
    set +e
    stop_server
    local stop_result=$?
    set -e
    
    if [[ $stop_result -ne 0 ]]; then
        log WARN "Stop server returned non-zero exit code ($stop_result), but continuing with update"
        # Check if server actually stopped despite the error
        if is_server_running; then
            log ERROR "Server is still running after stop attempt failed"
            log ERROR "Cannot safely proceed with update"
            exit 1
        else
            log INFO "Server stopped despite error, proceeding with update"
        fi
    fi
    
    # Create backup (only if update is needed)
    backup_server
    
    # Download latest server
    log INFO "Downloading server update..."
    download_server "$download_url"
    local zip_file="$DOWNLOADED_FILE"
    
    # Extract server
    extract_server "$zip_file"
    local extract_dir="$EXTRACTED_DIR"
    
    # Preserve important files
    preserve_files "$extract_dir"
    local preserve_dir="$PRESERVED_DIR"
    
    # Install new server
    install_server "$extract_dir" "$preserve_dir"
    
    # Cleanup (but keep temp dir for now in case restart fails)
    cleanup_old_backups
    
    log INFO "Minecraft Bedrock Server update completed successfully!"
    log INFO "Updated from version $installed_version to $latest_version"
    
    # Send success notification
    notify_update_success "$installed_version" "$latest_version"
    
    # Restart server if it was running before
    log DEBUG "Checking if server should be restarted... server_was_running=$server_was_running"
    if [[ "$server_was_running" == "true" ]]; then
        log INFO "Restarting server as it was running before the update..."
        start_server
    else
        log INFO "Server was not running before update, leaving it stopped"
        log INFO "You can start the server using: $SCRIPT_DIR/start-server.sh"
    fi
    
    # Final cleanup
    cleanup_temp
}

# Handle script interruption
cleanup_and_notify_error() {
    local exit_code=$?
    local line_number=${1:-"unknown"}
    
    log ERROR "Script interrupted or failed at line $line_number with exit code $exit_code"
    log ERROR "This may have occurred during: server status check, server stop, backup, download, or installation"
    log DEBUG "Call stack: ${BASH_SOURCE[*]}"
    log DEBUG "Function stack: ${FUNCNAME[*]}"
    
    # Cleanup and disable the EXIT trap to prevent double cleanup
    trap - EXIT
    cleanup_temp
    
    if [[ $exit_code -ne 0 ]]; then
        local error_msg="Script failed at line $line_number with exit code $exit_code. Check logs for details."
        log ERROR "$error_msg"
        notify_update_failure "$error_msg"
    fi
    
    exit $exit_code
}

# Set up error handling
trap 'cleanup_and_notify_error $LINENO' ERR
# Note: EXIT trap removed to prevent interference with normal script completion

# Run main function
main "$@"
