//
//  MoshBridge.h
//  Sloop
//
//  A plain-C surface over mosh's C++ client core (Network::Transport over the
//  State-Synchronization Protocol). Swift talks to this; the .mm side owns the
//  mosh objects and a dedicated network thread.
//
//  Lifecycle: create → set_callbacks → start → (send/resize)* → close → destroy.
//  All callbacks are delivered on the bridge's own network thread; the Swift
//  MoshTransport hops them to wherever it needs them.
//

#ifndef MOSH_BRIDGE_H
#define MOSH_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MoshSession MoshSession;

/// Server→client output (already-rendered ANSI to feed the terminal).
typedef void (*MoshOutputCallback)(const char *bytes, size_t len, void *ctx);
/// Fires exactly once when the session ends. `reason` is NULL on a clean close,
/// otherwise a short human-readable string (never owned by the callee).
typedef void (*MoshCloseCallback)(const char *reason, void *ctx);

/// Allocate a session for `ip`/`port` (the mosh-server UDP endpoint) secured by
/// the base64 `key` from the MOSH CONNECT handshake, sized to `cols`×`rows`.
/// Does not touch the network yet. Returns NULL only on allocation failure.
MoshSession *mosh_session_create(const char *ip, const char *port, const char *key,
                                 int cols, int rows);

/// Register the output/close callbacks and an opaque context. Call before start.
void mosh_session_set_callbacks(MoshSession *session,
                                MoshOutputCallback on_output,
                                MoshCloseCallback on_close,
                                void *ctx);

/// Spin up the background thread that constructs the transport and runs the
/// recv/tick loop. Connection errors surface through the close callback.
void mosh_session_start(MoshSession *session);

/// Queue user keystrokes (client→server). Thread-safe; wakes the loop.
void mosh_session_send(MoshSession *session, const char *bytes, size_t len);

/// Queue a terminal resize. Thread-safe; wakes the loop.
void mosh_session_resize(MoshSession *session, int cols, int rows);

/// Request a graceful shutdown. The close callback fires when it completes.
/// Thread-safe; wakes the loop.
void mosh_session_close(MoshSession *session);

/// Free the session. Safe to call after the close callback has fired; joins the
/// network thread if it is still running.
void mosh_session_destroy(MoshSession *session);

#ifdef __cplusplus
}
#endif

#endif /* MOSH_BRIDGE_H */
