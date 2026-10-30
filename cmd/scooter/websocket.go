package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
)

// A minimal RFC 6455 client: binary frames, ping/pong and close.

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xa
)

// handshakeError is a non-101 answer to the upgrade.
type handshakeError struct {
	resp *http.Response
}

func (e *handshakeError) Error() string {
	return fmt.Sprintf("websocket upgrade: %s", e.resp.Status)
}

type wsConn struct {
	conn net.Conn
	br   *bufio.Reader
	wmu  sync.Mutex
}

// dialWebSocket upgrades an http(s) URL to a WebSocket, sending headers.
func dialWebSocket(ctx context.Context, rawURL string, headers map[string]string) (*wsConn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	host := u.Host
	if u.Port() == "" {
		host = net.JoinHostPort(u.Hostname(), map[string]string{"https": "443", "wss": "443"}[u.Scheme])
		if u.Scheme == "http" || u.Scheme == "ws" {
			host = net.JoinHostPort(u.Hostname(), "80")
		}
	}
	var conn net.Conn
	switch u.Scheme {
	case "https", "wss":
		d := &tls.Dialer{Config: &tls.Config{ServerName: u.Hostname()}}
		conn, err = d.DialContext(ctx, "tcp", host)
	case "http", "ws":
		var d net.Dialer
		conn, err = d.DialContext(ctx, "tcp", host)
	default:
		return nil, fmt.Errorf("websocket: unsupported scheme %q", u.Scheme)
	}
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()

	nonce := make([]byte, 16)
	_, _ = rand.Read(nonce)
	key := base64.StdEncoding.EncodeToString(nonce)
	req := &http.Request{Method: http.MethodGet, URL: u, Host: u.Host, Header: http.Header{}}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Sec-WebSocket-Key", key)
	req.Header.Set("Sec-WebSocket-Version", "13")
	if err := req.Write(conn); err != nil {
		_ = conn.Close()
		return nil, err
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		_ = conn.Close()
		return nil, &handshakeError{resp: resp}
	}
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	if resp.Header.Get("Sec-WebSocket-Accept") != base64.StdEncoding.EncodeToString(sum[:]) {
		_ = conn.Close()
		return nil, errors.New("websocket upgrade: bad Sec-WebSocket-Accept")
	}
	return &wsConn{conn: conn, br: br}, nil
}

// writeFrame sends one masked frame, as clients must.
func (c *wsConn) writeFrame(op byte, payload []byte) error {
	hdr := make([]byte, 2, 14)
	hdr[0] = 0x80 | op
	switch n := len(payload); {
	case n < 126:
		hdr[1] = 0x80 | byte(n)
	case n <= 0xffff:
		hdr[1] = 0x80 | 126
		hdr = binary.BigEndian.AppendUint16(hdr, uint16(n))
	default:
		hdr[1] = 0x80 | 127
		hdr = binary.BigEndian.AppendUint64(hdr, uint64(n))
	}
	var mask [4]byte
	_, _ = rand.Read(mask[:])
	hdr = append(hdr, mask[:]...)
	buf := make([]byte, len(hdr)+len(payload))
	copy(buf, hdr)
	for i, b := range payload {
		buf[len(hdr)+i] = b ^ mask[i%4]
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err := c.conn.Write(buf)
	return err
}

// readFrame returns the next frame's opcode and payload.
func (c *wsConn) readFrame() (byte, []byte, error) {
	var h [2]byte
	if _, err := io.ReadFull(c.br, h[:]); err != nil {
		return 0, nil, err
	}
	op := h[0] & 0x0f
	n := uint64(h[1] & 0x7f)
	switch n {
	case 126:
		var b [2]byte
		if _, err := io.ReadFull(c.br, b[:]); err != nil {
			return 0, nil, err
		}
		n = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err := io.ReadFull(c.br, b[:]); err != nil {
			return 0, nil, err
		}
		n = binary.BigEndian.Uint64(b[:])
	}
	if n > 64<<20 {
		return 0, nil, fmt.Errorf("websocket: %d-byte frame is too large", n)
	}
	var mask [4]byte
	masked := h[1]&0x80 != 0
	if masked {
		if _, err := io.ReadFull(c.br, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(c.br, payload); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return op, payload, nil
}

// copyTo writes data frames to w until the peer closes, answering pings.
func (c *wsConn) copyTo(w io.Writer) error {
	for {
		op, payload, err := c.readFrame()
		if err != nil {
			return err
		}
		switch op {
		case opBinary, opText, opContinuation:
			if _, err := w.Write(payload); err != nil {
				return err
			}
		case opPing:
			if err := c.writeFrame(opPong, payload); err != nil {
				return err
			}
		case opClose:
			_ = c.writeFrame(opClose, nil)
			return nil
		}
	}
}

// copyFrom sends r as binary frames, then a close frame at EOF.
func (c *wsConn) copyFrom(r io.Reader) error {
	buf := make([]byte, 32<<10)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if werr := c.writeFrame(opBinary, buf[:n]); werr != nil {
				return werr
			}
		}
		if err == io.EOF {
			return c.writeFrame(opClose, nil)
		}
		if err != nil {
			return err
		}
	}
}

func (c *wsConn) Close() error { return c.conn.Close() }
