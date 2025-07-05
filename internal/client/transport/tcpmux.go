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
	"github.com/xtaci/smux"
)

type TcpMuxTransport struct {
	config          *TcpMuxConfig
	smuxConfig      *smux.Config
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
	xrayBalancer    *utils.XrayBalancer
	trafficObfuscator *utils.TrafficObfuscator
}

type TcpMuxConfig struct {
	RemoteAddr       string
	Token            string
	SnifferLog       string
	TunnelStatus     string
	Nodelay          bool
	Sniffer          bool
	KeepAlive        time.Duration
	RetryInterval    time.Duration
	DialTimeOut      time.Duration
	MuxVersion       int
	MaxFrameSize     int
	MaxReceiveBuffer int
	MaxStreamBuffer  int
	ConnPoolSize     int
	WebPort          int
	AggressivePool   bool
}

func NewMuxClient(parentCtx context.Context, config *TcpMuxConfig, logger *logrus.Logger) *TcpMuxTransport {
	// Create a derived context from the parent context
	ctx, cancel := context.WithCancel(parentCtx)

	// Initialize the TcpTransport struct
	client := &TcpMuxTransport{
		smuxConfig: &smux.Config{
			Version:           config.MuxVersion,
			KeepAliveInterval: 20 * time.Second,
			KeepAliveTimeout:  40 * time.Second,
			MaxFrameSize:      config.MaxFrameSize,
			MaxReceiveBuffer:  config.MaxReceiveBuffer,
			MaxStreamBuffer:   config.MaxStreamBuffer,
		},
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
		xrayBalancer:    utils.NewXrayBalancer(),
		trafficObfuscator: utils.NewTrafficObfuscator(),
	}

	return client
}

func (c *TcpMuxTransport) Start() {
	if c.config.WebPort > 0 {
		go c.usageMonitor.Monitor()
	}

	c.config.TunnelStatus = "Disconnected (TCPMUX)"

	go c.channelDialer()
}

