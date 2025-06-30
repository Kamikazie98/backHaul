package transport

import (
	"context"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/musix/backhaul/internal/utils"
	"github.com/musix/backhaul/internal/web"

	"github.com/sirupsen/logrus"
)

type TcpTransport struct {
	config          *TcpConfig
	parentctx       context.Context
	ctx             context.Context
	cancel          context.CancelFunc
	logger          *logrus.Logger
	controlChannel  net.Conn
	usageMonitor    *web.Usage
	restartMutex    sync.Mutex
	poolConnections int32
	loadConnections int32
	controlFlow     chan struct{}
	trafficBalancer *utils.TrafficBalancer
	trafficObfuscator *utils.TrafficObfuscator
}
type TcpConfig struct {
	RemoteAddr     string
	Token          string
	SnifferLog     string
	TunnelStatus   string
	KeepAlive      time.Duration
	RetryInterval  time.Duration
	DialTimeOut    time.Duration
	ConnPoolSize   int
	WebPort        int
	Nodelay        bool
	Sniffer        bool
	AggressivePool bool
}

func NewTCPClient(parentCtx context.Context, config *TcpConfig, logger *logrus.Logger) *TcpTransport {
	// Create a derived context from the parent context
	ctx, cancel := context.WithCancel(parentCtx)

	// Initialize the TcpTransport struct
	client := &TcpTransport{
		config:          config,
		parentctx:       parentCtx,
		ctx:             ctx,
		cancel:          cancel,
		logger:          logger,
		controlChannel:  nil,
		usageMonitor:    web.NewDataStore(fmt.Sprintf(":%v", config.WebPort), ctx, config.SnifferLog, config.Sniffer, &config.TunnelStatus, logger),
		poolConnections: 0,
		loadConnections: 0,
		controlFlow:     make(chan struct{}, 100),
		trafficBalancer: utils.NewTrafficBalancer(),
		trafficObfuscator: utils.NewTrafficObfuscator(),
	}

	return client
}

func (c *TcpTransport) Start() {
	if c.config.WebPort > 0 {
		go c.usageMonitor.Monitor()
	}

	c.config.TunnelStatus = "Disconnected (TCP)"

	go c.channelDialer()
}
func (c *TcpTransport) Restart() {
	if !c.restartMutex.TryLock() {
		c.logger.Warn("client is already restarting")
		return
	}
	defer c.restartMutex.Unlock()

	c.logger.Info("restarting client...")

	// for removing timeout logs
	level := c.logger.Level
	c.logger.SetLevel(logrus.FatalLevel)

	if c.cancel != nil {
		c.cancel()
	}

	// close control channel connection
	if c.controlChannel != nil {
		c.controlChannel.Close()
	}

	time.Sleep(2 * time.Second)

	ctx, cancel := context.WithCancel(c.parentctx)
	c.ctx = ctx
	c.cancel = cancel

	// Re-initialize variables
	c.controlChannel = nil
	c.usageMonitor = web.NewDataStore(fmt.Sprintf(":%v", c.config.WebPort), ctx, c.config.SnifferLog, c.config.Sniffer, &c.config.TunnelStatus, c.logger)
	c.config.TunnelStatus = ""
	c.poolConnections = 0
	c.loadConnections = 0
	c.controlFlow = make(chan struct{}, 100)

	// set the log level again
	c.logger.SetLevel(level)

	go c.Start()
}

