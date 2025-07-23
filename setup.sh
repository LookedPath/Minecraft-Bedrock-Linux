#!/bin/bash

# Minecraft Bedrock Server Installation and Setup Script
# This script sets up the initial environment for the Minecraft server

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
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root"
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    log INFO "Checking system requirements..."
    
    # Check for required commands
    local required_commands=("wget" "unzip" "screen" "tar" "sudo")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log ERROR "Required command not found: $cmd"
            log ERROR "Please install $cmd and try again"
            exit 1
        fi
    done
    
    # Check if we're on a 64-bit system
    if [[ $(uname -m) != "x86_64" ]]; then
        log WARN "Minecraft Bedrock Server requires a 64-bit system"
        log WARN "Current architecture: $(uname -m)"
    fi
    
    log INFO "System requirements check passed"
}

# Create mcserver user if it doesn't exist
create_user() {
    if id "$SERVER_USER" &>/dev/null; then
        log INFO "User $SERVER_USER already exists"
    else
        log INFO "Creating user: $SERVER_USER"
        
        # Create user with home directory
        useradd -m -s /bin/bash "$SERVER_USER"
        
        # Set up user's bashrc
        echo '# Minecraft server user profile' >> "/home/$SERVER_USER/.bashrc"
        echo 'export PATH=$PATH:/usr/games' >> "/home/$SERVER_USER/.bashrc"
        
        log INFO "User $SERVER_USER created successfully"
    fi
}

