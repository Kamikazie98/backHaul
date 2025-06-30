package utils

import (
	cryptorand "crypto/rand"
	"io"
	"math/rand"
	"time"
)

// TrafficObfuscator adds randomization to traffic patterns
type TrafficObfuscator struct {
	jitterMin time.Duration
	jitterMax time.Duration
	paddingMin int
	paddingMax int
	rng        *rand.Rand
}

// NewTrafficObfuscator creates a new traffic obfuscator
func NewTrafficObfuscator() *TrafficObfuscator {
	// Create a new random number generator with a secure seed
	source := rand.NewSource(time.Now().UnixNano())
	
	return &TrafficObfuscator{
		jitterMin: 10 * time.Millisecond,
		jitterMax: 50 * time.Millisecond,
		paddingMin: 64,    // Minimum padding bytes
		paddingMax: 1024,  // Maximum padding bytes
		rng:        rand.New(source),
	}
}

// ObfuscatedWriter wraps an io.Writer with traffic obfuscation
type ObfuscatedWriter struct {
	w io.Writer
	obfuscator *TrafficObfuscator
	padding []byte
}

// NewObfuscatedWriter creates a new obfuscated writer
func (to *TrafficObfuscator) NewObfuscatedWriter(w io.Writer) *ObfuscatedWriter {
	return &ObfuscatedWriter{
		w: w,
		obfuscator: to,
		padding: make([]byte, to.paddingMax),
	}
}

// Write implements io.Writer with traffic obfuscation
func (ow *ObfuscatedWriter) Write(p []byte) (n int, err error) {
	// Add random jitter
	jitter := ow.obfuscator.jitterMin + 
		time.Duration(ow.obfuscator.rng.Int63n(int64(ow.obfuscator.jitterMax-ow.obfuscator.jitterMin)))
	time.Sleep(jitter)

	// Write actual data
	n, err = ow.w.Write(p)
	if err != nil {
		return n, err
	}

	// Add random padding
	paddingSize := ow.obfuscator.paddingMin + 
		int(ow.obfuscator.rng.Int31n(int32(ow.obfuscator.paddingMax-ow.obfuscator.paddingMin)))
	
	// Fill padding with random data
	if _, err := cryptorand.Read(ow.padding[:paddingSize]); err != nil {
		return n, err
	}
	
	// Write padding
	_, err = ow.w.Write(ow.padding[:paddingSize])
	
	return n, err
}

// ObfuscatedReader wraps an io.Reader with traffic obfuscation
type ObfuscatedReader struct {
	r io.Reader
	obfuscator *TrafficObfuscator
}

// NewObfuscatedReader creates a new obfuscated reader
func (to *TrafficObfuscator) NewObfuscatedReader(r io.Reader) *ObfuscatedReader {
	return &ObfuscatedReader{
		r: r,
		obfuscator: to,
	}
}

// Read implements io.Reader with traffic obfuscation
func (or *ObfuscatedReader) Read(p []byte) (n int, err error) {
	// Add random jitter
	jitter := or.obfuscator.jitterMin + 
		time.Duration(or.obfuscator.rng.Int63n(int64(or.obfuscator.jitterMax-or.obfuscator.jitterMin)))
	time.Sleep(jitter)

	return or.r.Read(p)
} 