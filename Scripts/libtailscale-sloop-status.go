// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md
//
// An extra export for libtailscale, copied into the upstream package by
// Scripts/build-libtailscale.sh before it is compiled.
//
// libtailscale's C API can start a node and dial over it, but gives no way to
// ask what the node is *doing* — and the two answers that matter for a UI are
// exactly the ones it withholds: whether the node is running, and, when it
// isn't, the URL the user must visit to authorize this device. tsnet has both
// on the status it already fetches (`ipnstate.Status.BackendState`, `.AuthURL`)
// and libtailscale simply doesn't surface them.
//
// The alternative is what this replaces: setting a log fd and scraping the
// authorization URL out of tsnet's human-readable log. That reads a debugging
// aid as an API — it breaks silently whenever upstream rewords a log line, and
// it fails in the direction that strands the user, since a URL that isn't found
// is a login that cannot be completed.

package main

// #include <errno.h>
import "C"

import (
	"context"
	"unsafe"
)

// TsnetSloopStatus writes "<BackendState>\n<AuthURL>" into buf.
//
// BackendState is tsnet's own vocabulary — "NeedsLogin", "Starting",
// "Running" — and AuthURL is empty unless the control plane is waiting for this
// device to be authorized.
//
// Returns 0 on success, EBADF for an unknown handle, ERANGE when buf is too
// small, or -1 with the reason available from tailscale_errmsg.
//
//export TsnetSloopStatus
func TsnetSloopStatus(sd C.int, buf *C.char, buflen C.size_t) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}

	lc, err := s.s.LocalClient()
	if err != nil {
		return s.recErr(err)
	}
	// Without peers: this is called on a timer while the user waits, and the
	// peer list is both the large part of the response and of no interest here.
	st, err := lc.StatusWithoutPeers(context.Background())
	if err != nil {
		return s.recErr(err)
	}

	out := st.BackendState + "\n" + st.AuthURL
	if C.size_t(len(out)+1) > buflen {
		return C.ERANGE
	}
	dst := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(buflen))
	copy(dst, out)
	dst[len(out)] = 0
	s.recErr(nil)
	return 0
}
