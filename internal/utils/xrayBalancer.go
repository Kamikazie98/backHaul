package utils

import (
	"crypto/rand"
	"io"
	"sync"
	"sync/atomic"
	"time"
)

// XrayBalancer is a specialized traffic balancer optimized for xray-core protocols
type XrayBalancer struct {
	uploadBytes   int64
	downloadBytes int64
	mutex         sync.Mutex
	padding       []byte
	// Xray protocol specific settings
	minPadding    int
	maxPadding    int
	paddingPeriod time.Duration
	jitterRange   time.Duration
	// Synchronization channels
	uploadChan    chan int64
	downloadChan  chan int64
	syncInterval  time.Duration
}

// NewXrayBalancer creates a new traffic balancer optimized for xray-core
func NewXrayBalancer() *XrayBalancer {
	xb := &XrayBalancer{
		padding:       make([]byte, 8192), // 8KB max padding
		minPadding:    64,                 // Minimum padding size
		maxPadding:    8192,               // Maximum padding size
		paddingPeriod: 20 * time.Millisecond,
		jitterRange:   10 * time.Millisecond,
		uploadChan:    make(chan int64, 1000),
		downloadChan:  make(chan int64, 1000),
		syncInterval:  10 * time.Millisecond,
	}
	
	// Start the synchronization goroutine
	go xb.syncTraffic()
	
	return xb
}

// syncTraffic continuously monitors and balances traffic
func (xb *XrayBalancer) syncTraffic() {
	ticker := time.NewTicker(xb.syncInterval)
	defer ticker.Stop()

	for range ticker.C {
		upload := atomic.LoadInt64(&xb.uploadBytes)
		download := atomic.LoadInt64(&xb.downloadBytes)

		// Calculate the difference
		diff := download - upload

		// If there's an imbalance, add padding immediately
		if diff > 0 {
			paddingSize := diff
			if paddingSize > int64(xb.maxPadding) {
				paddingSize = int64(xb.maxPadding)
			}
			
			// Generate and send padding
			paddingData := make([]byte, paddingSize)
			rand.Read(paddingData)
			select {
			case xb.uploadChan <- paddingSize:
				atomic.AddInt64(&xb.uploadBytes, paddingSize)
			default:
				// Channel is full, skip this padding
			}
		}
	}
}

// BalancedCopy performs a balanced copy optimized for xray-core protocols
func (xb *XrayBalancer) BalancedCopy(dst io.Writer, src io.Reader) (written int64, err error) {
	buf := make([]byte, 32*1024) // 32KB buffer for better real-time response
	
	// Start a goroutine to handle padding writes
	go func() {
		for paddingSize := range xb.uploadChan {
			paddingData := make([]byte, paddingSize)
			rand.Read(paddingData)
			dst.Write(paddingData)
		}
	}()
	
	for {
		// Read from source with timeout to ensure regular checks
		nr, er := src.Read(buf)
		if nr > 0 {
			// Update download counter
			atomic.AddInt64(&xb.downloadBytes, int64(nr))
			select {
			case xb.downloadChan <- int64(nr):
			default:
				// Channel is full, skip notification
			}
			
			// Write actual data
			nw, ew := dst.Write(buf[0:nr])
			if nw > 0 {
				written += int64(nw)
				atomic.AddInt64(&xb.uploadBytes, int64(nw))
			}
			if ew != nil {
				err = ew
				break
			}
			if nr != nw {
				err = io.ErrShortWrite
				break
			}

			// Add immediate padding if needed
			xb.balanceTrafficImmediate(dst)
		}
		if er != nil {
			if er != io.EOF {
				err = er
			}
			break
		}
	}
	return written, err
}

// balanceTrafficImmediate adds padding immediately if needed
func (xb *XrayBalancer) balanceTrafficImmediate(dst io.Writer) {
	upload := atomic.LoadInt64(&xb.uploadBytes)
	download := atomic.LoadInt64(&xb.downloadBytes)
	
	// If upload is less than download, add padding immediately
	if upload < download {
		diff := download - upload
		if diff > int64(xb.maxPadding) {
			diff = int64(xb.maxPadding)
		}
		
		// Generate and write padding immediately
		paddingData := make([]byte, diff)
		rand.Read(paddingData)
		dst.Write(paddingData)
		atomic.AddInt64(&xb.uploadBytes, diff)
	}
}

// GetStats returns current traffic statistics
func (xb *XrayBalancer) GetStats() (upload, download int64) {
	return atomic.LoadInt64(&xb.uploadBytes), atomic.LoadInt64(&xb.downloadBytes)
}

// ResetStats resets traffic statistics
func (xb *XrayBalancer) ResetStats() {
	atomic.StoreInt64(&xb.uploadBytes, 0)
	atomic.StoreInt64(&xb.downloadBytes, 0)
}

// Close closes the balancer and its channels
func (xb *XrayBalancer) Close() {
	close(xb.uploadChan)
	close(xb.downloadChan)
} 