#!/bin/bash

# Minecraft Bedrock Server Installation and Setup Script
# This script sets up the initial environment for the Minecraft server

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/common.sh"

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
    local required_commands=("wget" "screen" "tar" "sudo" "python3" "realpath" "flock" "timeout")
    local missing=false
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log ERROR "Required command not found: $cmd"
            missing=true
        fi
    done
    if [[ "$missing" == true ]]; then
        show_dependency_commands
        return 1
    fi

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
    chown -R "$SERVER_USER:$SERVER_USER" "$SERVER_DIR"
    chown root:root "$BACKUP_DIR"
    
    # Set permissions
    chmod 750 "$SERVER_DIR"
    chmod 700 "$BACKUP_DIR"
    chmod 755 "$LOG_DIR"
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

# Root attaches by running Screen as the server user
multiuser off

# No shared-user access control changes are required.

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
    
    # Leave distribution-managed Screen socket directories untouched.

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
alias mcstart='sudo $SCRIPT_DIR/start-server.sh'
alias mcstop='sudo $SCRIPT_DIR/stop-server.sh'
alias mcstatus='$SCRIPT_DIR/server-manager.sh status'
alias mcconnect='$SCRIPT_DIR/server-manager.sh connect'
alias mcupdate='sudo $SCRIPT_DIR/update-server.sh'
alias mcrestart='sudo $SCRIPT_DIR/server-manager.sh restart'
alias mcversion='$SCRIPT_DIR/check-version.sh'
alias mcbackup='sudo $SCRIPT_DIR/update-server.sh'
EOF
    
    chown "$SERVER_USER:$SERVER_USER" "$alias_file"
    chmod 644 "$alias_file"
    
    # Also create system-wide aliases
    cat > "/etc/profile.d/minecraft.sh" << EOF
# Minecraft Server Management Aliases (System-wide)
alias mcstart='sudo $SCRIPT_DIR/start-server.sh'
alias mcstop='sudo $SCRIPT_DIR/stop-server.sh'
alias mcstatus='$SCRIPT_DIR/server-manager.sh status'
alias mcconnect='$SCRIPT_DIR/server-manager.sh connect'
alias mcupdate='sudo $SCRIPT_DIR/update-server.sh'
alias mcrestart='sudo $SCRIPT_DIR/server-manager.sh restart'
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
        (crontab -l 2>/dev/null || true; echo "$cron_job") | crontab -
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

# Package installation is opt-in and happens before validation needs GNU realpath.
install_dependencies() {
    log INFO "Installing required packages with the system package manager..."
    if command -v apt-get >/dev/null; then
        apt-get update
        apt-get install -y python3 coreutils util-linux wget screen tar sudo
    elif command -v dnf >/dev/null; then
        dnf install -y python3 coreutils util-linux wget screen tar sudo
    elif command -v yum >/dev/null; then
        yum install -y python3 coreutils util-linux wget screen tar sudo
    elif command -v pacman >/dev/null; then
        # Use the existing repository database; do not upgrade unrelated packages.
        pacman -S --needed --noconfirm python coreutils util-linux wget screen tar sudo
    elif command -v zypper >/dev/null; then
        zypper --non-interactive install python3 coreutils util-linux wget screen tar sudo
    else
        log ERROR "No supported package manager found. Install Python 3, GNU coreutils, util-linux, wget, screen, tar and sudo manually."
        return 1
    fi
}

show_dependency_commands() {
    log INFO "Install dependencies and apply compatibility changes with:"
    log INFO "  sudo bash $SCRIPT_DIR/setup.sh --upgrade --install-dependencies"
    log INFO "Or install Python 3, GNU coreutils and util-linux with your package manager."
}

