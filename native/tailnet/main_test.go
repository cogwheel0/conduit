package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"io"
	"net"
	"net/netip"
	"os"
	"strconv"
	"testing"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
	"tailscale.com/tsnet"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func TestMain(m *testing.M) {
	logtail.Disable()
	envknob.SetNoLogsNoSupport()
	os.Exit(m.Run())
}

func TestPersistedIdentity(t *testing.T) {
	dir := t.TempDir()
	key := make([]byte, 32)
	rand.Read(key)
	first, err := openStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	value := []byte("synthetic identity")
	if err = first.WriteState("demo", value); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(first.path)
	if err != nil || bytes.Contains(raw, value) {
		t.Fatal("invalid encrypted state")
	}
	reopened, err := openStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	read, err := reopened.ReadState("demo")
	if err != nil || !bytes.Equal(read, value) {
		t.Fatal("identity did not survive restart")
	}
	if _, err = openStore(dir, make([]byte, 32)); err == nil {
		t.Fatal("accepted a different key")
	}
	if err = reopened.WriteState("demo", nil); err != nil {
		t.Fatal(err)
	}
	reopened, err = openStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reopened.ReadState("demo"); err != ipn.ErrStateNotExist {
		t.Fatal("deleted key returned")
	}
}

func TestOnlyNamedPeersAreRoutable(t *testing.T) {
	ip := netip.MustParseAddr("100.64.0.17")
	status := &ipnstate.Status{Peer: map[key.NodePublic]*ipnstate.PeerStatus{{}: {DNSName: "orchard.preview.ts.net.", TailscaleIPs: []netip.Addr{ip}}}}
	for _, host := range []string{"orchard", "Orchard.preview.ts.net.", ip.String()} {
		if got, ok := peerAddress(status, host); !ok || got != ip {
			t.Fatalf("missing route for %s", host)
		}
	}
	for _, host := range []string{"127.0.0.1", "orchard.other.example", "100.64.0.18", "example.org", ""} {
		if _, ok := peerAddress(status, host); ok {
			t.Fatalf("accepted %q", host)
		}
	}
}

func TestExternalSyntheticPeer(t *testing.T) {
	addr := os.Getenv("CONDUIT_TAILNET_TEST_CONTROL")
	if addr == "" {
		t.Skip("requires the isolated test coordinator")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	client := &tsnet.Server{Dir: t.TempDir(), Hostname: "mobile-reader", ControlURL: addr, Logf: logger.Discard, UserLogf: logger.Discard}
	defer client.Close()
	if _, err := client.Up(ctx); err != nil {
		t.Fatal(err)
	}
	exercisePeer(t, ctx, client, cancel)
}

func exercisePeer(t *testing.T, ctx context.Context, client *tsnet.Server, cancel context.CancelFunc) {
	t.Helper()
	current = &mobileNode{server: client, ctx: ctx, cancel: cancel}
	t.Cleanup(func() { current = nil })
	var route result
	var err error
	for {
		route, err = run(command{Op: "dial", Host: "orchard", Port: 8080})
		if err == nil {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatalf("no synthetic route: %v", err)
		case <-time.After(100 * time.Millisecond):
		}
	}
	localhost := net.JoinHostPort("127.0.0.1", strconv.Itoa(route.Port))
	wrong, err := net.Dial("tcp", localhost)
	if err != nil {
		t.Fatal(err)
	}
	wrong.Write(bytes.Repeat([]byte{'x'}, 64))
	wrong.SetReadDeadline(time.Now().Add(time.Second))
	if _, err = wrong.Read(make([]byte, 1)); err == nil {
		t.Fatal("invalid ticket accepted")
	}
	wrong.Close()
	c, err := net.Dial("tcp", localhost)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	const payload = "A paper kite crosses the orchard."
	if _, err = io.WriteString(c, route.Ticket+payload); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, len(payload))
	if _, err := io.ReadFull(c, response); err != nil || string(response) != payload {
		t.Fatalf("data did not return: %v", err)
	}
	if _, err := run(command{Op: "dial", Host: "unlisted.example", Port: 443}); err == nil {
		t.Fatal("unlisted origin was dialled")
	}
}
