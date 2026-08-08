//
//  MoshBridge.mm
//  Sloop
//
//  Objective-C++ bridge over mosh's client core. Owns a Network::Transport
//  <UserStream, Complete> on a dedicated thread and mirrors the upstream
//  mosh-client main loop (see mosh src/frontend/stmclient.cc) minus the local
//  terminal and prediction overlay — Sloop renders the server's authoritative
//  framebuffer straight into SwiftTerm.
//
//  Threading model: the transport is single-threaded, so exactly one thread
//  (the loop below) ever touches it. send/resize/close come from other threads,
//  land in a mutex-guarded queue, and wake the loop through a self-pipe. Output
//  and the terminal close are delivered on the loop thread via the C callbacks.
//

#import "MoshBridge.h"

// Only the SSH-enabled project (project.ssh.yml) links mosh.xcframework and
// therefore has mosh's headers on the search path. In the base project the
// mosh headers are absent, so this whole translation unit compiles to nothing —
// the C symbols simply aren't defined, and MoshTransport.swift is gated off the
// same way (`#if canImport(CSSH)`), so nothing references them.
#if __has_include("networktransport.h")

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

// mosh's C++ client core (from mosh.xcframework's flat Headers dir).
//
// Include the *-impl.h template definitions, not just networktransport.h: the
// Network::Transport<UserStream, Complete> and TransportSender<UserStream>
// instantiations live only in mosh's frontend TUs (stmclient.cc), which we
// don't build. Pulling in the impl header here (as stmclient does) makes this
// TU instantiate those template methods itself. networktransport-impl.h
// includes networktransport.h and transportsender-impl.h.
//
// networktransport-impl.h uses the fatal_assert() macro but doesn't include its
// header — stmclient.cc includes fatal_assert.h first, so we do too.
#include "fatal_assert.h"
#include "networktransport-impl.h"
#include "user.h"
#include "completeterminal.h"
#include "terminaldisplay.h"
#include "terminalframebuffer.h"
#include "parseraction.h"

typedef Network::Transport<Network::UserStream, Terminal::Complete> MoshTransportType;

namespace {

// A single queued user-side event: either raw bytes to send, or a resize.
struct PendingEvent {
  enum Kind { Bytes, Resize } kind;
  std::string bytes;  // Kind == Bytes
  int cols = 0;       // Kind == Resize
  int rows = 0;
};

}  // namespace

struct MoshSession {
  // Immutable connection parameters, captured at create().
  std::string ip;
  std::string port;
  std::string key;
  int cols = 80;
  int rows = 24;

  // Callbacks + opaque context (set once, before start()).
  MoshOutputCallback on_output = nullptr;
  MoshCloseCallback on_close = nullptr;
  void *ctx = nullptr;

  // The network thread and its wakeup pipe.
  std::thread thread;
  std::atomic<bool> running{false};
  int wake_read = -1;
  int wake_write = -1;

  // Cross-thread command queue.
  std::mutex mutex;
  std::vector<PendingEvent> queue;
  bool close_requested = false;

  void wake() {
    if (wake_write >= 0) {
      const char b = 1;
      ssize_t n = ::write(wake_write, &b, 1);
      (void)n;  // best-effort; a full pipe already means "wake pending"
    }
  }
};

// MARK: - Network loop