func (c *TcpTransport) channelDialer() {
	c.logger.Info("attempting to establish a new control channel connection...")

	for {
		select {
		case <-c.ctx.Done():
			return
		default:
			//set default behaviour of control channel to nodelay, also using default buffer parameters
			tunnelTCPConn, err := TcpDialer(c.ctx, c.config.RemoteAddr, c.config.DialTimeOut, c.config.KeepAlive, true, 3, 0, 0)
			if err != nil {
				c.logger.Errorf("channel dialer: %v", err)
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Set a read deadline for the entire handshake process
			handshakeDeadline := time.Now().Add(5 * time.Second)
			if err := tunnelTCPConn.SetReadDeadline(handshakeDeadline); err != nil {
				c.logger.Errorf("failed to set handshake deadline: %v", err)
				tunnelTCPConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Sending security token with explicit signal type
			err = utils.SendBinaryTransportString(tunnelTCPConn, c.config.Token, utils.SG_Chan)
			if err != nil {
				c.logger.Errorf("failed to send security token: %v", err)
				tunnelTCPConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Receive response with signal validation
			message, signal, err := utils.ReceiveBinaryTransportString(tunnelTCPConn)
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					c.logger.Warn("timeout while waiting for control channel response")
				} else {
					c.logger.Errorf("failed to receive control channel response: %v", err)
				}
				tunnelTCPConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Validate both token and signal type
			if message != c.config.Token || signal != utils.SG_Chan {
				c.logger.Errorf("invalid handshake - Token match: %v, Signal match: %v", 
					message == c.config.Token, signal == utils.SG_Chan)
				tunnelTCPConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Clear the deadline after successful handshake
			tunnelTCPConn.SetReadDeadline(time.Time{})

			c.controlChannel = tunnelTCPConn
			c.logger.Info("control channel established successfully")

			c.config.TunnelStatus = "Connected (TCP)"
			go c.poolMaintainer()
			go c.channelHandler()

			return
		}
	}
}

func (c *TcpTransport) poolMaintainer() {
	for i := 0; i < c.config.ConnPoolSize; i++ { //initial pool filling
		go c.tunnelDialer()
	}

	// factors
	a := 4
	b := 5
	x := 3
	y := 4.0

	if c.config.AggressivePool {
		c.logger.Info("aggressive pool management enabled")
		a = 1
		b = 2
		x = 0
		y = 0.75
	}

	tickerPool := time.NewTicker(time.Second * 1)
	defer tickerPool.Stop()

	tickerLoad := time.NewTicker(time.Second * 10)
	defer tickerLoad.Stop()

	newPoolSize := c.config.ConnPoolSize // intial value
	var poolConnectionsSum int32 = 0

	for {
		select {
		case <-c.ctx.Done():
			return

		case <-tickerPool.C:
			// Accumulate pool connections over time (every second)
			atomic.AddInt32(&poolConnectionsSum, atomic.LoadInt32(&c.poolConnections))

		case <-tickerLoad.C:
			// Calculate the loadConnections over the last 10 seconds
			loadConnections := (int(atomic.LoadInt32(&c.loadConnections)) + 9) / 10 // +9 for ceil-like logic
			atomic.StoreInt32(&c.loadConnections, 0)                                // Reset

			// Calculate the average pool connections over the last 10 seconds
			poolConnectionsAvg := (int(atomic.LoadInt32(&poolConnectionsSum)) + 9) / 10 // +9 for ceil-like logic
			atomic.StoreInt32(&poolConnectionsSum, 0)                                   // Reset

			// Dynamically adjust the pool size based on current connections
			if (loadConnections + a) > poolConnectionsAvg*b {
				c.logger.Debugf("increasing pool size: %d -> %d, avg pool conn: %d, avg load conn: %d", newPoolSize, newPoolSize+1, poolConnectionsAvg, loadConnections)
				newPoolSize++

				// Add a new connection to the pool
				go c.tunnelDialer()
			} else if float64(loadConnections+x) < float64(poolConnectionsAvg)*y && newPoolSize > c.config.ConnPoolSize {
				c.logger.Debugf("decreasing pool size: %d -> %d, avg pool conn: %d, avg load conn: %d", newPoolSize, newPoolSize-1, poolConnectionsAvg, loadConnections)
				newPoolSize--

				// send a signal to controlFlow
				c.controlFlow <- struct{}{}
			}
		}
	}

}

func (c *TcpTransport) channelHandler() {
	defer func() {
		if c.controlChannel != nil {
			c.controlChannel.Close()
		}
		c.Restart()
	}()

	for {
		select {
		case <-c.ctx.Done():
			return
		default:
			message, signal, err := utils.ReceiveBinaryTransportString(c.controlChannel)
			if err != nil {
				c.logger.Errorf("control channel error: %v", err)
				return
			}

			// Validate the received signal
			if !validateSignal(signal) {
				c.logger.Errorf("received invalid signal: %d", signal)
				continue
			}

			switch signal {
			case utils.SG_HB:
				// Handle heartbeat
				err = utils.SendBinaryTransportString(c.controlChannel, message, utils.SG_HB)
				if err != nil {
					c.logger.Errorf("failed to send heartbeat response: %v", err)
					return
				}

			case utils.SG_Chan:
				// Handle channel request
				c.controlFlow <- struct{}{}

			case utils.SG_Closed:
				// Handle closed signal
				c.logger.Info("received close signal from server")
				return

			case utils.SG_Ping:
				// Handle ping
				err = utils.SendBinaryTransportString(c.controlChannel, message, utils.SG_Ping)
				if err != nil {
					c.logger.Errorf("failed to send ping response: %v", err)
					return
				}

			default:
				c.logger.Warnf("unhandled signal type: %d", signal)
			}
		}
	}
}

// Dialing to the tunnel server, chained functions, without retry
func (c *TcpTransport) tunnelDialer() {
	c.logger.Debugf("initiating new connection to tunnel server at %s", c.config.RemoteAddr)

	// Dial to the tunnel server
	// Based on calculations 1MB of buffer on 80ms RTT will have about 100Mbit Bandwidth per connection,
	// this is enough to get 800Mbit/s on speedtest and also not having too much buffer to bufferbloat
	tcpConn, err := TcpDialer(c.ctx, c.config.RemoteAddr, c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, 3, 1024*1024, 1024*1024)
	if err != nil {
		c.logger.Error("tunnel server dialer: ", err)

		return
	}

	// Increment active connections counter
	atomic.AddInt32(&c.poolConnections, 1)

	// Attempt to receive the remote address from the tunnel server
	remoteAddr, transport, err := utils.ReceiveBinaryTransportString(tcpConn)

	// Decrement active connections after successful or failed connection
	atomic.AddInt32(&c.poolConnections, -1)

	if err != nil {
		c.logger.Debugf("failed to receive port from tunnel connection %s: %v", tcpConn.RemoteAddr().String(), err)
		tcpConn.Close()
		return
	}

	// Extract the port from the received address
	port, resolvedAddr, err := ResolveRemoteAddr(remoteAddr)
	if err != nil {
		c.logger.Infof("failed to resolve remote port: %v", err)
		tcpConn.Close() // Close the connection on error
		return
	}

	switch transport {
	case utils.SG_TCP:
		// Dial local server using the received address
		c.localDialer(tcpConn, resolvedAddr, port)

	case utils.SG_UDP:
		UDPDialer(tcpConn, resolvedAddr, c.logger, c.usageMonitor, port, c.config.Sniffer)

	default:
		c.logger.Error("undefined transport. close the connection.")
		tcpConn.Close()
	}
}

func (c *TcpTransport) localDialer(tcpConn net.Conn, remoteAddr string, port int) {
	// Set Default S,R buffer to 32kb also enabling nodelay on send side of local network ( receive side should be handled by xray)
	localConnection, err := TcpDialer(c.ctx, remoteAddr, c.config.DialTimeOut, c.config.KeepAlive, true, 1, 32*1024, 32*1024)
	if err != nil {
		c.logger.Errorf("local dialer: %v", err)
		tcpConn.Close()
		return
	}

	c.logger.Debugf("connected to local address %s successfully", remoteAddr)

	// Create traffic handlers
	balancer := utils.NewTrafficBalancer()
	obfuscator := utils.NewTrafficObfuscator()

	// Create obfuscated writers and readers
	obfLocalWriter := obfuscator.NewObfuscatedWriter(localConnection)
	obfRemoteWriter := obfuscator.NewObfuscatedWriter(tcpConn)
	obfLocalReader := obfuscator.NewObfuscatedReader(localConnection)
	obfRemoteReader := obfuscator.NewObfuscatedReader(tcpConn)

	var wg sync.WaitGroup
	wg.Add(2)

	// Handle upload (local to remote) with balancing and obfuscation
	go func() {
		defer wg.Done()
		balancer.BalancedCopy(obfRemoteWriter, obfLocalReader)
	}()

	// Handle download (remote to local) with balancing and obfuscation
	go func() {
		defer wg.Done()
		balancer.BalancedCopy(obfLocalWriter, obfRemoteReader)
	}()

	// Wait for both directions to complete
	wg.Wait()
}
