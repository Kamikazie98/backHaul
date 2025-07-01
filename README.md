# Backhaul customized for xray-core

A high-performance tunnel service with multiple transport protocols support.

## Features

- Multiple transport protocols support:
  - TCP
  - TCP Multiplexing
  - WebSocket
  - WebSocket Secure (WSS)
  - WebSocket Multiplexing
  - WebSocket Secure Multiplexing
- UDP over TCP support
- Connection pooling with aggressive mode option
- Traffic monitoring and statistics
- Web interface for monitoring
- Systemd service integration
- Easy configuration management

## Quick Installation

### Linux/Unix Systems

1. Download and run the installation script:
```bash
curl -O https://raw.githubusercontent.com/Kamikazie98/backHaul/main/backhaul.sh
chmod +x backhaul.sh
sudo ./backhaul.sh install
```

2. Create a new configuration:
```bash
sudo ./backhaul.sh create
```

3. Start the service:
```bash
sudo ./backhaul.sh manage start
```

## Configuration

### Server Configuration

The server configuration can be created using the interactive setup:
```bash
sudo ./backhaul.sh create
# Choose 's' when prompted for server/client type
```

Key configuration parameters:
- `bind_addr`: Address to bind (e.g., "0.0.0.0:3080")
- `transport`: Protocol (tcp, tcpmux, ws, wss, wsmux, wssmux)
- `accept_udp`: Enable UDP over TCP
- `token`: Authentication token
- `ports`: Port mappings for forwarding

Example port mappings:
- Single port: "443"
- Port range: "443-600"
- Port with target: "443=1.1.1.1:5201"
- Full mapping: "127.0.0.2:443=1.1.1.1:5201"

### Client Configuration

Create a client configuration:
```bash
sudo ./backhaul.sh create
# Choose 'c' when prompted for server/client type
```

Key configuration parameters:
- `remote_addr`: Server address
- `edge_ip`: CDN edge IP (optional)
- `transport`: Protocol (must match server)
- `token`: Authentication token
- `connection_pool`: Number of connections to maintain
- `aggressive_pool`: Enable aggressive connection pooling

## Service Management

Start the service:
```bash
sudo ./backhaul.sh manage start
```

Other management commands:
```bash
sudo ./backhaul.sh manage stop      # Stop the service
sudo ./backhaul.sh manage restart   # Restart the service
sudo ./backhaul.sh manage status    # Check service status
sudo ./backhaul.sh manage logs      # View service logs
```

## Advanced Configuration

### Performance Tuning

- `mux_version`: Multiplexing version (1 or 2)
- `mux_framesize`: Frame size for multiplexing (default: 32768)
- `mux_receivebuffer`: Receive buffer size (default: 4194304)
- `mux_streambuffer`: Stream buffer size (default: 65536)
- `nodelay`: Enable TCP_NODELAY
- `keepalive_period`: Keepalive interval in seconds

### Monitoring

- `sniffer`: Enable traffic monitoring
- `web_port`: Web interface port (default: 2060)
- `sniffer_log`: Path to traffic log file

### TLS Configuration (for WSS)

- `tls_cert`: Path to TLS certificate
- `tls_key`: Path to TLS private key

## Uninstallation

To remove Backhaul:
```bash
sudo ./backhaul.sh uninstall
```

## File Locations

- Configurations: `/etc/backhaul/`
- Binary: `/usr/local/backhaul/`
- Service: `/etc/systemd/system/backhaul.service`

## Troubleshooting

1. Check service status:
```bash
sudo ./backhaul.sh manage status
```

2. View logs:
```bash
sudo ./backhaul.sh manage logs
```

3. Common issues:
   - Port already in use: Check for conflicting services
   - Connection refused: Verify firewall rules
   - Authentication failed: Check token configuration
   - TLS errors: Verify certificate paths and permissions

## License

This project is licensed under the AGPL-3.0 license. See the LICENSE file for details.

## Stargazers over time
[![Stargazers over time](https://starchart.cc/Musixal/Backhaul.svg?variant=light)](https://starchart.cc/Musixal/Backhaul)

