#!/usr/bin/env bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/usr/local/backhaul"
CONFIG_DIR="/etc/backhaul"
SERVICE_NAME="backhaul"
GITHUB_REPO="Kamikazie98/backHaul"

# Function to check if script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "${RED}Please run as root${NC}\n"
        exit 1
    fi
}

# Function to install dependencies
install_dependencies() {
    printf "${BLUE}Installing dependencies...${NC}\n"
    if command -v apt-get > /dev/null 2>&1; then
        apt-get update
        apt-get install -y curl wget unzip
    elif command -v yum > /dev/null 2>&1; then
        yum install -y curl wget unzip
    else
        printf "${RED}Unsupported package manager. Please install curl, wget and unzip manually.${NC}\n"
        exit 1
    fi
}

# Function to download latest release
download_latest() {
    printf "${BLUE}Downloading latest version...${NC}\n"
    
    # Determine system architecture
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) printf "${RED}Unsupported architecture: ${ARCH}${NC}\n"; exit 1 ;;
    esac
    
    # Create installation directory
    mkdir -p "${INSTALL_DIR}"
    
    # Download latest release
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "${LATEST_VERSION}" ]; then
        printf "${RED}Failed to fetch latest version from GitHub${NC}\n"
        exit 1
    fi
    
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_VERSION}/backhaul_linux_${ARCH}.tar.gz"
    if ! wget -O "/tmp/backhaul.tar.gz" "${DOWNLOAD_URL}"; then
        printf "${RED}Failed to download release${NC}\n"
        exit 1
    fi
    
    if ! tar xzf "/tmp/backhaul.tar.gz" -C "${INSTALL_DIR}"; then
        printf "${RED}Failed to extract archive${NC}\n"
        rm -f "/tmp/backhaul.tar.gz"
        exit 1
    fi
    
    # Find and rename the binary
    BINARY_PATH=$(find "${INSTALL_DIR}" -name "backhaul_linux_${ARCH}*" -type f)
    if [ -n "${BINARY_PATH}" ]; then
        mv "${BINARY_PATH}" "${INSTALL_DIR}/backhaul"
        chmod +x "${INSTALL_DIR}/backhaul"
    else
        printf "${RED}Could not find binary file in extracted archive${NC}\n"
        exit 1
    fi
    
    rm -f "/tmp/backhaul.tar.gz"
}

