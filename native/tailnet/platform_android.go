package main

import (
	"net"

	"tailscale.com/net/netmon"
)

// Android restricts netlink interface enumeration for app UIDs. As in
// upstream's androidbin implementation, ask the kernel which local source it
// would select. Connecting a UDP socket without writing sends no packets.
// androidbin's automatic fallback excludes cgo builds such as this shared library.
func init() {
	netmon.HookInterfacesFallback.Set(func() ([]netmon.Interface, error) {
		var addrs []net.Addr
		for _, target := range []string{"192.0.2.1:53", "[2001:db8::1]:53"} {
			socket, err := net.Dial("udp", target)
			if err != nil {
				continue
			}
			ip := socket.LocalAddr().(*net.UDPAddr).IP
			socket.Close()
			bits := 128
			if ipv4 := ip.To4(); ipv4 != nil {
				ip = ipv4
				bits = 32
			}
			addrs = append(addrs, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
		}
		if len(addrs) == 0 {
			return nil, &net.OpError{Op: "interface", Net: "android", Err: net.ErrClosed}
		}
		return []netmon.Interface{{
			Interface: &net.Interface{Name: "android", MTU: 1500, Flags: net.FlagUp | net.FlagRunning},
			AltAddrs:  addrs,
		}}, nil
	})
}
