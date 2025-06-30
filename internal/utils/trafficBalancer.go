package utils

import (
	"io"
	"sync"
	"sync/atomic"
	"time"
)

// TrafficBalancer ensures symmetric traffic flow
type TrafficBalancer struct {
	uploadBytes   int64
	downloadBytes int64
	mutex         sync.Mutex
	padding       []byte
}

// NewTrafficBalancer creates a new traffic balancer instance
func NewTrafficBalancer() *TrafficBalancer {
	return &TrafficBalancer{
		padding: make([]byte, 1024), // 1KB padding buffer
	}
}

// BalancedCopy performs a balanced copy between src and dst
func (tb *TrafficBalancer) BalancedCopy(dst io.Writer, src io.Reader) (written int64, err error) {
	buf := make([]byte, 32*1024)
	
	for {
		// Read from source
		nr, er := src.Read(buf)
		if nr > 0 {
			atomic.AddInt64(&tb.downloadBytes, int64(nr))
			
			// Write actual data
			nw, ew := dst.Write(buf[0:nr])
			if nw < 0 || nr < nw {
				nw = 0
				if ew == nil {
					ew = io.ErrShortWrite
				}
			}
			written += int64(nw)
			atomic.AddInt64(&tb.uploadBytes, int64(nw))
			
			// Balance traffic if needed
			tb.balanceTraffic(dst)
			
			if ew != nil {
				err = ew
				break
			}
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

// balanceTraffic adds padding if needed to maintain 1:1 ratio
func (tb *TrafficBalancer) balanceTraffic(dst io.Writer) {
	tb.mutex.Lock()
	defer tb.mutex.Unlock()
	
	upload := atomic.LoadInt64(&tb.uploadBytes)
	download := atomic.LoadInt64(&tb.downloadBytes)
	
	// If upload is less than download, add padding
	if upload < download {
		diff := download - upload
		if diff > int64(len(tb.padding)) {
			diff = int64(len(tb.padding))
		}
		
		// Add random delay to make traffic pattern less predictable
		time.Sleep(time.Duration(50+time.Now().UnixNano()%100) * time.Millisecond)
		
		// Write padding with random data
		dst.Write(tb.padding[:diff])
		atomic.AddInt64(&tb.uploadBytes, diff)
	}
}

// GetStats returns current traffic statistics
func (tb *TrafficBalancer) GetStats() (upload, download int64) {
	return atomic.LoadInt64(&tb.uploadBytes), atomic.LoadInt64(&tb.downloadBytes)
} 