# Function to create systemd service
create_service() {
    check_root
    printf "${BLUE}Creating systemd service...${NC}\n"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Backhaul Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/backhaul -c ${CONFIG_DIR}/config.toml
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# Function to create a new tunnel configuration
create_tunnel() {
    check_root
    printf "${BLUE}Creating new tunnel configuration...${NC}\n"
    
    printf "Is this a server or client? [s/c]: "
    read -r TYPE
    if [ "${TYPE}" != "s" ] && [ "${TYPE}" != "c" ]; then
        printf "${RED}Invalid type. Please choose 's' for server or 'c' for client${NC}\n"
        return 1
    fi
    
    printf "Enter configuration name (e.g., mytunnel): "
    read -r CONFIG_NAME
    if [ -z "${CONFIG_NAME}" ]; then
        printf "${RED}Configuration name cannot be empty${NC}\n"
        return 1
    fi
    
    CONFIG_FILE="${CONFIG_DIR}/${CONFIG_NAME}.toml"
    mkdir -p "${CONFIG_DIR}"
    
    if [ "${TYPE}" = "s" ]; then
        # Prompt for server configuration parameters
        printf "${BLUE}Enter server configuration parameters:${NC}\n"
        read -p "Bind address (e.g., 0.0.0.0:3080): " BIND_ADDR
        BIND_ADDR=${BIND_ADDR:-"0.0.0.0:3080"}
        read -p "Transport protocol (tcp, tcpmux, ws, wss, wsmux, wssmux) [default: tcp]: " TRANSPORT
        TRANSPORT=${TRANSPORT:-"tcp"}
        read -p "Accept UDP over TCP? (true/false) [default: false]: " ACCEPT_UDP
        ACCEPT_UDP=${ACCEPT_UDP:-"false"}
        read -p "Token for authentication [default: your_token]: " TOKEN
        TOKEN=${TOKEN:-"your_token"}
        read -p "Keepalive period in seconds [default: 75]: " KEEPALIVE
        KEEPALIVE=${KEEPALIVE:-75}
        read -p "Enable TCP_NODELAY? (true/false) [default: false]: " NODELAY
        NODELAY=${NODELAY:-"false"}
        read -p "Channel size [default: 2048]: " CHANNEL_SIZE
        CHANNEL_SIZE=${CHANNEL_SIZE:-2048}
        read -p "Heartbeat interval in seconds [default: 40]: " HEARTBEAT
        HEARTBEAT=${HEARTBEAT:-40}
        read -p "Mux concurrency [default: 8]: " MUX_CON
        MUX_CON=${MUX_CON:-8}
        read -p "Mux version (1 or 2) [default: 1]: " MUX_VERSION
        MUX_VERSION=${MUX_VERSION:-1}
        read -p "Mux frame size [default: 32768]: " MUX_FRAMESIZE
        MUX_FRAMESIZE=${MUX_FRAMESIZE:-32768}
        read -p "Mux receive buffer size [default: 4194304]: " MUX_RECEIVEBUFFER
        MUX_RECEIVEBUFFER=${MUX_RECEIVEBUFFER:-4194304}
        read -p "Mux stream buffer size [default: 65536]: " MUX_STREAMBUFFER
        MUX_STREAMBUFFER=${MUX_STREAMBUFFER:-65536}
        read -p "Enable sniffer? (true/false) [default: false]: " SNIFFER
        SNIFFER=${SNIFFER:-"false"}
        read -p "Web port (0 to disable) [default: 2060]: " WEB_PORT
        WEB_PORT=${WEB_PORT:-2060}
        read -p "Sniffer log file [default: /root/log.json]: " SNIFFER_LOG
        SNIFFER_LOG=${SNIFFER_LOG:-"/root/log.json"}
        read -p "TLS certificate file (for wss/wssmux) [default: /root/server.crt]: " TLS_CERT
        TLS_CERT=${TLS_CERT:-"/root/server.crt"}
        read -p "TLS key file (for wss/wssmux) [default: /root/server.key]: " TLS_KEY
        TLS_KEY=${TLS_KEY:-"/root/server.key"}
        read -p "Log level (panic, fatal, error, warn, info, debug, trace) [default: info]: " LOG_LEVEL
        LOG_LEVEL=${LOG_LEVEL:-"info"}
        
        # Prompt for port mappings
        printf "${BLUE}Enter port mappings (one per line, press Enter twice to finish):${NC}\n"
        printf "${YELLOW}Format examples: '443', '443-600', '443-600:5201', '443=1.1.1.1:5201', '127.0.0.2:443=1.1.1.1:5201'${NC}"
        PORTS=""
        while IFS= read -r PORT; do
            [[ -z "$PORT" ]] && break
            PORTS="$PORTS\n    \"$PORT\","
        done
        
        # Write server config
        cat > "$CONFIG_FILE" << EOF
[server]
bind_addr = "$BIND_ADDR"
transport = "$TRANSPORT"
accept_udp = $ACCEPT_UDP
token = "$TOKEN"
keepalive_period = $KEEPALIVE
nodelay = $NODELAY
channel_size = $CHANNEL_SIZE
heartbeat = $HEARTBEAT
mux_con = $MUX_CON
mux_version = $MUX_VERSION
mux_framesize = $MUX_FRAMESIZE
mux_receivebuffer = $MUX_RECEIVEBUFFER
mux_streambuffer = $MUX_STREAMBUFFER
sniffer = $SNIFFER
web_port = $WEB_PORT
sniffer_log = "$SNIFFER_LOG"
tls_cert = "$TLS_CERT"
tls_key = "$TLS_KEY"
log_level = "$LOG_LEVEL"

ports = [
$PORTS
]
EOF
        printf "${GREEN}Created server configuration: $CONFIG_FILE${NC}\n"
        
    else
        # Prompt for client configuration parameters
        printf "${BLUE}Enter client configuration parameters:${NC}\n"
        read -p "Remote server address (e.g., your_server_ip:3080): " REMOTE_ADDR
        REMOTE_ADDR=${REMOTE_ADDR:-"your_server_ip:3080"}
        read -p "Edge IP for CDN (e.g., 188.114.96.0, optional): " EDGE_IP
        EDGE_IP=${EDGE_IP:-""}
        read -p "Transport protocol (tcp, tcpmux, ws, wss, wsmux, wssmux) [default: tcp]: " TRANSPORT
        TRANSPORT=${TRANSPORT:-"tcp"}
        read -p "Token for authentication [default: your_token]: " TOKEN
        TOKEN=${TOKEN:-"your_token"}
        read -p "Connection pool size [default: 8]: " CONNECTION_POOL
        CONNECTION_POOL=${CONNECTION_POOL:-8}
        read -p "Enable aggressive pool? (true/false) [default: false]: " AGGRESSIVE_POOL
        AGGRESSIVE_POOL=${AGGRESSIVE_POOL:-"false"}
        read -p "Keepalive period in seconds [default: 75]: " KEEPALIVE
        KEEPALIVE=${KEEPALIVE:-75}
        read -p "Enable TCP_NODELAY? (true/false) [default: false]: " NODELAY
        NODELAY=${NODELAY:-"false"}
        read -p "Retry interval in seconds [default: 3]: " RETRY_INTERVAL
        RETRY_INTERVAL=${RETRY_INTERVAL:-3}
        read -p "Dial timeout in seconds [default: 10]: " DIAL_TIMEOUT
        DIAL_TIMEOUT=${DIAL_TIMEOUT:-10}
        read -p "Mux version (1 or 2) [default: 1]: " MUX_VERSION
        MUX_VERSION=${MUX_VERSION:-1}
        read -p "Mux frame size [default: 32768]: " MUX_FRAMESIZE
        MUX_FRAMESIZE=${MUX_FRAMESIZE:-32768}
        read -p "Mux receive buffer size [default: 4194304]: " MUX_RECEIVEBUFFER
        MUX_RECEIVEBUFFER=${MUX_RECEIVEBUFFER:-4194304}
        read -p "Mux stream buffer size [default: 65536]: " MUX_STREAMBUFFER
        MUX_STREAMBUFFER=${MUX_STREAMBUFFER:-65536}
        read -p "Enable sniffer? (true/false) [default: false]: " SNIFFER
        SNIFFER=${SNIFFER:-"false"}
        read -p "Web port (0 to disable) [default: 2060]: " WEB_PORT
        WEB_PORT=${WEB_PORT:-2060}
        read -p "Sniffer log file [default: /root/log.json]: " SNIFFER_LOG
        SNIFFER_LOG=${SNIFFER_LOG:-"/root/log.json"}
        read -p "Log level (panic, fatal, error, warn, info, debug, trace) [default: info]: " LOG_LEVEL
        LOG_LEVEL=${LOG_LEVEL:-"info"}
        
        # Write client config
        cat > "$CONFIG_FILE" << EOF
[client]
remote_addr = "$REMOTE_ADDR"
$( [ -n "$EDGE_IP" ] && echo "edge_ip = \"$EDGE_IP\"" )
transport = "$TRANSPORT"
token = "$TOKEN"
connection_pool = $CONNECTION_POOL
aggressive_pool = $AGGRESSIVE_POOL
keepalive_period = $KEEPALIVE
nodelay = $NODELAY
retry_interval = $RETRY_INTERVAL
dial_timeout = $DIAL_TIMEOUT
mux_version = $MUX_VERSION
mux_framesize = $MUX_FRAMESIZE
mux_receivebuffer = $MUX_RECEIVEBUFFER
mux_streambuffer = $MUX_STREAMBUFFER
sniffer = $SNIFFER
web_port = $WEB_PORT
sniffer_log = "$SNIFFER_LOG"
log_level = "$LOG_LEVEL"
EOF
        printf "${GREEN}Created client configuration: $CONFIG_FILE${NC}\n"
    fi
    
    # Copy to default config for service
    cp "$CONFIG_FILE" "$CONFIG_DIR/config.toml"
    printf "${YELLOW}Configuration saved. You can edit $CONFIG_FILE manually if needed.${NC}\n"
    printf "${YELLOW}Use './backhaul.sh manage start' to start the tunnel.${NC}\n"
}

# Function to install Backhaul
install() {
    check_root
    install_dependencies
    download_latest
    create_service
    
    printf "${GREEN}Installation completed!${NC}\n"
    printf "Run './backhaul.sh create' to create a new tunnel configuration.\n"
}

# Function to manage tunnels
manage_tunnel() {
    check_root
    
    case "$1" in
        start)
            systemctl start "${SERVICE_NAME}"
            printf "${GREEN}Started Backhaul service${NC}\n"
            ;;
        stop)
            systemctl stop "${SERVICE_NAME}"
            printf "${YELLOW}Stopped Backhaul service${NC}\n"
            ;;
        restart)
            systemctl restart "${SERVICE_NAME}"
            printf "${GREEN}Restarted Backhaul service${NC}\n"
            ;;
        status)
            systemctl status "${SERVICE_NAME}"
            ;;
        logs)
            journalctl -u "${SERVICE_NAME}" -f
            ;;
        *)
            printf "${RED}Usage: %s manage [start|stop|restart|status|logs]${NC}\n" "$0"
            exit 1
            ;;
    esac
}

# Function to uninstall Backhaul
uninstall() {
    check_root
    
    printf "${YELLOW}Uninstalling Backhaul...${NC}\n"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null
    systemctl disable "${SERVICE_NAME}" 2>/dev/null
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    
    rm -rf "${INSTALL_DIR}"
    rm -rf "${CONFIG_DIR}"
    printf "${GREEN}Uninstallation completed${NC}\n"
}

# Main script logic
case "$1" in
    install)
        install
        ;;
    create)
        create_tunnel
        ;;
    manage)
        manage_tunnel "$2"
        ;;
    uninstall)
        uninstall
        ;;
    *)
        printf "${BLUE}Usage: %s {install|create|manage|uninstall}${NC}\n" "$0"
        printf "\nCommands:\n"
        printf "  ${YELLOW}install${NC}    Install Backhaul\n"
        printf "  ${YELLOW}create${NC}     Create a new tunnel configuration (server or client)\n"
        printf "  ${YELLOW}manage${NC}     Manage tunnel service (start|stop|restart|status|logs)\n"
        printf "  ${YELLOW}uninstall${NC}  Remove Backhaul\n"
        exit 1
        ;;
esac