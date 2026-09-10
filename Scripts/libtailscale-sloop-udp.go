// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md
//
// A datagram-preserving dial for libtailscale, copied into the upstream package
// by Scripts/build-libtailscale.sh before it is compiled.
//
// `tailscale_dial` already takes a network string, so "udp" reaches tsnet
// intact — but the fd it hands back cannot carry UDP. Upstream bridges every
// net.Conn to C through a SOCK_STREAM socketpair, and a stream socket has no
// message boundaries: two datagrams written into it arrive as one read, three
// as two, and a protocol that puts one frame per packet gets a byte soup it
// cannot parse. Mosh is exactly such a protocol, so its SSP session over a
// tailnet would fail at the first coalesced pair.
//
// This dials udp and bridges it through a SOCK_DGRAM socketpair instead, where
// one write is one datagram in both directions. tsnet's netstack hands back one
// datagram per Read, and io.CopyBuffer does a read then a write per iteration,
// so the boundary survives the crossing rather than being reconstructed
// afterwards by length prefixes nobody else in the pipeline speaks.
//
// It lives beside upstream's code rather than patching it: the change needs
// package-private access (`getServer`, `conns`, the `conn` type), and adding a
// file is a merge-free way to have it. Upstream's own `newConn` is untouched.

package main

// #include <errno.h>
import "C"

import (
	"context"
	"io"
	"net"
	"os"
	"syscall"
)

// TsnetDialUDP connects to addr ("host:port") over the tailnet and writes a
// datagram socket fd to connOut. Each write to that fd is one UDP packet.
//
// Returns 0 on success, EBADF for an unknown handle, or -1 with the reason
// available from tailscale_errmsg.
//
//export TsnetDialUDP
func TsnetDialUDP(sd C.int, addr *C.char, connOut *C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	netConn, err := s.s.Dial(context.Background(), "udp", C.GoString(addr))
	if err != nil {
		return s.recErr(err)
	}
	s.started = true
	if err := newDatagramConn(s, netConn, connOut); err != nil {
		return s.recErr(err)
	}
	return 0
}

// newDatagramConn is upstream's newConn with two differences: the socketpair
// carries messages rather than a stream, and neither direction half-closes —
// SHUT_WR on a datagram socket says nothing to the far end, so the close that
// matters is the fd's.
func newDatagramConn(s *server, netConn net.Conn, connOut *C.int) error {
	fds, err := syscall.Socketpair(syscall.AF_LOCAL, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return err
	}
	// A datagram larger than the socket's buffer is dropped, not truncated, and
	// AF_LOCAL defaults low enough to matter. Mosh's packets sit under 1500
	// bytes, but a UDP datagram may be up to 64 KB and silently losing the big
	// ones is the kind of bug that presents as "works until it doesn't".
	for _, fd := range fds {
		_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 1<<16)
		_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 1<<16)
	}

	r := os.NewFile(uintptr(fds[1]), "socketpair-dgram-r")
	c := &conn{s: s.s, c: netConn, r: r}
	fdC := C.int(fds[0])

	conns.mu.Lock()
	if conns.m == nil {
		conns.m = make(map[C.int]*conn)
	}
	conns.m[fdC] = c
	conns.mu.Unlock()

	connCleanup := func() {
		var inCleanup bool
		conns.mu.Lock()
		if tsConn, ok := conns.m[fdC]; ok && tsConn.c == netConn {
			delete(conns.m, fdC)
			inCleanup = true
		}
		conns.mu.Unlock()

		if !inCleanup {
			return
		}
		r.Close()
		netConn.Close()
	}

	// One datagram per iteration in each direction: Read yields exactly one,
	// Write sends exactly one.
	go func() {
		defer connCleanup()
		var b [1 << 16]byte
		io.CopyBuffer(r, netConn, b[:])
	}()
	go func() {
		defer connCleanup()
		var b [1 << 16]byte
		io.CopyBuffer(netConn, r, b[:])
	}()

	*connOut = fdC
	return nil
}