get_server_home() {
    local account
    account=$(getent passwd "$SERVER_USER") || return 1
    SERVER_HOME=$(printf '%s\n' "$account" | cut -d: -f6)
    [[ "$SERVER_HOME" == /*/* && "$(realpath -m -- "$SERVER_HOME")" == "$SERVER_HOME" && -d "$SERVER_HOME" ]] || {
        log ERROR "Server account must have an existing, canonical home directory"; return 1;
    }
    [[ "$(id -u "$SERVER_USER")" != 0 ]] || { log ERROR "Server account must not be root"; return 1; }
}

repair_screen_runtime() {
    # Reapply distribution policy instead of assuming a shared socket directory mode.
    if command -v systemd-tmpfiles >/dev/null; then
        systemd-tmpfiles --create --prefix=/run/screen || return 1
    fi
    local directory mode
    for directory in /run/screen /var/run/screen; do
        [[ -d "$directory" ]] || continue
        mode=$(stat -c %a "$directory") || return 1
        if (( (8#$mode & 0002) != 0 && (8#$mode & 01000) == 0 )); then
            log ERROR "Unsafe legacy Screen permissions remain on $directory."
            log ERROR "Reinstall the distribution's screen package, then rerun setup.sh --upgrade."
            log ERROR "Debian/Ubuntu: sudo apt-get install --reinstall screen"
            log ERROR "Fedora/RHEL: sudo dnf reinstall screen"
            return 1
        fi
    done
    [[ -d /run/screen || -d /var/run/screen ]] || {
        log ERROR "Screen runtime directory missing; reinstall the screen package and rerun --upgrade"; return 1;
    }
    # The old setup created this private socket directory with mode 755.
    directory="/run/screen/S-$SERVER_USER"
    [[ -e "$directory" || -L "$directory" ]] || return 0
    [[ -d "$directory" && ! -L "$directory" ]] || {
        log ERROR "Refusing unsafe Screen user socket directory: $directory"; return 1;
    }
    chown "$SERVER_USER:$(id -gn "$SERVER_USER")" "$directory" || return 1
    chmod 700 "$directory" || return 1
}

upgrade_installation() {
    get_server_home || return 1
    [[ -d "$SERVER_DIR" ]] || {
        log ERROR "No existing installation at $SERVER_DIR. Use setup.sh for a new installation."; return 1;
    }
    # Legacy scripts do not hold our lock. Run this during a maintenance window.
    if has_server_process || has_screen_session; then
        log ERROR "Stop the existing server before running --upgrade."
        return 1
    fi
    repair_screen_runtime || return 1
    mkdir -p -- "$BACKUP_DIR" "$LOG_DIR"
    chown root:root "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'minecraft-backup-*.tar.gz' \
        -exec chown root:root {} + -exec chmod 600 {} +
    chmod 750 "$SERVER_DIR"
    python3 "$SCRIPT_DIR/migrate-settings.py" "$SERVER_HOME/.screenrc" \
        "$SERVER_HOME/.bash_aliases" /etc/profile.d/minecraft.sh
    setup_script_permissions
    log INFO "Compatibility upgrade completed. Server data and config.sh were preserved."
    log INFO "Existing systemd service, firewall rules and cron jobs were left in place."
    log INFO "Reload aliases with: source /etc/profile.d/minecraft.sh"
    log INFO "Start the server with: sudo $SCRIPT_DIR/start-server.sh"
}

show_usage() {
    cat <<'USAGE'
Usage: sudo bash setup.sh [--upgrade | --check] [--install-dependencies]

  (no mode)                Set up a new server installation.
  --upgrade                Apply compatibility changes to an existing installation.
                           Stop the old server first; safe to rerun.
  --check                  Check dependencies and configuration without changes.
  --install-dependencies   Install required packages using apt/dnf/yum/pacman/zypper.
                           Optional for new setup or --upgrade; not valid with --check.
  -h, --help               Show this help.
USAGE
}

# Main setup function
main() {
    local mode=setup install_packages=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --upgrade|--check)
                [[ "$mode" == setup ]] || { log ERROR "Choose one setup mode"; return 1; }
                mode=${1#--} ;;
            --install-dependencies) install_packages=true ;;
            -h|--help) show_usage; return 0 ;;
            *) log ERROR "Unknown option: $1"; show_usage; return 1 ;;
        esac
        shift
    done
    if [[ "$mode" == check && "$install_packages" == true ]]; then
        log ERROR "--check cannot install packages"; return 1
    fi
    check_root
    if [[ "$install_packages" == true ]]; then install_dependencies; fi
    check_requirements
    validate_config || { log ERROR "Unsafe or invalid configuration; review config.sh"; return 1; }
    if [[ "$mode" == check ]]; then
        log INFO "Dependencies and configuration are compatible."
        log INFO "For an installation created by the old setup, run: sudo bash $SCRIPT_DIR/setup.sh --upgrade"
        return 0
    fi
    acquire_management_lock
    if [[ "$mode" == upgrade ]]; then
        upgrade_installation
        return
    fi
    log INFO "Starting Minecraft Bedrock Server setup..."
    create_user
    setup_directories
    setup_screen
    setup_script_permissions
    create_aliases
    setup_update_cron
    create_systemd_service
    setup_firewall
    show_completion_message
}

# Run main function
main "$@"
