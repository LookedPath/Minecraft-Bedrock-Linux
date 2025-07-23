#!/bin/bash

# Minecraft Bedrock Server Start Script
# This script starts the Minecraft Bedrock server in a screen session
# The screen session can be accessed by both the mcserver user and root

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
        log ERROR "This script must be run as root to set up screen permissions"
        log ERROR "Please run: sudo $0"
        exit 1
    fi
}

# Check if server is already running
is_server_running() {
    if sudo -u "$SERVER_USER" screen -list | grep -q "$SCREEN_SESSION_NAME"; then
        return 0
    else
        return 1
    fi
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

# Setup screen permissions for multi-user access
setup_screen_permissions() {
    # Set screen directory permissions - screen requires mode 777
    if [[ $EUID -eq 0 ]]; then
        # Create the main screen directory if it doesn't exist
        if [[ ! -d "/run/screen" ]]; then
            mkdir -p "/run/screen"
        fi
        
        # Screen requires mode 777 on the main directory
        chmod 777 "/run/screen" 2>/dev/null || true
        
        # Also handle /var/run/screen if it exists (legacy path)
        if [[ -d "/var/run/screen" ]]; then
            chmod 777 "/var/run/screen" 2>/dev/null || true
        fi
    fi
    
    # Create user-specific screen directory with proper permissions
    local screen_dir="/run/screen/S-$SERVER_USER"
    if [[ ! -d "$screen_dir" ]]; then
        mkdir -p "$screen_dir"
        chown "$SERVER_USER:$SERVER_USER" "$screen_dir"
        chmod 755 "$screen_dir"
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
    
    # Change to server directory
    cd "$SERVER_DIR"
    
    # Start server in screen session as the mcserver user
    # Use script to ensure proper TTY handling and multi-user access
    sudo -u "$SERVER_USER" screen -dmS "$SCREEN_SESSION_NAME" bash -c "
        echo 'Starting Minecraft Bedrock Server...'
        echo 'Session: $SCREEN_SESSION_NAME'
        echo 'Server Directory: $SERVER_DIR'
        echo 'Started at: \$(date)'
        echo '=========================='
        echo ''
        LD_LIBRARY_PATH=. ./$SERVER_EXECUTABLE
    "
    
    # Wait a moment for the server to start
    sleep 3
    
    # Check if the server started successfully
    if is_server_running; then
        log INFO "Server started successfully!"
        log INFO "Screen session name: $SCREEN_SESSION_NAME"
        log INFO ""
        log INFO "To attach to the server console:"
        log INFO "  As $SERVER_USER: screen -r $SCREEN_SESSION_NAME"
        log INFO "  As root: sudo -u $SERVER_USER screen -r $SCREEN_SESSION_NAME"
        log INFO ""
        log INFO "To detach from the console: Press Ctrl+A, then D"
        log INFO "To stop the server: Use the stop-server.sh script or type 'stop' in the console"
    else
        log ERROR "Failed to start the server"
        log ERROR "Check the server logs for more information"
        exit 1
    fi
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
