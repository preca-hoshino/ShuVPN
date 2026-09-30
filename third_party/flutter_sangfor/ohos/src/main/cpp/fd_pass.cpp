// Cross-process file descriptor hand-off over an AF_UNIX socket using
// SCM_RIGHTS. The VPN extension ability runs in its own process; the TUN
// descriptor it receives from vpnConnection.create() is sent through a
// local socket to the app process, where Dart reads and writes it directly
// through FFI (mirroring the Android VpnService detachFd() design).
//
// Main process side: startFdListener() binds the socket and accepts one
// connection on a background thread; pollFd() returns the received
// descriptor once available.
//
// Extension process side: sendFd() connects (with retries, since the
// listener may bind a beat after the extension spawns) and sends the
// descriptor with sendmsg().

#include "napi/native_api.h"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <thread>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

constexpr int kRetryDelayUs = 250 * 1000;

struct FdListenerState {
  std::atomic<bool> running{false};
  std::atomic<int> listenerFd{-1};
  std::atomic<int> receivedFd{-1};
};

FdListenerState g_state;

sockaddr_un MakeAddr(const char* path) {
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  std::strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  return addr;
}

void AcceptLoop(int listener) {
  while (g_state.running.load()) {
    int conn = accept(listener, nullptr, nullptr);
    if (conn < 0) {
      if (errno == EINTR) {
        continue;
      }
      // The listener was closed (stopFdListener or a newer startFdListener
      // replaced it); leave without touching shared state.
      return;
    }
    char payload = 0;
    iovec iov{};
    iov.iov_base = &payload;
    iov.iov_len = 1;
    union {
      char bytes[CMSG_SPACE(sizeof(int))];
      cmsghdr alignment;
    } control{};
    msghdr msg{};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.bytes;
    msg.msg_controllen = sizeof(control.bytes);
    ssize_t received = recvmsg(conn, &msg, 0);
    close(conn);
    if (received < 0) {
      continue;
    }
    for (cmsghdr* cmsg = CMSG_FIRSTHDR(&msg); cmsg != nullptr;
         cmsg = CMSG_NXTHDR(&msg, cmsg)) {
      if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS &&
          cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
        int fd = -1;
        std::memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
        if (fd >= 0) {
          g_state.receivedFd.store(fd);
          g_state.running.store(false);
          break;
        }
      }
    }
    if (!g_state.running.load()) {
      break;
    }
  }
  if (g_state.listenerFd.load() == listener) {
    g_state.listenerFd.store(-1);
    close(listener);
  }
}

void StopListenerLocked() {
  g_state.running.store(false);
  int listenerFd = g_state.listenerFd.exchange(-1);
  if (listenerFd >= 0) {
    // Unblocks accept() in the worker thread.
    close(listenerFd);
  }
  int pending = g_state.receivedFd.exchange(-1);
  if (pending >= 0) {
    close(pending);
  }
}

napi_value StartFdListener(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  char path[256] = {0};
  size_t length = 0;
  napi_get_value_string_utf8(env, args[0], path, sizeof(path) - 1, &length);

  bool ok = false;
  if (length > 0 && length < sizeof(sockaddr_un().sun_path)) {
    StopListenerLocked();
    unlink(path);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener >= 0) {
      sockaddr_un addr = MakeAddr(path);
      if (bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) ==
              0 &&
          listen(listener, 1) == 0) {
        g_state.listenerFd.store(listener);
        g_state.running.store(true);
        std::thread(AcceptLoop, listener).detach();
        ok = true;
      } else {
        close(listener);
      }
    }
  }
  napi_value result = nullptr;
  napi_get_boolean(env, ok, &result);
  return result;
}

napi_value PollFd(napi_env env, napi_callback_info info) {
  (void)info;
  int fd = g_state.receivedFd.exchange(-1);
  napi_value result = nullptr;
  napi_create_int32(env, fd, &result);
  return result;
}

napi_value StopFdListener(napi_env env, napi_callback_info info) {
  (void)info;
  StopListenerLocked();
  napi_value result = nullptr;
  napi_get_boolean(env, true, &result);
  return result;
}

napi_value SendFd(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  char path[256] = {0};
  size_t length = 0;
  napi_get_value_string_utf8(env, args[0], path, sizeof(path) - 1, &length);
  int32_t fd = -1;
  int32_t timeoutMs = 60000;
  if (argc > 1) {
    napi_get_value_int32(env, args[1], &fd);
  }
  if (argc > 2) {
    napi_get_value_int32(env, args[2], &timeoutMs);
  }

  bool ok = false;
  if (length > 0 && length < sizeof(sockaddr_un().sun_path) && fd >= 0) {
    int waitedMs = 0;
    while (waitedMs <= timeoutMs) {
      int sock = socket(AF_UNIX, SOCK_STREAM, 0);
      if (sock < 0) {
        break;
      }
      sockaddr_un addr = MakeAddr(path);
      if (connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) ==
          0) {
        char payload = 0;
        iovec iov{};
        iov.iov_base = &payload;
        iov.iov_len = 1;
        union {
          char bytes[CMSG_SPACE(sizeof(int))];
          cmsghdr alignment;
        } control{};
        msghdr msg{};
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.bytes;
        msg.msg_controllen = sizeof(control.bytes);
        cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
        cmsg->cmsg_level = SOL_SOCKET;
        cmsg->cmsg_type = SCM_RIGHTS;
        cmsg->cmsg_len = CMSG_LEN(sizeof(int));
        std::memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));
        ok = sendmsg(sock, &msg, 0) >= 0;
        close(sock);
        break;
      }
      close(sock);
      usleep(kRetryDelayUs);
      waitedMs += kRetryDelayUs / 1000;
    }
  }
  napi_value result = nullptr;
  napi_get_boolean(env, ok, &result);
  return result;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"startFdListener", nullptr, StartFdListener, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"pollFd", nullptr, PollFd, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"stopFdListener", nullptr, StopFdListener, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"sendFd", nullptr, SendFd, nullptr, nullptr, nullptr, napi_default,
       nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "flutter_sangfor",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterFlutterSangforModule() {
  napi_module_register(&g_module);
}
