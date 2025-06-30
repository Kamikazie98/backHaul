//go:build windows

package transport

import (
	"fmt"
	"net"
	"syscall"
	"time"
)

// setSocketOptions sets the required socket options for optimal performance on Windows
func setSocketOptions(conn net.Conn, nodelay bool, keepalive time.Duration, writeBuffer, readBuffer int) error {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return fmt.Errorf("not a TCP connection")
	}

	// Get the underlying file descriptor
	rawConn, err := tcpConn.SyscallConn()
	if err != nil {
		return fmt.Errorf("failed to get syscall conn: %v", err)
	}

	var setOptErr error
	err = rawConn.Control(func(fd uintptr) {
		handle := syscall.Handle(fd)
		if nodelay {
			setOptErr = syscall.SetsockoptInt(handle, syscall.IPPROTO_TCP, syscall.TCP_NODELAY, 1)
		}
		if keepalive > 0 {
			setOptErr = syscall.SetsockoptInt(handle, syscall.SOL_SOCKET, syscall.SO_KEEPALIVE, 1)
		}
		if writeBuffer > 0 {
			setOptErr = syscall.SetsockoptInt(handle, syscall.SOL_SOCKET, syscall.SO_SNDBUF, writeBuffer)
		}
		if readBuffer > 0 {
			setOptErr = syscall.SetsockoptInt(handle, syscall.SOL_SOCKET, syscall.SO_RCVBUF, readBuffer)
		}
	})

	if err != nil {
		return fmt.Errorf("failed to set socket options: %v", err)
	}
	if setOptErr != nil {
		return fmt.Errorf("failed to set specific socket option: %v", setOptErr)
	}

	return nil
} 