# Setup directories with proper permissions
setup_directories() {
    log INFO "Setting up directories..."
    
    # Create all necessary directories
    local directories=(
        "$SERVER_DIR"
        "$BACKUP_DIR"
        "$LOG_DIR"
        "/home/$SERVER_USER/.minecraft"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log INFO "Created directory: $dir"
        fi
    done
    
    # Set ownership for server-related directories
    chown -R "$SERVER_USER:$SERVER_USER" "$SERVER_DIR" "$BACKUP_DIR" "/home/$SERVER_USER"
    
    # Set permissions
    chmod 755 "$SERVER_DIR" "$BACKUP_DIR" "$LOG_DIR"
    chmod 750 "/home/$SERVER_USER"
    
    log INFO "Directories setup completed"
}

# Setup screen configuration for multi-user access
setup_screen() {
    log INFO "Setting up screen configuration..."
    
    # Create screen configuration for the server user
    local screenrc="/home/$SERVER_USER/.screenrc"
    
    cat > "$screenrc" << 'EOF'
# Minecraft Server Screen Configuration

# Set default shell
shell /bin/bash

# Don't display the copyright page
startup_message off

# Increase scrollback buffer
defscrollback 10000

# Enable mouse scrolling
termcapinfo xterm* ti@:te@

# Set screen to be accessible by multiple users
multiuser on

# Allow root to attach
acladd root

# Set default window title
shelltitle "Minecraft Server"

# Status line
hardstatus alwayslastline
hardstatus string '%{= kG}[ %{G}%H %{g}][%= %{= kw}%?%-Lw%?%{r}(%{W}%n*%f%t%?(%u)%?%{r})%{w}%?%+Lw%?%?%= %{g}][%{B} %d/%m %{W}%c %{g}]'

# Bind keys for easier navigation
bind ^A other
bind ^Q quit
bind ^D detach
EOF
    
    chown "$SERVER_USER:$SERVER_USER" "$screenrc"
    chmod 644 "$screenrc"
    
    # Ensure screen directories have proper permissions
    # Screen requires mode 777 on the main directory for multi-user access
    mkdir -p "/run/screen"
    chmod 777 "/run/screen"
    
    # Also handle legacy path if it exists
    if [[ -d "/var/run/screen" ]]; then
        chmod 777 "/var/run/screen"
    fi
    
    log INFO "Screen configuration completed"
}

# Create systemd service (optional)
create_systemd_service() {
    log INFO "Creating systemd service..."
    
    local service_file="/etc/systemd/system/minecraft-bedrock.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=Minecraft Bedrock Server
After=network.target

[Service]
Type=forking
User=root
Group=root
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/start-server.sh
ExecStop=$SCRIPT_DIR/stop-server.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and enable service
    systemctl daemon-reload
    
    log INFO "Systemd service created: minecraft-bedrock.service"
    log INFO "To enable auto-start: systemctl enable minecraft-bedrock"
    log INFO "To start via systemd: systemctl start minecraft-bedrock"
}

# Set up firewall rules (if ufw is available)
setup_firewall() {
    if command -v ufw &> /dev/null; then
        log INFO "Setting up firewall rules..."
        
        # Default Minecraft Bedrock port is 19132 UDP
        ufw allow 19132/udp comment "Minecraft Bedrock Server"
        
        log INFO "Firewall rules added for port 19132/UDP"
    else
        log WARN "UFW not found, skipping firewall setup"
        log WARN "Make sure to open port 19132/UDP in your firewall"
    fi
}

# Make scripts executable
setup_script_permissions() {
    log INFO "Setting up script permissions..."
    
    local scripts=(
        "$SCRIPT_DIR/update-server.sh"
        "$SCRIPT_DIR/start-server.sh"
        "$SCRIPT_DIR/stop-server.sh"
        "$SCRIPT_DIR/server-manager.sh"
        "$SCRIPT_DIR/check-version.sh"
        "$SCRIPT_DIR/setup.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            log INFO "Made executable: $(basename "$script")"
        fi
    done
}

# Create helpful aliases
create_aliases() {
    log INFO "Creating helpful command aliases..."
    
    local alias_file="/home/$SERVER_USER/.bash_aliases"
    
    cat > "$alias_file" << EOF
# Minecraft Server Management Aliases
alias mcstart='$SCRIPT_DIR/start-server.sh'
alias mcstop='$SCRIPT_DIR/stop-server.sh'
alias mcstatus='$SCRIPT_DIR/server-manager.sh status'
alias mcconnect='$SCRIPT_DIR/server-manager.sh connect'
alias mcupdate='sudo $SCRIPT_DIR/update-server.sh'
alias mcrestart='$SCRIPT_DIR/server-manager.sh restart'
alias mcversion='$SCRIPT_DIR/check-version.sh'
alias mcbackup='sudo $SCRIPT_DIR/update-server.sh'
EOF
    
    chown "$SERVER_USER:$SERVER_USER" "$alias_file"
    chmod 644 "$alias_file"
    
    # Also create system-wide aliases
    cat > "/etc/profile.d/minecraft.sh" << EOF
# Minecraft Server Management Aliases (System-wide)
alias mcstart='$SCRIPT_DIR/start-server.sh'
alias mcstop='$SCRIPT_DIR/stop-server.sh'
alias mcstatus='$SCRIPT_DIR/server-manager.sh status'
alias mcconnect='$SCRIPT_DIR/server-manager.sh connect'
alias mcupdate='sudo $SCRIPT_DIR/update-server.sh'
alias mcrestart='$SCRIPT_DIR/server-manager.sh restart'
alias mcversion='$SCRIPT_DIR/check-version.sh'
EOF
    
    chmod 644 "/etc/profile.d/minecraft.sh"
    
    log INFO "Aliases created successfully"
}

# Setup automatic update checking and updating via cron
setup_update_cron() {
    log INFO "Setting up automatic update checking and updating..."
    
    # Create log directory and file with proper permissions
    mkdir -p "/var/log/minecraft"
    touch "/var/log/minecraft/auto-update.log"
    chmod 644 "/var/log/minecraft/auto-update.log"
    
    # Add cron job to run update-server.sh every hour
    # The output will be logged to the auto-update.log file
    local cron_job="0 * * * * $SCRIPT_DIR/update-server.sh >> /var/log/minecraft/auto-update.log 2>&1"
    
    # Check if the cron job already exists to avoid duplicates
    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/update-server.sh"; then
        # Add the cron job
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        log INFO "Added hourly auto-update to crontab"
    else
        log INFO "Auto-update cron job already exists"
    fi
    
    log INFO "Automatic update system configured successfully"
    log INFO "The server will be checked for updates every hour"
    log INFO "Updates will be applied automatically if available"
    log INFO "All activity is logged to /var/log/minecraft/auto-update.log"
}

# Show completion message
show_completion_message() {
    echo ""
    log INFO "=================================="
    log INFO "Setup completed successfully!"
    log INFO "=================================="
    echo ""
    log INFO "Next steps:"
    log INFO "1. Run: $SCRIPT_DIR/update-server.sh"
    log INFO "   This will download and install the Minecraft Bedrock server"
    echo ""
    log INFO "2. Configure server settings:"
    log INFO "   Edit: $SERVER_DIR/server.properties"
    echo ""
    log INFO "3. Start the server:"
    log INFO "   Run: $SCRIPT_DIR/start-server.sh"
    echo ""
    log INFO "Useful commands:"
    log INFO "  Start server:     $SCRIPT_DIR/start-server.sh"
    log INFO "  Stop server:      $SCRIPT_DIR/stop-server.sh"
    log INFO "  Server status:    $SCRIPT_DIR/server-manager.sh status"
    log INFO "  Connect console:  $SCRIPT_DIR/server-manager.sh connect"
    log INFO "  Update server:    $SCRIPT_DIR/update-server.sh"
    echo ""
    log INFO "The server will run as user: $SERVER_USER"
    log INFO "Server directory: $SERVER_DIR"
    log INFO "Backup directory: $BACKUP_DIR"
    log INFO "Log directory: $LOG_DIR"
    echo ""
    log INFO "Automatic features:"
    log INFO "  Auto-updates: Every hour (logged to /var/log/minecraft/auto-update.log)"
    log INFO "  Systemd service: Available for auto-start on boot"
    echo ""
    log INFO "Firewall: Make sure port 19132/UDP is open"
    echo ""
}

# Main setup function
main() {
    log INFO "Starting Minecraft Bedrock Server setup..."
    
    # Perform setup steps
    check_root
    check_requirements
    create_user
    setup_directories
    setup_screen
    setup_script_permissions
    create_aliases
    setup_update_cron
    create_systemd_service
    setup_firewall
    
    # Show completion message
    show_completion_message
}

# Run main function
main "$@"
