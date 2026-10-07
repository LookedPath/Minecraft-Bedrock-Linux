#!/bin/bash

# Minecraft Bedrock Server Updater Script
# This script downloads the latest Minecraft Bedrock server, backs up the old installation,
# and updates the server while preserving world data and configuration files.

set -Eeuo pipefail
umask 077

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

WORK_DIR=""
TRANSACTION_DIR=""
SERVER_WAS_RUNNING=false
STOP_ATTEMPTED=false
UPDATE_COMMITTED=false
NEW_PROMOTED=false
BACKUP_FILE=""

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
    local required_commands=("wget" "tar" "grep" "python3" "realpath" "flock" "timeout" "sudo" "screen")
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
        local post_data
        post_data=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlencode({"chat_id":sys.argv[1], "text":sys.argv[2].replace("%0A", "\n"), "parse_mode":sys.argv[3]}))' "$chat_id" "$message" "$parse_mode")
        
        # Send the message with timeout
        local response
        response=$(timeout 30 wget --timeout=15 --tries=2 \
            --post-data="$post_data" \
            --header="Content-Type: application/x-www-form-urlencoded" \
            --user-agent="$USER_AGENT" \
            -q -O - "$api_url" 2>/dev/null) || response=""
        
        if printf '%s\n' "$response" | grep -q '"ok":true'; then
            log DEBUG "Message sent successfully to chat ID: $chat_id"
            success_count=$((success_count + 1))
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
        
        if send_telegram_message "$message" "Markdown"; then
            log DEBUG "Update success notification sent successfully"
        else
            log WARN "Failed to send update success notification, but continuing"
        fi
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
        
        if send_telegram_message "$message" "Markdown"; then
            log DEBUG "Update failure notification sent successfully"
        else
            log WARN "Failed to send update failure notification"
        fi
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
        
        if send_telegram_message "$message" "Markdown"; then
            log DEBUG "No update notification sent successfully"
        else
            log WARN "Failed to send no update notification"
        fi
    fi
}

