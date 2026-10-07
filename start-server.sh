#!/bin/bash

# Minecraft Bedrock Server Start Script
# This script starts the Minecraft Bedrock server in a screen session
# The screen session can be accessed by both the mcserver user and root

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/common.sh"
validate_config || { printf "%s\n" "Unsafe or invalid configuration" >&2; exit 1; }

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
        log ERROR "This script must be run as root to set up screen permissions"
        log ERROR "Please run: sudo $0"
        exit 1
    fi
}

# Check if server is already running
is_server_running() {
    has_server_process || has_screen_session
}

# Check if server directory exists and has the executable
check_server_installation() {
    if [[ ! -d "$SERVER_DIR" ]]; then
        log ERROR "Server directory not found: $SERVER_DIR"
        log ERROR "Please run update-server.sh first to install the server"
        exit 1
    fi
    
    if [[ ! -f "$SERVER_DIR/$SERVER_EXECUTABLE" ]]; then
        log ERROR "Server executable not found: $SERVER_DIR/$SERVER_EXECUTABLE"
        log ERROR "Please run update-server.sh first to install the server"
        exit 1
    fi
    
    if [[ ! -x "$SERVER_DIR/$SERVER_EXECUTABLE" ]]; then
        log ERROR "Server executable is not executable: $SERVER_DIR/$SERVER_EXECUTABLE"
        exit 1
    fi
}

# Verify the distribution-managed Screen runtime directory
setup_screen_permissions() {
    # Socket directories and permissions belong to the distribution's screen package.
    # Root attaches by running screen as SERVER_USER; multiuser mode is unnecessary.
    if [[ ! -d /run/screen && ! -d /var/run/screen ]]; then
        log ERROR "Screen socket directory missing; repair the screen package installation"
        return 1
    fi
}

# Create log directory if it doesn't exist
setup_logging() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
        chmod 755 "$LOG_DIR"
    fi
    
    # Touch log file and set permissions
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# Start the server
start_server() {
    log INFO "Starting Minecraft Bedrock Server..."
    cd -- "$SERVER_DIR"
    # Use positional arguments; configured values must never become shell source.
    sudo -u "$SERVER_USER" screen -dmS "$SCREEN_SESSION_NAME" bash -c \
        'cd -- "$1" && exec env LD_LIBRARY_PATH=. "./$2"' \
        bedrock-start "$SERVER_DIR" "$SERVER_EXECUTABLE" 9>&-
    local elapsed
    for ((elapsed=0; elapsed<15; elapsed++)); do
        sleep 1
        if ! has_screen_session || ! has_server_process; then
            log ERROR "Server did not remain running during startup verification"
            return 1
        fi
    done
    log INFO "Server process and console remained running for 15 seconds"
}

# Show server status
show_status() {
    echo ""
    log INFO "Server Status:"
    
    if is_server_running; then
        log INFO "✓ Server is running"
        
        # Show screen sessions
        echo ""
        log INFO "Active screen sessions:"
        sudo -u "$SERVER_USER" screen -list | grep "$SCREEN_SESSION_NAME" || true
        
        # Show recent log entries if available
        if [[ -f "$LOG_FILE" ]]; then
            echo ""
            log INFO "Recent log entries:"
            tail -n 5 "$LOG_FILE" 2>/dev/null || true
        fi
    else
        log WARN "✗ Server is not running"
    fi
    
    echo ""
}

# Main function
main() {
    log INFO "Minecraft Bedrock Server Start Script"
    
    # Check if running as root
    check_root
    acquire_management_lock
    
    # Check if server is already running
    if is_server_running; then
        log WARN "Server is already running!"
        show_status
        exit 0
    fi
    
    # Setup logging
    setup_logging
    
    # Check server installation
    check_server_installation
    
    # Setup screen permissions
    setup_screen_permissions
    
    # Start the server
    start_server
    
    # Show status
    show_status
}

# Run main function
main "$@"
