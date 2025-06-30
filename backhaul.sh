#!/bin/bash

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
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi
}

# Function to install dependencies
install_dependencies() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y curl wget unzip
    elif command -v yum &> /dev/null; then
        yum install -y curl wget unzip
    else
        echo -e "${RED}Unsupported package manager. Please install curl, wget_ABORTIVE and unzip manually.${NC}"
        exit 1
    fi
}

# Function to download latest release
download_latest() {
    echo -e "${BLUE}Downloading latest version...${NC}"
    
    # Determine system architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    
    # Download latest release
    LATEST_VERSION=$(curl -s https://api.github.com/repos/${GITHUB_REPO}/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}Failed to fetch latest version from GitHub${NC}"
        exit 1
    fi
    wget -O /tmp/backhaul.tar.gz "https://github.com/${GITHUB_REPO}/releases/download/${LATEST_VERSION}/backhaul_linux_${ARCH}.tar.gz"
    
    tar xzf /tmp/backhaul.tar.gz -C "$INSTALL_DIR"
    rm /tmp/backhaul.tar.gz
    
    chmod +x "$INSTALL_DIR/backhaul"
}

# Function to create systemd service
create_service() {
    check_root
    echo -e "${BLUE}Creating systemd service...${NC}"
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Backhaul Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/backhaul -c $CONFIG_DIR/config.toml
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
    echo -e "${BLUE}Creating new tunnel configuration...${NC}"
    
    read -p "Is this a server or client? [s/c]: " TYPE
    if [[ "$TYPE" != "s" && "$TYPE" != "c" ]]; then
        echo -e "${RED}Invalid type. Please choose 's' for server or 'c' for client${NC}"
        return 1
    fi
    
    read -p "Enter configuration name (e.g., mytunnel): " CONFIG_NAME
    if [ -z "$CONFIG_NAME" ]; then
        echo -e "${RED}Configuration name cannot be empty${NC}"
        return 1
    fi
    
    CONFIG_FILE="$CONFIG_DIR/${CONFIG_NAME}.toml"
    
    if [ "$TYPE" = "s" ]; then
        # Prompt for server configuration parameters
        echo -e "${BLUE}Enter server configuration parameters:${NC}"
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
        echo -e "${BLUE}Enter port mappings (one per line, press Enter twice to finish):${NC}"
        echo -e "${YELLOW}Format examples: '443', '443-600', '443-600:5201', '443=1.1.1.1:5201', '127.0.0.2:443=1.1.1.1:5201'${NC}"
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
        echo -e "${GREEN}Created server configuration: $CONFIG_FILE${NC}"
        
    else
        # Prompt for client configuration parameters
        echo -e "${BLUE}Enter client configuration parameters:${NC}"
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
        echo -e "${GREEN}Created client configuration: $CONFIG_FILE${NC}"
    fi
    
    # Copy to default config for service
    cp "$CONFIG_FILE" "$CONFIG_DIR/config.toml"
    echo -e "${YELLOW}Configuration saved. You can edit $CONFIG_FILE manually if needed.${NC}"
    echo -e "${YELLOW}Use './backhaul.sh manage start' to start the tunnel.${NC}"
}

# Function to install Backhaul
install() {
    check_root
    install_dependencies
    download_latest
    create_service
    
    echo -e "${GREEN}Installation completed!${NC}"
    echo -e "Run './backhaul.sh create' to create a new tunnel configuration."
}

# Function to manage tunnels
manage_tunnel() {
    check_root
    
    case "$1" in
        start)
            systemctl start ${SERVICE_NAME}
            echo -e "${GREEN}Started Backhaul service${NC}"
            ;;
        stop)
            systemctl stop ${SERVICE_NAME}
            echo -e "${YELLOW}Stopped Backhaul service${NC}"
            ;;
        restart)
            systemctl restart ${SERVICE_NAME}
            echo -e "${GREEN}Restarted Backhaul service${NC}"
            ;;
        status)
            systemctl status ${SERVICE_NAME}
            ;;
        logs)
            journalctl -u ${SERVICE_NAME} -f
            ;;
        *)
            echo -e "${RED}Usage: $0 manage [start|stop|restart|status|logs]${NC}"
            exit 1
            ;;
    esac
}

# Function to uninstall Backhaul
uninstall() {
    check_root
    
    echo -e "${YELLOW}Uninstalling Backhaul...${NC}"
    
    systemctl stop ${SERVICE_NAME} 2>/dev/null
    systemctl disable ${SERVICE_NAME} 2>/dev/null
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    
    rm -rf "$INSTALL_DIR"
    rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}Uninstallation completed${NC}"
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
        echo -e "${BLUE}Usage: $0 {install|create|manage|uninstall}${NC}"
        echo -e "\nCommands:"
        echo -e "  ${YELLOW}install${NC}    Install Backhaul"
        echo -e "  ${YELLOW}create${NC}     Create a new tunnel configuration (server or client)"
        echo -e "  ${YELLOW}manage${NC}     Manage tunnel service (start|stop|restart|status|logs)"
        echo -e "  ${YELLOW}uninstall${NC}  Remove Backhaul"
        exit 1
        ;;
esac