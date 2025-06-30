```bash
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
GITHUB_VERSION="v1.1.0"

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
        echo -e "${RED}Unsupported package manager. Please install curl, wget, and unzip manually.${NC}"
        exit 1
    fi
}

# Function to download specific release
download_latest() {
    echo -e "${BLUE}Downloading Backhaul version ${GITHUB_VERSION}...${NC}"
    
    # Determine system architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    
    # Download specific release
    URL="https://github.com/${GITHUB_REPO}/releases/download/${GITHUB_VERSION}/backhaul_linux_${ARCH}.tar.gz"
    wget -O /tmp/backhaul.tar.gz "$URL" || {
        echo -e "${RED}Failed to download from $URL. Check if the release exists or try building from source.${NC}"
        exit 1
    }
    
    # Extract and verify
    tar xzf /tmp/backhaul.tar.gz -C "$INSTALL_DIR" || {
        echo -e "${RED}Failed to extract tarball${NC}"
        exit 1
    }
    
    # Check if the binary exists (allow for different naming)
    if [ ! -f "$INSTALL_DIR/backhaul" ]; then
        BINARY=$(find "$INSTALL_DIR" -type f -executable | head -n 1)
        if [ -n "$BINARY" ]; then
            mv "$BINARY" "$INSTALL_DIR/backhaul"
        else
            echo -e "${RED}No executable found in tarball${NC}"
            exit 1
        fi
    fi
    
    chmod +x "$INSTALL_DIR/backhaul"
    rm /tmp/backhaul.tar.gz
    
    # Verify binary
    if ! "$INSTALL_DIR/backhaul" --version >/dev/null 2>&1; then
        echo -e "${RED}Downloaded binary is not executable. Try building from source.${NC}"
        exit 1
    fi
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
mux_recievebuffer = $MUX_RECEIVEBUFFER
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
mux_recievebuffer = $MUX_RECEIVEBUFFER
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
```

### Key Updates
1. **Repository and Version**:
   - Changed `GITHUB_REPO` to `Kamikazie98/backHaul` and `GITHUB_VERSION` to `v1.1.0` to match your specified repository and version.
   - The `download_latest` function now targets the specific `v1.1.0` release instead of fetching the latest version.

2. **Enhanced Error Handling**:
   - The `download_latest` function checks if the download and extraction succeed.
   - It searches for an executable in the extracted tarball and renames it to `backhaul` if necessary.
   - It verifies the binary is executable by running `--version`.

3. **User-Input Parameters**:
   - The `create_tunnel` function prompts for all server parameters (e.g., `bind_addr`, `transport`, `ports`, etc.) and client parameters (e.g., `remote_addr`, `edge_ip`, `connection_pool`, etc.) as specified in the TOML configurations.
   - Port mappings for the server are entered dynamically (press Enter twice to finish).
   - Configurations are saved to a user-named TOML file and copied to `/etc/backhaul/config.toml` for the systemd service.

4. **Tunnel Management**:
   - `manage start|stop|restart|status|logs` uses systemd to control the service, check status, and view logs.

5. **Uninstallation**:
   - Removes the installation directory, config directory, and systemd service for a complete cleanup.

### Usage Example
```bash
# Install Backhaul
sudo ./backhaul.sh install

# Create a new tunnel configuration
sudo ./backhaul.sh create
# Example prompts for server:
# - Bind address: 0.0.0.0:3080
# - Transport protocol: tcp
# - Port mappings: 443, 80, 443-600:5201
# Example prompts for client:
# - Remote server address: server_ip:3080
# - Transport protocol: wssmux
# - Connection pool size: 8

# Start the tunnel
sudo ./backhaul.sh manage start

# Check tunnel status
sudo ./backhaul.sh manage status

# View tunnel logs
sudo ./backhaul.sh manage logs

# Stop the tunnel
sudo ./backhaul.sh manage stop

# Uninstall Backhaul
sudo ./backhaul.sh uninstall
```

### Notes
- **Repository Verification**: I couldn’t access `https://github.com/Kamikazie98/backHaul/releases/tag/v1.1.0` to confirm the availability of binaries. If no binaries are provided, you’ll need to build from source (as shown above). Check the release page for available assets.
- **Binary Naming**: The script assumes a binary named `backhaul` or renames the first executable found in the tarball. If the naming convention is different, you may need to adjust the `download_latest` function.
- **Config Validation**: The script doesn’t validate user inputs (e.g., valid ports or transport protocols). You can add validation if needed (e.g., check if `TRANSPORT` is one of `tcp`, `tcpmux`, `ws`, `wss`, `wsmux`, `wssmux`).
- **TLS Files**: For `wss` or `wssmux` transports, ensure the `tls_cert` and `tls_key` files exist at the specified paths (e.g., `/root/server.crt`, `/root/server.key`). You can generate them with OpenSSL:
  ```bash
  openssl req -x509 -newkey rsa:4096 -keyout /root/server.key -out /root/server.crt -days 365 -nodes
  ```

### If the Issue Persists
If the `install` command or manual download fails:
1. Verify the repository and release exist: `https://github.com/Kamikazie98/backHaul/releases/tag/v1.1.0`.
2. Check the GitHub release assets for the correct binary name and update the `download_latest` function if needed.
3. Build from source as a fallback (requires Go):
   ```bash
   sudo apt-get install -y golang git
   git clone -b v1.1.0 https://github.com/Kamikazie98/backHaul.git
   cd backHaul
   go build -o backhaul
   sudo mv backhaul /usr/local/backhaul/
   sudo chmod +x /usr/local/backhaul/backhaul
   ```
4. Check the systemd logs for additional errors:
   ```bash
   journalctl -u backhaul -b
   ```

If you need specific validations, additional features, or help with building from source, let me know![](https://github.com/Musixal/Backhaul)