func (c *TcpMuxTransport) Restart() {
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

func (c *TcpMuxTransport) channelDialer() {
	c.logger.Info("attempting to establish a new tcpmux control channel connection...")

	for {
		select {
		case <-c.ctx.Done():
			return
		default:
			tunnelConn, err := TcpDialer(c.ctx, c.config.RemoteAddr, c.config.DialTimeOut, c.config.KeepAlive, true, 3, 0, 0)
			if err != nil {
				c.logger.Errorf("channel dialer: %v", err)
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Set a read deadline for the entire handshake process
			handshakeDeadline := time.Now().Add(5 * time.Second)
			if err := tunnelConn.SetReadDeadline(handshakeDeadline); err != nil {
				c.logger.Errorf("failed to set handshake deadline: %v", err)
				tunnelConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Sending security token with explicit signal type
			err = utils.SendBinaryTransportString(tunnelConn, c.config.Token, utils.SG_Chan)
			if err != nil {
				c.logger.Errorf("failed to send security token: %v", err)
				tunnelConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Receive response with signal validation
			message, signal, err := utils.ReceiveBinaryTransportString(tunnelConn)
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					c.logger.Warn("timeout while waiting for control channel response")
				} else {
					c.logger.Errorf("failed to receive control channel response: %v", err)
				}
				tunnelConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Validate both token and signal type
			if message != c.config.Token || signal != utils.SG_Chan {
				c.logger.Errorf("invalid handshake - Token match: %v, Signal match: %v", 
					message == c.config.Token, signal == utils.SG_Chan)
				tunnelConn.Close()
				time.Sleep(c.config.RetryInterval)
				continue
			}

			// Clear the deadline after successful handshake
			tunnelConn.SetReadDeadline(time.Time{})

			c.controlChannel = tunnelConn
			c.logger.Info("control channel established successfully")

			c.config.TunnelStatus = "Connected (TCPMux)"
			go c.poolMaintainer()
			go c.channelHandler()

			return
		}
	}
}

func (c *TcpMuxTransport) poolMaintainer() {
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

func (c *TcpMuxTransport) channelHandler() {
	defer func() {
		if c.controlChannel != nil {
			c.controlChannel.Close()
		}
		c.Restart()
	}()

	for {
		select {
		case <-c.ctx.Done():
			// Send close signal before exiting
			_ = utils.SendBinaryTransportString(c.controlChannel, "", utils.SG_Closed)
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
				c.logger.Debug("heartbeat signal received and responded successfully")

			case utils.SG_Chan:
				// Handle channel request
				atomic.AddInt32(&c.loadConnections, 1)
				select {
				case <-c.controlFlow: // Do nothing
				default:
					c.logger.Debug("channel signal received, initiating tunnel dialer")
					go c.tunnelDialer()
				}

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

func (c *TcpMuxTransport) tunnelDialer() {
	c.logger.Debugf("initiating new tunnel connection to address %s", c.config.RemoteAddr)

	// Dial to the tunnel server
	// in case of mux we set 2M which is good for 200mbit per connection
	tunnelConn, err := TcpDialer(c.ctx, c.config.RemoteAddr, c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, 3, 2*1024*1024, 2*1024*1024)
	if err != nil {
		c.logger.Errorf("tunnel server dialer: %v", err)

		return
	}

	// Increment active connections counter
	atomic.AddInt32(&c.poolConnections, 1)
	// defer atomic.AddInt32(&c.poolConnections, -1) // This will be handled by handleSession defer

	c.handleSession(tunnelConn)
}

func (c *TcpMuxTransport) handleSession(tunnelConn net.Conn) {
	defer atomic.AddInt32(&c.poolConnections, -1) // Decrement when session ends
	defer tunnelConn.Close()                      // Ensure underlying connection is closed

	// SMUX client session (since this is client code, it should be smux.Client)
	session, err := smux.Client(tunnelConn, c.smuxConfig)
	if err != nil {
		c.logger.Errorf("failed to create mux client session: %v", err)
		return
	}
	defer session.Close() // Ensure session is closed when handleSession exits

	for {
		select {
		case <-c.ctx.Done():
			c.logger.Debug("context done, closing session")
			return
		default:
			// Client opens a stream to the server when server signals (via control channel)
			// or when server initiates a stream for relay.
			// In this model, the server opens a stream (session.AcceptStream on server),
			// and the client accepts it here.
			stream, err := session.AcceptStream()
			if err != nil {
				if !session.IsClosed() {
					c.logger.Errorf("failed to accept stream: %v, session active: %v", err, !session.IsClosed())
				} else {
					c.logger.Debug("session closed, cannot accept further streams")
				}
				return // Session is likely problematic or closed, exit handler.
			}
			c.logger.Debugf("accepted new stream %d from server", stream.ID())

			// Perform the new relay handshake over the accepted stream
			// 1. Receive SG_RELAY_READY
			// Set a deadline for receiving the signal
			if err := stream.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
				c.logger.Errorf("stream %d: failed to set read deadline for SG_RELAY_READY: %v", stream.ID(), err)
				stream.Close()
				continue
			}

			initialSignal, err := utils.ReceiveBinaryByte(stream) // stream implements net.Conn
			if err != nil {
				c.logger.Errorf("stream %d: failed to receive initial signal: %v", stream.ID(), err)
				stream.Close()
				continue
			}

			if err := stream.SetReadDeadline(time.Time{}); err != nil { // Clear deadline
				c.logger.Warnf("stream %d: failed to clear read deadline: %v", stream.ID(), err)
			}

			if initialSignal != utils.SG_RELAY_READY {
				c.logger.Errorf("stream %d: received unexpected initial signal %X instead of SG_RELAY_READY", stream.ID(), initialSignal)
				stream.Close()
				continue
			}
			c.logger.Debugf("stream %d: received SG_RELAY_READY", stream.ID())

			// 2. Receive the destination address string
			destinationAddr, err := utils.ReceiveBinaryString(stream)
			if err != nil {
				c.logger.Errorf("stream %d: failed to receive destination address: %v", stream.ID(), err)
				stream.Close()
				continue
			}
			c.logger.Debugf("stream %d: received destination address '%s'", stream.ID(), destinationAddr)

			go c.localDialer(stream, destinationAddr, true) // true for isRelaySetup
		}
	}
}

func (c *TcpMuxTransport) localDialer(stream *smux.Stream, destinationAddrRaw string, isRelaySetup bool) {
	// Resolve destination address
	// ResolveRemoteAddr is in client/transport/shared.go, ensure it's suitable or adapt
	port, resolvedAddr, err := ResolveRemoteAddr(destinationAddrRaw)
	if err != nil {
		c.logger.Errorf("stream %d: failed to resolve remote port from destination '%s': %v", stream.ID(), destinationAddrRaw, err)
		stream.Close()
		return
	}

	finalDialHost := resolvedAddr
	if finalDialHost == "" {
		finalDialHost = "127.0.0.1" // Default to localhost
	}
	fullDialAddr := fmt.Sprintf("%s:%d", finalDialHost, port)

	// Create traffic handlers optimized for xray-core protocols
	// These should be instance members if they have state that needs to be shared,
	// or ensure they are lightweight to create per stream.
	// For now, assuming xrayBalancer and trafficObfuscator are fine as instance members.
	// If they maintain per-connection state, new instances might be needed.
	// The current TCP implementation creates them per connection (balancer, obfuscator).
	// Let's stick to that pattern for consistency if they are stateful.
	balancer := utils.NewXrayBalancer() // Create new balancer for each stream
	obfuscator := utils.NewTrafficObfuscator() // Create new obfuscator for each stream

	// Establish local connection
	localConn, err := net.DialTimeout("tcp", fullDialAddr, c.config.DialTimeOut)
	if err != nil {
		c.logger.Errorf("stream %d: failed to connect to local address %s: %v", stream.ID(), fullDialAddr, err)
		stream.Close()
		return
	}
	// Defer closing localConn and stream until the copy operations are done.
	// balancer.Close() is not needed as it's stateless or managed internally by copy.

	c.logger.Debugf("stream %d: connected to local service %s successfully", stream.ID(), fullDialAddr)

	if isRelaySetup {
		// 3. Send SG_RELAY_ACK back to server over the stream
		if err := utils.SendBinaryByte(stream, utils.SG_RELAY_ACK); err != nil {
			c.logger.Errorf("stream %d: failed to send SG_RELAY_ACK to server: %v", stream.ID(), err)
			localConn.Close()
			stream.Close()
			return
		}
		c.logger.Debugf("stream %d: sent SG_RELAY_ACK to server", stream.ID())
	}

	// Set TCP options for optimal performance with xray-core (on localConn)
	if tcpConn, ok := localConn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(true)                     // Enable TCP_NODELAY
		tcpConn.SetKeepAlive(true)                   // Enable keep-alive
		tcpConn.SetKeepAlivePeriod(30 * time.Second) // Set keep-alive period
		tcpConn.SetWriteBuffer(32 * 1024)            // 32KB write buffer for better real-time response
		tcpConn.SetReadBuffer(32 * 1024)             // 32KB read buffer for better real-time response
	}

	// Create obfuscated streams optimized for xray-core protocols
	obfLocalWriter := obfuscator.NewObfuscatedWriter(localConn)
	obfStreamWriter := obfuscator.NewObfuscatedWriter(stream)
	obfLocalReader := obfuscator.NewObfuscatedReader(localConn)
	obfStreamReader := obfuscator.NewObfuscatedReader(stream)

	var wg sync.WaitGroup
	wg.Add(2)

	// Create synchronization channels
	doneChan := make(chan struct{})
	defer close(doneChan)

	// Handle upload (local to remote) with synchronized balancing
	go func() {
		defer wg.Done()
		defer stream.Close()
		defer localConn.Close()
		balancer.BalancedCopy(obfStreamWriter, obfLocalReader)
	}()

	// Handle download (remote to local) with synchronized balancing
	go func() {
		defer wg.Done()
		defer stream.Close()
		defer localConn.Close()
		balancer.BalancedCopy(obfLocalWriter, obfStreamReader)
	}()

	// Monitor traffic balance in real-time
	go func() {
		ticker := time.NewTicker(10 * time.Millisecond)
		defer ticker.Stop()

		for {
			select {
			case <-doneChan:
				return
			case <-ticker.C:
				upload, download := balancer.GetStats()
				if upload != download {
					c.logger.Debugf("Traffic imbalance detected - Upload: %d, Download: %d, Difference: %d bytes", 
						upload, download, download-upload)
				}
			}
		}
	}()

	// Wait for both directions to complete
	wg.Wait()

	// Log final traffic statistics
	upload, download := balancer.GetStats()
	c.logger.Debugf("Connection closed. Final stats - Upload: %d bytes, Download: %d bytes, Ratio: %.2f", 
		upload, download, float64(upload)/float64(download))
}