# Create necessary directories
setup_directories() {
    validate_config || { log ERROR "Unsafe or invalid configuration"; exit 1; }
    id "$SERVER_USER" >/dev/null || { log ERROR "Run setup.sh first"; exit 1; }
    acquire_management_lock || exit 1
    mkdir -p -- "$(dirname "$SERVER_DIR")" "$BACKUP_DIR" "$LOG_DIR"
    chown root:root "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    WORK_DIR=$(mktemp -d /tmp/minecraft-update.XXXXXXXX)
    TEMP_DIR="$WORK_DIR"
    log INFO "Created private update workspace"
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
            if [[ -n "$download_url" && "$download_url" != "null" && "$download_url" =~ ^https:// ]]; then
                # Extract version from the URL
                latest_version=$(echo "$download_url" | sed -nE 's/.*bedrock-server-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$/\1/p' 2>/dev/null || echo "")
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
                if [[ -n "$download_url" && "$download_url" =~ ^https:// ]]; then
                    # Extract version from the URL
                    latest_version=$(echo "$download_url" | sed -nE 's/.*bedrock-server-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$/\1/p' 2>/dev/null || echo "")
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
            latest_version=$(sed -nE 's/.*bedrock-server-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$/\1/p' "$temp_page" 2>/dev/null | head -1 || echo "")
            
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
        local config_version=$(echo "$DOWNLOAD_URL" | sed -nE 's/.*bedrock-server-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$/\1/p' 2>/dev/null || echo "unknown")
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
    
    [[ "$download_url" =~ ^https://[^[:space:]]+/bedrock-server-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.zip$ ]] || {
        log ERROR "Invalid HTTPS download URL"; return 1;
    }

    # Test the final URL with timeout
    log DEBUG "Validating download URL: $download_url"
    log DEBUG "URL length: ${#download_url} characters"
    log DEBUG "URL starts with: $(echo "$download_url" | head -c 50)..."
    
    if ! timeout 15 wget --https-only --spider --timeout=10 --user-agent="$USER_AGENT" -q "$download_url" 2>/dev/null; then
        log ERROR "Download URL is not accessible: $download_url"
        log ERROR "Please check your internet connection or update the URL manually in config.sh"
        log DEBUG "Trying wget with verbose output for debugging..."
        timeout 15 wget --https-only --spider --timeout=10 --user-agent="$USER_AGENT" -v "$download_url" 2>&1 | head -5 || true
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
    # Reject plaintext HTTP and malformed URLs before invoking wget.
    [[ "$download_url" =~ ^https://[^[:space:]]+/bedrock-server-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.zip$ ]] || {
        log ERROR "Expected an HTTPS Bedrock server archive URL"; return 1;
    }
    log INFO "Downloading server update before shutdown..."
    DOWNLOADED_FILE="$WORK_DIR/bedrock-server-latest.zip"
    timeout 600 wget --https-only --timeout=30 --tries=3 --user-agent="$USER_AGENT" \
        -O "$DOWNLOADED_FILE" -- "$download_url"
}

# Extract server files
extract_server() {
    EXTRACTED_DIR="$WORK_DIR/extracted"
    mkdir -- "$EXTRACTED_DIR"
    python3 "$SCRIPT_DIR/validate-archive.py" "$1" "$EXTRACTED_DIR" \
        "$SERVER_EXECUTABLE" "${MAX_EXTRACTED_BYTES:-4294967296}"
    log INFO "Archive contents and executable validated"
}

# Check if server is running
is_server_running() {
    # A process without its console still prevents a safe update.
    has_server_process || has_screen_session
}

# Stop the server gracefully using the stop-server script
stop_server() {
    if is_server_running; then
        log INFO "Stopping server before backup..."
        timeout 180 "$SCRIPT_DIR/stop-server.sh" || return 1
    fi
    if is_server_running; then
        log ERROR "Server has not stopped; refusing to update"
        return 1
    fi
}

# Start the server using the start-server script
start_server() {
    "$SCRIPT_DIR/start-server.sh"
}

# Create backup of current server
backup_server() {
    [[ -d "$SERVER_DIR" ]] || return 0
    BACKUP_FILE=$(mktemp "$BACKUP_DIR/minecraft-backup-$(date +%Y%m%d-%H%M%S)-XXXXXXXX.tar.gz")
    # Include dotfiles and preserve metadata. Publish only a complete, readable archive.
    local partial="$BACKUP_FILE.partial"
    rm -- "$BACKUP_FILE"
    tar -czf "$partial" -C "$(dirname "$SERVER_DIR")" -- "$(basename "$SERVER_DIR")"
    tar -tzf "$partial" >/dev/null
    mv -- "$partial" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    log INFO "Complete backup created: $BACKUP_FILE"
}

# Clean old backups
cleanup_old_backups() {
    # Never expire the backup created by this update.
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'minecraft-backup-*.tar.gz' \
        ! -path "$BACKUP_FILE" -mtime "+$BACKUP_RETENTION_DAYS" -delete
}

# Preserve important files during update
preserve_files() {
    PRESERVED_DIR="$WORK_DIR/preserve"
    mkdir -- "$PRESERVED_DIR"
    local entry
    for entry in "${PRESERVE_FILES[@]}" "${WORLD_DIRS[@]}"; do
        if [[ -e "$SERVER_DIR/$entry" || -L "$SERVER_DIR/$entry" ]]; then
            cp -a -- "$SERVER_DIR/$entry" "$PRESERVED_DIR/"
        fi
    done
}

# Install new server
install_server() {
    local extract_dir="$1" preserve_dir="$2" entry
    TRANSACTION_DIR=$(mktemp -d "$(dirname "$SERVER_DIR")/.minecraft-install.XXXXXXXX")
    local stage="$TRANSACTION_DIR/new"
    mkdir -- "$stage"
    cp -a -- "$extract_dir/." "$stage/"
    # Replace preserved directories instead of merging with new defaults.
    for entry in "${PRESERVE_FILES[@]}" "${WORLD_DIRS[@]}"; do
        if [[ -e "$preserve_dir/$entry" || -L "$preserve_dir/$entry" ]]; then
            rm -rf -- "$stage/$entry"
            cp -a -- "$preserve_dir/$entry" "$stage/"
        fi
    done
    # Reject symlinks in preserved data before root chmod/chown operations.
    if [[ -n "$(find "$stage" -type l -print -quit)" ]]; then
        log ERROR "Symlinks in preserved data require manual review"; return 1
    fi
    store_version_info "$stage"
    chmod +x "$stage/$SERVER_EXECUTABLE"
    chown -R "$SERVER_USER:$SERVER_USER" "$stage"
    chmod 750 "$stage"
    # Both renames remain on the same filesystem. Keep old files until startup passes.
    if [[ -d "$SERVER_DIR" ]]; then
        mv -- "$SERVER_DIR" "$TRANSACTION_DIR/old"
    fi
    NEW_PROMOTED=true
    mv -- "$stage" "$SERVER_DIR"
    log INFO "Replacement installed; previous installation retained until verification"
}

# Store version information to a file for future reference
store_version_info() {
    local version_file="${1:-$SERVER_DIR}/.installed_version"
    local install_date=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Extract version from the download URL if possible
    local installed_version=""
    if [[ -n "$DETECTED_DOWNLOAD_URL" ]]; then
        installed_version=$(echo "$DETECTED_DOWNLOAD_URL" | sed -nE 's/.*bedrock-server-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$/\1/p' 2>/dev/null || echo "")
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
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

# Main update process
main() {
    validate_config || { printf "%s\n" "Unsafe or invalid configuration" >&2; exit 1; }
    check_root
    check_requirements
    setup_directories
    get_installed_version
    local installed_version="$INSTALLED_VERSION"
    get_latest_download_url
    local download_url="$DETECTED_DOWNLOAD_URL" latest_version
    latest_version=$(printf '%s\n' "$download_url" | sed -nE 's/.*bedrock-server-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$/\1/p')
    [[ -n "$latest_version" ]] || { log ERROR "Cannot determine target version"; exit 1; }
    if ! check_update_needed "$installed_version" "$latest_version"; then
        notify_no_update "$installed_version"
        return 0
    fi
    notify_update_start "$installed_version"
    download_server "$download_url"
    extract_server "$DOWNLOADED_FILE"
    if is_server_running; then SERVER_WAS_RUNNING=true; fi
    STOP_ATTEMPTED=true
    stop_server
    backup_server
    preserve_files "$EXTRACTED_DIR"
    install_server "$EXTRACTED_DIR" "$PRESERVED_DIR"
    if [[ "$SERVER_WAS_RUNNING" == true ]]; then
        start_server
    fi
    UPDATE_COMMITTED=true
    cleanup_old_backups || log WARN "Update committed, but backup retention cleanup failed"
    log INFO "Update completed: $installed_version → $latest_version"
    notify_update_success "$installed_version" "$latest_version"
}

# EXIT runs for explicit exits and errors; signals use conventional failure statuses.
finish_update() {
    local status=$? recovery_failed=false
    trap - EXIT ERR INT TERM
    set +e
    if [[ "$status" -ne 0 && "$UPDATE_COMMITTED" != true ]]; then
        log ERROR "Update failed (exit $status); recovering previous installation"
        if [[ -n "$TRANSACTION_DIR" && -d "$TRANSACTION_DIR/old" ]] || [[ "$NEW_PROMOTED" == true ]]; then
            if is_server_running; then
                timeout 180 "$SCRIPT_DIR/stop-server.sh" --force
            fi
            if is_server_running; then
                recovery_failed=true
                log ERROR "Cannot stop replacement; retained recovery files: $TRANSACTION_DIR"
            else
                if [[ "$NEW_PROMOTED" == true && -d "$SERVER_DIR" ]]; then
                    mv -- "$SERVER_DIR" "$TRANSACTION_DIR/failed" || recovery_failed=true
                fi
                if [[ "$recovery_failed" == false && -d "$TRANSACTION_DIR/old" ]]; then
                    mv -- "$TRANSACTION_DIR/old" "$SERVER_DIR" || recovery_failed=true
                fi
            fi
        fi
        if [[ "$recovery_failed" == false && "$SERVER_WAS_RUNNING" == true && "$STOP_ATTEMPTED" == true ]]; then
            if ! is_server_running; then
                start_server || { recovery_failed=true; log ERROR "Previous server could not restart; backup: $BACKUP_FILE"; }
            fi
        fi
        notify_update_failure "Update failed (exit $status). Recovery files: ${TRANSACTION_DIR:-none}; backup: ${BACKUP_FILE:-none}. Check logs."
    fi
    cleanup_temp
    if [[ -n "$TRANSACTION_DIR" && -d "$TRANSACTION_DIR" ]]; then
        if [[ "$UPDATE_COMMITTED" == true || ( "$status" -eq 0 && "$recovery_failed" == false ) ]]; then
            rm -rf -- "$TRANSACTION_DIR"
        else
            log WARN "Retained transaction files for inspection: $TRANSACTION_DIR"
        fi
    fi
    exit "$status"
}

trap finish_update EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