static void mosh_run_loop(MoshSession *s) {
  Terminal::Display display(false);  // curses-free (see terminaldisplayinit stub)
  Terminal::Framebuffer last_fb(1, 1);
  bool initialized = false;

  std::string close_reason;

  try {
    Network::UserStream blank;
    Terminal::Complete local_terminal(s->cols, s->rows);
    MoshTransportType network(blank, local_terminal,
                              s->key.c_str(), s->ip.c_str(), s->port.c_str());
    network.set_send_delay(1);  // minimal delay on outgoing keystrokes

    // Tell the server our initial size.
    network.get_current_state().push_back(Parser::Resize(s->cols, s->rows));

    uint64_t last_num = network.get_remote_state_num();
    bool shutting_down = false;

    while (s->running.load()) {
      // Drain queued user events into the transport's outgoing state.
      bool want_close = false;
      std::vector<PendingEvent> pending;
      {
        std::lock_guard<std::mutex> lock(s->mutex);
        pending.swap(s->queue);
        want_close = s->close_requested;
      }
      for (const auto &ev : pending) {
        if (network.shutdown_in_progress()) break;
        if (ev.kind == PendingEvent::Bytes) {
          for (char c : ev.bytes) {
            network.get_current_state().push_back(Parser::UserByte(c));
          }
        } else {
          network.get_current_state().push_back(Parser::Resize(ev.cols, ev.rows));
        }
      }
      if (want_close && !shutting_down) {
        shutting_down = true;
        network.start_shutdown();
      }

      network.tick();  // flush anything queued above

      // Wait for a network packet, a wakeup, or the sender's next deadline.
      int wait_ms = network.wait_time();
      if (wait_ms < 0 || wait_ms > 1000) wait_ms = 1000;  // cap so we re-check state
      struct timeval tv;
      tv.tv_sec = wait_ms / 1000;
      tv.tv_usec = (wait_ms % 1000) * 1000;

      fd_set rfds;
      FD_ZERO(&rfds);
      int maxfd = s->wake_read;
      FD_SET(s->wake_read, &rfds);
      std::vector<int> netfds = network.fds();
      for (int fd : netfds) {
        FD_SET(fd, &rfds);
        if (fd > maxfd) maxfd = fd;
      }

      int active = ::select(maxfd + 1, &rfds, nullptr, nullptr, &tv);
      if (active < 0) {
        if (errno == EINTR) continue;
        close_reason = std::string("select: ") + strerror(errno);
        break;
      }

      // Drain the wakeup pipe (its only purpose is to interrupt select).
      if (FD_ISSET(s->wake_read, &rfds)) {
        char buf[64];
        while (::read(s->wake_read, buf, sizeof(buf)) > 0) {
        }
      }

      // Receive any datagrams that arrived.
      bool got_packet = false;
      for (int fd : netfds) {
        if (FD_ISSET(fd, &rfds)) {
          got_packet = true;
          break;
        }
      }
      if (got_packet) {
        network.recv();
      }

      // Render the server's framebuffer if it advanced.
      if (network.get_remote_state_num() != last_num) {
        last_num = network.get_remote_state_num();
        const Terminal::Framebuffer &new_fb =
            network.get_latest_remote_state().state.get_fb();
        std::string diff = display.new_frame(initialized, last_fb, new_fb);
        initialized = true;
        last_fb = new_fb;
        if (!diff.empty() && s->on_output) {
          s->on_output(diff.data(), diff.size(), s->ctx);
        }
      }

      // Shutdown bookkeeping (mirrors stmclient).
      if (network.shutdown_in_progress() && network.shutdown_acknowledged()) {
        break;
      }
      if (network.shutdown_in_progress() && network.shutdown_ack_timed_out()) {
        break;
      }
      if (network.counterparty_shutdown_ack_sent()) {
        break;
      }
      // Give up if the server has gone silent for too long.
      if (network.get_remote_state_num() != 0 &&
          Network::timestamp() - network.get_latest_remote_state().timestamp > 15000) {
        if (close_reason.empty()) close_reason = "Mosh session timed out";
        break;
      }
    }
  } catch (const Network::NetworkException &e) {
    close_reason = std::string("network: ") + e.what();
  } catch (const Crypto::CryptoException &e) {
    close_reason = std::string("crypto: ") + e.what();
  } catch (const std::exception &e) {
    close_reason = e.what();
  } catch (...) {
    close_reason = "unknown Mosh error";
  }

  s->running.store(false);
  if (s->on_close) {
    s->on_close(close_reason.empty() ? nullptr : close_reason.c_str(), s->ctx);
  }
}

// MARK: - C API

MoshSession *mosh_session_create(const char *ip, const char *port, const char *key,
                                 int cols, int rows) {
  MoshSession *s = new (std::nothrow) MoshSession();
  if (!s) return nullptr;
  s->ip = ip ? ip : "";
  s->port = port ? port : "";
  s->key = key ? key : "";
  s->cols = cols > 0 ? cols : 80;
  s->rows = rows > 0 ? rows : 24;
  return s;
}

void mosh_session_set_callbacks(MoshSession *session,
                                MoshOutputCallback on_output,
                                MoshCloseCallback on_close,
                                void *ctx) {
  if (!session) return;
  session->on_output = on_output;
  session->on_close = on_close;
  session->ctx = ctx;
}

void mosh_session_start(MoshSession *session) {
  if (!session || session->running.load()) return;

  int fds[2];
  if (::pipe(fds) != 0) {
    if (session->on_close) session->on_close("pipe() failed", session->ctx);
    return;
  }
  // Non-blocking read end so we can drain it without blocking the loop.
  ::fcntl(fds[0], F_SETFL, ::fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK);
  session->wake_read = fds[0];
  session->wake_write = fds[1];

  session->running.store(true);
  session->thread = std::thread(mosh_run_loop, session);
}

void mosh_session_send(MoshSession *session, const char *bytes, size_t len) {
  if (!session || !bytes || len == 0) return;
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    PendingEvent ev;
    ev.kind = PendingEvent::Bytes;
    ev.bytes.assign(bytes, len);
    session->queue.push_back(std::move(ev));
  }
  session->wake();
}

void mosh_session_resize(MoshSession *session, int cols, int rows) {
  if (!session || cols <= 0 || rows <= 0) return;
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    PendingEvent ev;
    ev.kind = PendingEvent::Resize;
    ev.cols = cols;
    ev.rows = rows;
    session->queue.push_back(std::move(ev));
  }
  session->wake();
}

void mosh_session_close(MoshSession *session) {
  if (!session) return;
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    session->close_requested = true;
  }
  session->wake();
}

void mosh_session_destroy(MoshSession *session) {
  if (!session) return;
  session->running.store(false);
  session->wake();
  if (session->thread.joinable()) session->thread.join();
  if (session->wake_read >= 0) ::close(session->wake_read);
  if (session->wake_write >= 0) ::close(session->wake_write);
  delete session;
}

#endif  // __has_include("networktransport.h")
