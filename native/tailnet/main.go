// Package main provides the app-owned, userspace Tailscale node. No OS VPN or
// device route is installed. The library is loaded only on an opted-in phone.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"tailscale.com/envknob"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

type mobileNode struct {
	server *tsnet.Server
	ctx    context.Context
	cancel context.CancelFunc
}

var nodeMu sync.Mutex
var current *mobileNode
var handoffCancels sync.Map // ticket -> context.CancelFunc, until the stream closes

type command struct {
	Op, Dir, Key, Host, Ticket string
	Port                       int
}
type result struct {
	State    string `json:"state,omitempty"`
	LoginURL string `json:"loginURL,omitempty"`
	Port     int    `json:"port,omitempty"`
	Ticket   string `json:"ticket,omitempty"`
	Error    string `json:"error,omitempty"`
}

//export conduit_tailnet_call
func conduit_tailnet_call(raw *C.char) *C.char {
	var c command
	var r result
	if err := json.Unmarshal([]byte(C.GoString(raw)), &c); err != nil {
		r.Error = "invalid request"
	} else if value, err := run(c); err != nil {
		// Native errors can include server addresses and sign-in URLs.
		r.Error = "Tailscale connection unavailable"
	} else {
		r = value
	}
	b, _ := json.Marshal(r)
	return C.CString(string(b))
}

//export conduit_tailnet_free
func conduit_tailnet_free(p *C.char) { C.free(unsafe.Pointer(p)) }

func run(c command) (result, error) {
	if c.Op == "cancel" {
		if cancel, ok := handoffCancels.Load(c.Ticket); ok {
			cancel.(context.CancelFunc)()
		}
		return result{}, nil
	}
	nodeMu.Lock()
	if c.Op == "start" && current == nil {
		key, err := base64.StdEncoding.DecodeString(c.Key)
		if err != nil {
			nodeMu.Unlock()
			return result{}, err
		}
		store, err := openStore(c.Dir, key)
		if err != nil {
			nodeMu.Unlock()
			return result{}, err
		}
		logtail.Disable()
		envknob.SetNoLogsNoSupport()
		server := &tsnet.Server{Hostname: "conduit-mobile", Dir: c.Dir, Store: store, Logf: logger.Discard, UserLogf: logger.Discard}
		if err := server.Start(); err != nil {
			nodeMu.Unlock()
			return result{}, err
		}
		ctx, cancel := context.WithCancel(context.Background())
		current = &mobileNode{server: server, ctx: ctx, cancel: cancel}
	}
	n := current
	if c.Op == "stop" || c.Op == "logout" {
		defer nodeMu.Unlock()
		if n == nil {
			return result{}, nil
		}
		// Detach the node before logout. Close it even when the phone cannot
		// reach the coordinator to revoke its session.
		current = nil
		defer n.server.Close()
		defer n.cancel()
		if c.Op == "logout" {
			ctx, cancel := context.WithTimeout(n.ctx, 10*time.Second)
			defer cancel()
			lc, err := n.server.LocalClient()
			if err != nil {
				return result{}, err
			}
			if err = lc.Logout(ctx); err != nil {
				return result{}, err
			}
		}
		return result{}, nil
	}
	nodeMu.Unlock()
	if n == nil {
		return result{State: "Stopped"}, errors.New("node stopped")
	}
	lc, err := n.server.LocalClient()
	if err != nil {
		return result{}, err
	}
	ctx, cancel := context.WithTimeout(n.ctx, 15*time.Second)
	defer cancel()
	switch c.Op {
	case "start", "status":
		st, err := lc.StatusWithoutPeers(ctx)
		if err != nil {
			return result{}, err
		}
		return result{State: st.BackendState, LoginURL: st.AuthURL}, nil
	case "dial":
		if c.Port < 1 || c.Port > 65535 {
			return result{}, errors.New("invalid port")
		}
		if _, err := n.server.Up(ctx); err != nil {
			return result{}, err
		}
		st, err := lc.Status(ctx)
		if err != nil {
			return result{}, err
		}
		target, ok := peerAddress(st, c.Host)
		if !ok {
			return result{}, errors.New("not a tailnet peer")
		}
		remote, err := n.server.Dial(ctx, "tcp", net.JoinHostPort(target.String(), strconv.Itoa(c.Port)))
		if err != nil {
			return result{}, err
		}
		return handoff(n.ctx, remote)
	}
	return result{}, errors.New("unknown operation")
}

// Resolve using the authenticated network map. UserDial can otherwise open
// public sockets, and a phone DNS lookup could disclose a private hostname.
func peerAddress(st *ipnstate.Status, host string) (netip.Addr, bool) {
	name := strings.ToLower(strings.TrimSuffix(host, "."))
	ip, _ := netip.ParseAddr(name)
	for _, peer := range st.Peer {
		fqdn := strings.ToLower(strings.TrimSuffix(peer.DNSName, "."))
		short, _, _ := strings.Cut(fqdn, ".")
		for _, addr := range peer.TailscaleIPs {
			if addr == ip || (name != "" && (name == fqdn || name == short)) {
				return addr, true
			}
		}
	}
	return netip.Addr{}, false
}

// Dart's HttpClient needs a real Socket for its existing TLS and WebSocket
// code. Hand it one already-dialled stream. The rendezvous accepts a random
// one-use ticket and never accepts a destination from the loopback listener.
func handoff(ctx context.Context, remote net.Conn) (result, error) {
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		remote.Close()
		return result{}, err
	}
	var secret [32]byte
	rand.Read(secret[:])
	ticket := hex.EncodeToString(secret[:])
	ctx, cancel := context.WithCancel(ctx)
	handoffCancels.Store(ticket, cancel)
	go func() {
		defer handoffCancels.Delete(ticket)
		defer cancel()
		defer remote.Close()
		defer listener.Close()
		stop := context.AfterFunc(ctx, func() { listener.Close(); remote.Close() })
		defer stop()
		deadline := time.Now().Add(10 * time.Second)
		listener.SetDeadline(deadline)
		for {
			s, err := listener.AcceptTCP()
			if err != nil {
				return
			}
			stopSocket := context.AfterFunc(ctx, func() { s.Close() })
			s.SetReadDeadline(deadline)
			var offered [64]byte
			_, err = io.ReadFull(s, offered[:])
			if err != nil || subtle.ConstantTimeCompare(offered[:], []byte(ticket)) != 1 {
				stopSocket()
				s.Close()
				continue
			}
			listener.Close()
			s.SetReadDeadline(time.Time{})
			defer s.Close()
			// Shutdown must release both pumps even when the peer is silent.
			defer stopSocket()
			done := make(chan struct{})
			go func() {
				io.Copy(remote, s)
				if h, ok := remote.(interface{ CloseWrite() error }); ok {
					h.CloseWrite()
				}
				close(done)
			}()
			io.Copy(s, remote)
			s.CloseWrite()
			<-done
			return
		}
	}()
	return result{Port: listener.Addr().(*net.TCPAddr).Port, Ticket: ticket}, nil
}
func main() {}
