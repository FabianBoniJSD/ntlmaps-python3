#!/bin/bash
# filepath: setup-ntlmaps.sh

# NTLM Authorization Proxy Server Setup Script
# This script automatically sets up NTLMAPS as a systemd service

set -e  # Exit on any error

# Configuration placeholders - modify these as needed
NTLM_USER="${NTLM_USER:-ntlmaps}"
NTLM_GROUP="${NTLM_GROUP:-ntlmaps}"
NTLM_HOME="${NTLM_HOME:-/opt/ntlmaps}"
NTLM_PORT="${NTLM_PORT:-5865}"
PARENT_PROXY="${PARENT_PROXY:-proxy.example.com}"
PARENT_PROXY_PORT="${PARENT_PROXY_PORT:-3128}"
NT_DOMAIN="${NT_DOMAIN:-example.com}"
SERVICE_NAME="ntlmaps"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Create user and group
create_user() {
    log_info "Creating user and group: ${NTLM_USER}"
    
    if ! getent group "$NTLM_GROUP" > /dev/null 2>&1; then
        groupadd --system "$NTLM_GROUP"
        log_success "Created group: ${NTLM_GROUP}"
    else
        log_warning "Group ${NTLM_GROUP} already exists"
    fi
    
    if ! getent passwd "$NTLM_USER" > /dev/null 2>&1; then
        useradd --system -g "$NTLM_GROUP" --home-dir "$NTLM_HOME" \
                --shell /bin/false --comment "NTLM Proxy Service" "$NTLM_USER"
        log_success "Created user: ${NTLM_USER}"
    else
        log_warning "User ${NTLM_USER} already exists"
    fi
}

# Create directories
create_directories() {
    log_info "Creating directories"
    
    mkdir -p "$NTLM_HOME"/{lib,logs}
    chown -R "$NTLM_USER:$NTLM_GROUP" "$NTLM_HOME"
    chmod 755 "$NTLM_HOME"
    
    log_success "Created directory structure at ${NTLM_HOME}"
}

# Install NTLMAPS files
install_files() {
    log_info "Installing NTLMAPS files"
    
    # Check if source directory exists
    if [[ ! -d "lib" ]] || [[ ! -f "main.py" ]]; then
        log_error "NTLMAPS source files not found. Please run this script from the ntlmaps directory."
        exit 1
    fi
    
    # Copy files
    cp -r lib/* "$NTLM_HOME/lib/"
    cp main.py "$NTLM_HOME/"
    
    # Set ownership and permissions
    chown -R "$NTLM_USER:$NTLM_GROUP" "$NTLM_HOME"
    chmod 644 "$NTLM_HOME"/*.py
    chmod 644 "$NTLM_HOME"/lib/*.py
    
    log_success "Installed NTLMAPS files"
}

# Create configuration file
create_config() {
    log_info "Creating configuration file"
    
    cat > "$NTLM_HOME/server.cfg" << EOF
#========================================================================
[GENERAL]

LISTEN_PORT:${NTLM_PORT}
PARENT_PROXY:${PARENT_PROXY}
PARENT_PROXY_PORT:${PARENT_PROXY_PORT}
PARENT_PROXY_TIMEOUT:15
ALLOW_EXTERNAL_CLIENTS:1
FRIENDLY_IPS:
URL_LOG:1
MAX_CONNECTION_BACKLOG:5

#========================================================================
[CLIENT_HEADER]

Accept: image/gif, image/x-xbitmap, image/jpeg, image/pjpeg, application/vnd.ms-excel, application/msword, application/vnd.ms-powerpoint, */*
User-Agent: Mozilla/4.0 (compatible; MSIE 5.5; Windows 98)

#========================================================================
[NTLM_AUTH]

NT_HOSTNAME:
NT_DOMAIN:${NT_DOMAIN}
USER:
PASSWORD:

LM_PART:1
NT_PART:1
NTLM_FLAGS: 07820000
NTLM_TO_BASIC:1

#========================================================================
[DEBUG]

DEBUG:1
BIN_DEBUG:0
SCR_DEBUG:0
AUTH_DEBUG:1
EOF

    chown "$NTLM_USER:$NTLM_GROUP" "$NTLM_HOME/server.cfg"
    chmod 600 "$NTLM_HOME/server.cfg"  # Secure config file
    
    log_success "Created configuration file"
}

# Create systemd service
create_service() {
    log_info "Creating systemd service"
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=NTLM Authorization Proxy Server
Documentation=https://github.com/ntlmaps/ntlmaps
After=network.target
Wants=network.target

[Service]
Type=simple
User=${NTLM_USER}
Group=${NTLM_GROUP}
WorkingDirectory=${NTLM_HOME}
ExecStart=/usr/bin/python3 ${NTLM_HOME}/main.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${NTLM_HOME}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Network settings
BindReadOnlyPaths=/etc/resolv.conf

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Created systemd service"
}

