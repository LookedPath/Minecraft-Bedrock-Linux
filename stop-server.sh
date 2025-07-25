#!/bin/bash

# Minecraft Bedrock Server Stop Script
# This script gracefully stops the Minecraft Bedrock server

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

# Check if server is running
is_server_running() {
    if sudo -u "$SERVER_USER" screen -list | grep -q "$SCREEN_SESSION_NAME"; then
        return 0
    else
        return 1
    fi
}

# Send a message to all players before shutdown
send_shutdown_warning() {
    local countdown="$1"
    
    log INFO "Sending shutdown warning to players ($countdown seconds)..."
    
    local message="Server will shut down in $countdown seconds. Please save your progress!"
    
    # Send the message to the server console
    sudo -u "$SERVER_USER" screen -S "$SCREEN_SESSION_NAME" -X stuff "say $message\n"
}

# Send a command to the server console
send_server_command() {
    local command="$1"
    
    if is_server_running; then
        sudo -u "$SERVER_USER" screen -S "$SCREEN_SESSION_NAME" -X stuff "$command\n"
        return 0
    else
        log ERROR "Server is not running"
        return 1
    fi
}

# Gracefully stop the server
graceful_stop() {
    local force="$1"
    
    if ! is_server_running; then
        log INFO "Server is not running"
        return 0
    fi
    
    log INFO "Stopping Minecraft Bedrock Server gracefully..."
    
    # If not forcing, send warnings to players
    if [[ "$force" != "force" ]]; then
        # Send warnings at 60, 30, 15, 5 seconds
        send_shutdown_warning 60
        sleep 45
        
        if is_server_running; then
            send_shutdown_warning 15
            sleep 10
            
            if is_server_running; then
                send_shutdown_warning 5
                sleep 5
            fi
        fi
    fi
    
    if is_server_running; then
        # Save the world before stopping
        log INFO "Saving world data..."
        send_server_command "save hold"
        sleep 2
        send_server_command "save query"
        sleep 3
        send_server_command "save resume"
        sleep 2
        
        # Send stop command
        log INFO "Sending stop command to server..."
        send_server_command "stop"
        
        # Wait for server to stop (max 60 seconds)
        local count=0
        local max_wait=60
        
        log INFO "Waiting for server to stop (max $max_wait seconds)..."
        while is_server_running && [[ $count -lt $max_wait ]]; do
            sleep 1
            ((count++))
            
            # Show progress every 10 seconds
            if [[ $((count % 10)) -eq 0 ]]; then
                log INFO "Still waiting... ($count/$max_wait seconds)"
            fi
        done
        
        if is_server_running; then
            log WARN "Server didn't stop gracefully within $max_wait seconds"
            log WARN "Killing screen session..."
            sudo -u "$SERVER_USER" screen -S "$SCREEN_SESSION_NAME" -X quit
            sleep 2
            
            if is_server_running; then
                log ERROR "Failed to stop server"
                return 1
            else
                log WARN "Server stopped forcefully"
            fi
        else
            log INFO "Server stopped gracefully"
        fi
    fi
    
    return 0
}

# Force stop the server (immediate)
force_stop() {
    if ! is_server_running; then
        log INFO "Server is not running"
        return 0
    fi
    
    log WARN "Force stopping Minecraft Bedrock Server..."
    
    # Kill the screen session immediately
    sudo -u "$SERVER_USER" screen -S "$SCREEN_SESSION_NAME" -X quit
    sleep 2
    
    if is_server_running; then
        log ERROR "Failed to force stop server"
        return 1
    else
        log INFO "Server stopped forcefully"
    fi
    
    return 0
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
    else
        log INFO "✗ Server is not running"
    fi
    
    echo ""
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -f, --force     Force stop the server immediately (no warnings)"
    echo "  -s, --status    Show server status only"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              Stop server gracefully with player warnings"
    echo "  $0 --force      Stop server immediately"
    echo "  $0 --status     Check if server is running"
}

# Main function
main() {
    local action="stop"
    local force_mode="normal"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force_mode="force"
                shift
                ;;
            -s|--status)
                action="status"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    log INFO "Minecraft Bedrock Server Stop Script"
    
    case "$action" in
        "status")
            show_status
            ;;
        "stop")
            if [[ "$force_mode" == "force" ]]; then
                force_stop
            else
                graceful_stop "$force_mode"
            fi
            show_status
            ;;
    esac
}

# Run main function
main "$@"
