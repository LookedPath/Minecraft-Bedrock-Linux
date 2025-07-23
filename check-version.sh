#!/bin/bash

# Minecraft Bedrock Server Version Checker
# This script checks for the latest available Minecraft Bedrock server version

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        DEBUG) echo -e "${BLUE}[DEBUG]${NC} $message" ;;
        HEADER) echo -e "${CYAN}$message${NC}" ;;
    esac
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

# Get the latest available version
get_latest_version() {
    local temp_dir="/tmp/mc-version-check"
    mkdir -p "$temp_dir"
    
    log INFO "Checking for latest Minecraft Bedrock server version..."
    
    local latest_version=""
    
    # Method 1: Use the official Minecraft API
    log DEBUG "Fetching version from official Minecraft API..."
    local api_url="https://net-secondary.web.minecraft-services.net/api/v1.0/download/links"
    local temp_json="$temp_dir/minecraft_api.json"
    
    if timeout 30 wget --timeout=15 --tries=2 --user-agent="$USER_AGENT" -q -O "$temp_json" "$api_url" 2>/dev/null; then
        log DEBUG "Successfully fetched API response"
        
        # Check if we have jq available for better JSON parsing
        if command -v jq &>/dev/null; then
            # Use jq for robust JSON parsing
            local download_url=$(jq -r '.result.links[] | select(.downloadType=="serverBedrockLinux") | .downloadUrl' "$temp_json" 2>/dev/null || echo "")
            if [[ -n "$download_url" && "$download_url" != "null" ]]; then
                latest_version=$(echo "$download_url" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "")
                log INFO "Found latest version using API: $latest_version"
            fi
        else
            # Fallback to grep/sed parsing if jq is not available
            log DEBUG "jq not available, using grep/sed for JSON parsing"
            
            local linux_entry=$(grep -o '"downloadType":"serverBedrockLinux","downloadUrl":"[^"]*"' "$temp_json" 2>/dev/null || echo "")
            if [[ -n "$linux_entry" ]]; then
                local download_url=$(echo "$linux_entry" | sed 's/.*"downloadUrl":"//;s/".*//' 2>/dev/null || echo "")
                if [[ -n "$download_url" ]]; then
                    latest_version=$(echo "$download_url" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "")
                    log INFO "Found latest version using API: $latest_version"
                fi
            fi
        fi
        
        rm -f "$temp_json"
    else
        log WARN "Failed to fetch from official Minecraft API"
    fi
    
    # Method 2: Fallback to website scraping if API fails
    if [[ -z "$latest_version" ]]; then
        log DEBUG "API failed, falling back to website scraping..."
        local temp_page="$temp_dir/minecraft_page.html"
        
        if timeout 30 wget --timeout=15 --tries=2 --user-agent="$USER_AGENT" -q -O "$temp_page" "https://www.minecraft.net/en-us/download/server/bedrock" 2>/dev/null; then
            latest_version=$(grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$temp_page" 2>/dev/null | head -1 || echo "")
            
            if [[ -n "$latest_version" ]]; then
                log INFO "Found latest version from website: $latest_version"
            fi
            
            rm -f "$temp_page"
        else
            log WARN "Failed to fetch version from official website"
        fi
    fi
    
    # Method 3: Extract version from configured URL as final fallback
    if [[ -z "$latest_version" ]]; then
        latest_version=$(echo "$DOWNLOAD_URL" | grep -oP 'bedrock-server-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "unknown")
        if [[ "$latest_version" != "unknown" ]]; then
            log INFO "Using version from configuration: $latest_version"
        fi
    fi
    
    rm -rf "$temp_dir"
    LATEST_VERSION="$latest_version"
}

# Compare versions
compare_versions() {
    local installed="$1"
    local latest="$2"
    
    log HEADER "=== Version Comparison ==="
    echo ""
    
    log INFO "Installed version: $installed"
    log INFO "Latest version:    $latest"
    echo ""
    
    if [[ "$installed" == "not-installed" ]]; then
        log WARN "Minecraft Bedrock server is not installed"
        log INFO "Run: sudo ./update-server.sh to install"
        return 1
    elif [[ "$latest" == "unknown" ]]; then
        log WARN "Could not determine latest version"
        log INFO "Check your internet connection or update manually"
        return 1
    elif [[ "$installed" == "$latest" ]]; then
        log INFO "✓ Server is up to date!"
        return 0
    else
        # Try version comparison if both are proper version numbers
        if [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1 | grep -q "^$installed$"; then
                if [[ "$installed" != "$latest" ]]; then
                    log WARN "⚠ Server update available!"
                    log INFO "Run: sudo ./update-server.sh to update"
                    return 2
                fi
            else
                log WARN "⚠ Installed version is newer than detected latest?"
                log INFO "This might indicate a detection issue"
                return 3
            fi
        else
            log WARN "⚠ Cannot compare versions (non-standard format)"
            log INFO "Consider updating: sudo ./update-server.sh"
            return 2
        fi
    fi
}

# Show detailed information
show_detailed_info() {
    log HEADER "=== Detailed Server Information ==="
    echo ""
    
    # Server status
    if command -v "$SCRIPT_DIR/server-manager.sh" &>/dev/null; then
        if sudo -u "$SERVER_USER" screen -list 2>/dev/null | grep -q "$SCREEN_SESSION_NAME"; then
            log INFO "Server Status: ✓ Running"
        else
            log INFO "Server Status: ✗ Stopped"
        fi
    fi
    
    # Installation directory
    if [[ -d "$SERVER_DIR" ]]; then
        log INFO "Installation: ✓ $SERVER_DIR"
        
        # Directory size
        local dir_size=$(du -sh "$SERVER_DIR" 2>/dev/null | cut -f1 || echo "unknown")
        log INFO "Directory size: $dir_size"
        
        # Show installation details from version file if available
        local version_file="$SERVER_DIR/.installed_version"
        if [[ -f "$version_file" ]]; then
            local install_date=$(grep "^INSTALL_DATE=" "$version_file" 2>/dev/null | cut -d'=' -f2- || echo "unknown")
            local download_url=$(grep "^DOWNLOAD_URL=" "$version_file" 2>/dev/null | cut -d'=' -f2- || echo "unknown")
            log INFO "Install date: $install_date"
            if [[ "$download_url" != "unknown" && -n "$download_url" ]]; then
                log INFO "Source URL: $download_url"
            fi
        else
            # Fallback to file modification date
            if [[ -f "$SERVER_DIR/$SERVER_EXECUTABLE" ]]; then
                local mod_date=$(stat -c %y "$SERVER_DIR/$SERVER_EXECUTABLE" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
                log INFO "Last updated: $mod_date"
            fi
        fi
    else
        log INFO "Installation: ✗ Not found"
    fi
    
    # Backup information
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_count=$(find "$BACKUP_DIR" -name "minecraft-backup-*.tar.gz" -type f 2>/dev/null | wc -l)
        log INFO "Backups available: $backup_count"
        
        if [[ $backup_count -gt 0 ]]; then
            local latest_backup=$(find "$BACKUP_DIR" -name "minecraft-backup-*.tar.gz" -type f -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
            if [[ -n "$latest_backup" ]]; then
                local backup_name=$(basename "$latest_backup")
                log INFO "Latest backup: $backup_name"
            fi
        fi
    fi
    
    echo ""
}

# Main function
main() {
    local show_detailed=false
    local check_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--detailed)
                show_detailed=true
                shift
                ;;
            -c|--check-only)
                check_only=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  -d, --detailed    Show detailed server information"
                echo "  -c, --check-only  Only check versions, don't show details"
                echo "  -h, --help        Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                Check version with basic info"
                echo "  $0 --detailed     Check version with detailed server info"
                echo "  $0 --check-only   Just compare versions"
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    log HEADER "Minecraft Bedrock Server Version Checker"
    echo ""
    
    # Get versions
    get_installed_version
    local installed_version="$INSTALLED_VERSION"
    get_latest_version
    local latest_version="$LATEST_VERSION"
    
    # Compare versions
    compare_versions "$installed_version" "$latest_version"
    local comparison_result=$?
    
    # Show detailed info if requested
    if [[ "$show_detailed" == true && "$check_only" == false ]]; then
        show_detailed_info
    fi
    
    # Return appropriate exit code
    exit $comparison_result
}

# Run main function
main "$@"
