//go:build !android && !ios

package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/netns"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func TestPrivateStreamOnSyntheticTailnet(t *testing.T) {
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	relay := derpserver.New(key.NewNode(), logger.Discard)
	https := httptest.NewTLSServer(derpserver.Handler(relay))
	t.Cleanup(func() { https.CloseClientConnections(); relay.Close(); https.Close() })
	relayNode := &tailcfg.DERPNode{
		Name: "preview", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none",
		STUNPort: -1, DERPPort: https.Listener.Addr().(*net.TCPAddr).Port, InsecureForTests: true,
	}
	control := &testcontrol.Server{
		DERPMap: &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
			1: {RegionID: 1, RegionCode: "preview", Nodes: []*tailcfg.DERPNode{relayNode}},
		}},
		DNSConfig: &tailcfg.DNSConfig{Proxied: true}, MagicDNSDomain: "preview.ts.net", Logf: logger.Discard,
	}
	control.HTTPTestServer = httptest.NewServer(control)
	t.Cleanup(control.HTTPTestServer.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	node := func(name string) *tsnet.Server {
		s := &tsnet.Server{Dir: t.TempDir(), Hostname: name, ControlURL: control.HTTPTestServer.URL, Logf: logger.Discard, UserLogf: logger.Discard}
		if _, err := s.Up(ctx); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { s.Close() })
		return s
	}
	server := node("orchard")
	listener, err := server.Listen("tcp", ":8080")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	if target := os.Getenv("CONDUIT_TAILNET_FIXTURE"); target != "" {
		log := fmt.Sprintf("%s\n%d\n", control.HTTPTestServer.URL, relayNode.DERPPort)
		if err := os.WriteFile(target, []byte(log), 0600); err != nil {
			t.Fatal(err)
		}
		// The device runner removes the file after the last client exits.
		deadline := time.After(15 * time.Minute)
		for {
			if _, err := os.Stat(target); os.IsNotExist(err) {
				return
			}
			select {
			case <-time.After(time.Second):
			case <-deadline:
				t.Fatal("fixture timed out")
			}
		}
	}
	exercisePeer(t, ctx, node("reader"), cancel)
}