# Enable and start service
enable_service() {
    log_info "Enabling and starting service"
    
    systemctl enable "$SERVICE_NAME.service"
    systemctl start "$SERVICE_NAME.service"
    
    # Wait a moment for service to start
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE_NAME.service"; then
        log_success "Service ${SERVICE_NAME} is running"
    else
        log_error "Service ${SERVICE_NAME} failed to start"
        systemctl status "$SERVICE_NAME.service"
        exit 1
    fi
}

# Create log rotation
create_logrotate() {
    log_info "Setting up log rotation"
    
    cat > "/etc/logrotate.d/${SERVICE_NAME}" << EOF
${NTLM_HOME}/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        systemctl reload-or-restart ${SERVICE_NAME}.service > /dev/null 2>&1 || true
    endscript
}
EOF

    log_success "Created log rotation configuration"
}

# Create firewall rule (optional)
setup_firewall() {
    if command -v firewall-cmd > /dev/null 2>&1; then
        log_info "Setting up firewall rules"
        
        if firewall-cmd --state > /dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${NTLM_PORT}/tcp"
            firewall-cmd --reload
            log_success "Added firewall rule for port ${NTLM_PORT}"
        else
            log_warning "Firewalld is not running"
        fi
    else
        log_warning "Firewalld not found, skipping firewall setup"
    fi
}

# Display service information
show_info() {
    log_success "NTLMAPS installation completed!"
    echo
    echo "Configuration:"
    echo "  Service Name: ${SERVICE_NAME}"
    echo "  User/Group: ${NTLM_USER}/${NTLM_GROUP}"
    echo "  Install Path: ${NTLM_HOME}"
    echo "  Listen Port: ${NTLM_PORT}"
    echo "  Parent Proxy: ${PARENT_PROXY}:${PARENT_PROXY_PORT}"
    echo "  Domain: ${NT_DOMAIN}"
    echo
    echo "Service Management:"
    echo "  Status: systemctl status ${SERVICE_NAME}"
    echo "  Start:  systemctl start ${SERVICE_NAME}"
    echo "  Stop:   systemctl stop ${SERVICE_NAME}"
    echo "  Logs:   journalctl -u ${SERVICE_NAME} -f"
    echo
    echo "Configuration file: ${NTLM_HOME}/server.cfg"
    echo "Log files: ${NTLM_HOME}/logs/"
    echo
    echo "To use the proxy, set:"
    echo "  export http_proxy=http://localhost:${NTLM_PORT}/"
    echo "  export https_proxy=http://localhost:${NTLM_PORT}/"
}

# Usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Environment variables (with defaults):"
    echo "  NTLM_USER=${NTLM_USER}"
    echo "  NTLM_GROUP=${NTLM_GROUP}"
    echo "  NTLM_HOME=${NTLM_HOME}"
    echo "  NTLM_PORT=${NTLM_PORT}"
    echo "  PARENT_PROXY=${PARENT_PROXY}"
    echo "  PARENT_PROXY_PORT=${PARENT_PROXY_PORT}"
    echo "  NT_DOMAIN=${NT_DOMAIN}"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --uninstall    Uninstall the service"
    echo
    echo "Examples:"
    echo "  # Basic installation"
    echo "  sudo ./setup-ntlmaps.sh"
    echo
    echo "  # Custom configuration"
    echo "  sudo NTLM_PORT=8080 PARENT_PROXY=proxy.company.com ./setup-ntlmaps.sh"
}

# Uninstall function
uninstall() {
    log_info "Uninstalling NTLMAPS service"
    
    # Stop and disable service
    if systemctl is-active --quiet "$SERVICE_NAME.service"; then
        systemctl stop "$SERVICE_NAME.service"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME.service"; then
        systemctl disable "$SERVICE_NAME.service"
    fi
    
    # Remove service file
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    
    # Remove logrotate config
    rm -f "/etc/logrotate.d/${SERVICE_NAME}"
    
    # Remove firewall rule
    if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${NTLM_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --reload
    fi
    
    # Optionally remove user and directory
    read -p "Remove user ${NTLM_USER} and directory ${NTLM_HOME}? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl stop "$SERVICE_NAME.service" 2>/dev/null || true
        userdel "$NTLM_USER" 2>/dev/null || true
        groupdel "$NTLM_GROUP" 2>/dev/null || true
        rm -rf "$NTLM_HOME"
        log_success "Removed user and directory"
    fi
    
    log_success "NTLMAPS service uninstalled"
}

# Main installation function
main() {
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        --uninstall)
            check_root
            uninstall
            exit 0
            ;;
        "")
            # Normal installation
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    
    check_root
    
    log_info "Starting NTLMAPS installation"
    log_info "Using configuration:"
    log_info "  User: ${NTLM_USER}"
    log_info "  Home: ${NTLM_HOME}"
    log_info "  Port: ${NTLM_PORT}"
    log_info "  Proxy: ${PARENT_PROXY}:${PARENT_PROXY_PORT}"
    log_info "  Domain: ${NT_DOMAIN}"
    
    create_user
    create_directories
    install_files
    create_config
    create_service
    create_logrotate
    setup_firewall
    enable_service
    show_info
}

# Run main function with all arguments
main "$@"
