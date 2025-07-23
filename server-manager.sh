#!/bin/bash

# Minecraft Bedrock Server Status and Management Script
# This script provides status information and basic management commands

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

# Check if server is running
is_server_running() {
    if sudo -u "$SERVER_USER" screen -list | grep -q "$SCREEN_SESSION_NAME"; then
        return 0
    else
        return 1
    fi
}

# Get server process information
get_server_process_info() {
    local pid=$(pgrep -f "$SERVER_EXECUTABLE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]]; then
        echo "$pid"
    else
        echo ""
    fi
}

# Show server status
show_server_status() {
    log HEADER "=== Minecraft Bedrock Server Status ==="
    echo ""
    
    # Check if server is running
    if is_server_running; then
        log INFO "✓ Server is RUNNING"
        
        # Get process information
        local pid=$(get_server_process_info)
        if [[ -n "$pid" ]]; then
            log INFO "Process ID: $pid"
            
            # Show memory usage
            local memory=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
            if [[ -n "$memory" ]]; then
                local memory_mb=$((memory / 1024))
                log INFO "Memory usage: ${memory_mb}MB"
            fi
            
            # Show CPU usage
            local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
            if [[ -n "$cpu" ]]; then
                log INFO "CPU usage: ${cpu}%"
            fi
            
            # Show uptime
            local start_time=$(ps -p "$pid" -o lstart= 2>/dev/null)
            if [[ -n "$start_time" ]]; then
                log INFO "Started: $start_time"
            fi
        fi
        
        # Show screen session info
        echo ""
        log INFO "Screen session details:"
        sudo -u "$SERVER_USER" screen -list | grep "$SCREEN_SESSION_NAME" || log WARN "No screen session found"
        
    else
        log WARN "✗ Server is NOT RUNNING"
    fi
    
    echo ""
}

# Show server directory status
show_directory_status() {
    log HEADER "=== Directory Status ==="
    echo ""
    
    if [[ -d "$SERVER_DIR" ]]; then
        log INFO "✓ Server directory exists: $SERVER_DIR"
        
        # Check for server executable
        if [[ -f "$SERVER_DIR/$SERVER_EXECUTABLE" ]]; then
            log INFO "✓ Server executable found"
            if [[ -x "$SERVER_DIR/$SERVER_EXECUTABLE" ]]; then
                log INFO "✓ Server executable is executable"
            else
                log WARN "✗ Server executable is not executable"
            fi
        else
            log ERROR "✗ Server executable not found"
        fi
        
        # Check for world data
        if [[ -d "$SERVER_DIR/worlds" ]]; then
            local world_count=$(find "$SERVER_DIR/worlds" -maxdepth 1 -type d | wc -l)
            log INFO "✓ Worlds directory found ($((world_count - 1)) worlds)"
        else
            log WARN "✗ Worlds directory not found"
        fi
        
        # Check for configuration files
        for file in "${PRESERVE_FILES[@]}"; do
            if [[ -f "$SERVER_DIR/$file" ]]; then
                log INFO "✓ Configuration file: $file"
            else
                log WARN "✗ Configuration file missing: $file"
            fi
        done
        
        # Show disk usage
        local disk_usage=$(du -sh "$SERVER_DIR" 2>/dev/null | cut -f1)
        log INFO "Disk usage: $disk_usage"
        
    else
        log ERROR "✗ Server directory not found: $SERVER_DIR"
        log ERROR "Run update-server.sh to install the server"
    fi
    
    echo ""
}

# Show backup status
show_backup_status() {
    log HEADER "=== Backup Status ==="
    echo ""
    
    if [[ -d "$BACKUP_DIR" ]]; then
        log INFO "✓ Backup directory exists: $BACKUP_DIR"
        
        local backup_count=$(find "$BACKUP_DIR" -name "minecraft-backup-*.tar.gz" -type f 2>/dev/null | wc -l)
        log INFO "Available backups: $backup_count"
        
        if [[ $backup_count -gt 0 ]]; then
            echo ""
            log INFO "Recent backups:"
            find "$BACKUP_DIR" -name "minecraft-backup-*.tar.gz" -type f -printf "%T@ %s %p\n" 2>/dev/null | \
                sort -nr | head -5 | while IFS=' ' read -r timestamp size path; do
                local backup_name=$(basename "$path")
                local size_mb=$((size / 1024 / 1024))
                local backup_date=$(date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                echo "  $backup_name (${size_mb}MB) - $backup_date"
            done
        fi
        
        # Show backup directory disk usage
        local backup_disk_usage=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        log INFO "Backup directory disk usage: $backup_disk_usage"
        
    else
        log WARN "✗ Backup directory not found: $BACKUP_DIR"
    fi
    
    echo ""
}

# Show log information
show_log_status() {
    log HEADER "=== Log Status ==="
    echo ""
    
    if [[ -f "$LOG_FILE" ]]; then
        log INFO "✓ Log file exists: $LOG_FILE"
        
        local log_size=$(du -sh "$LOG_FILE" 2>/dev/null | cut -f1)
        log INFO "Log file size: $log_size"
        
        local log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        log INFO "Log entries: $log_lines lines"
        
        echo ""
        log INFO "Recent log entries (last 10):"
        tail -n 10 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
            echo "  $line"
        done
        
    else
        log WARN "✗ Log file not found: $LOG_FILE"
    fi
    
    echo ""
}

# Connect to server console
connect_to_console() {
    if ! is_server_running; then
        log ERROR "Server is not running"
        return 1
    fi
    
    log INFO "Connecting to server console..."
    log INFO "Press Ctrl+A, then D to detach from the console"
    echo ""
    
    # Connect to the screen session
    sudo -u "$SERVER_USER" screen -r "$SCREEN_SESSION_NAME"
}

# Send command to server
send_command() {
    local command="$1"
    
    if ! is_server_running; then
        log ERROR "Server is not running"
        return 1
    fi
    
    log INFO "Sending command to server: $command"
    sudo -u "$SERVER_USER" screen -S "$SCREEN_SESSION_NAME" -X stuff "$command\n"
}

# Show usage information
show_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status          Show complete server status (default)"
    echo "  connect         Connect to server console"
    echo "  command <cmd>   Send command to server"
    echo "  start           Start the server"
    echo "  stop            Stop the server gracefully"
    echo "  restart         Restart the server"
    echo "  update          Update the server"
    echo ""
    echo "Examples:"
    echo "  $0                      Show server status"
    echo "  $0 connect              Connect to server console"
    echo "  $0 command \"say Hello\"   Send a message to players"
    echo "  $0 start                Start the server"
    echo "  $0 stop                 Stop the server"
    echo "  $0 restart              Restart the server"
}

# Main function
main() {
    local command="${1:-status}"
    
    case "$command" in
        "status"|"")
            show_server_status
            show_directory_status
            show_backup_status
            show_log_status
            ;;
        "connect"|"console")
            connect_to_console
            ;;
        "command"|"cmd")
            if [[ $# -lt 2 ]]; then
                log ERROR "Command argument required"
                log ERROR "Usage: $0 command <server_command>"
                exit 1
            fi
            send_command "$2"
            ;;
        "start")
            "$SCRIPT_DIR/start-server.sh"
            ;;
        "stop")
            "$SCRIPT_DIR/stop-server.sh"
            ;;
        "restart")
            "$SCRIPT_DIR/stop-server.sh"
            sleep 5
            "$SCRIPT_DIR/start-server.sh"
            ;;
        "update")
            "$SCRIPT_DIR/update-server.sh"
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            log ERROR "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
