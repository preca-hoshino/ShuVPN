# flutter_sangfor

Flutter integration for Sangfor aTrust-compatible VPN deployments.

## Status

This repository is an independent implementation. It does not include or
redistribute Sangfor SDK binaries. The public API and platform adapters are
being built incrementally, with protocol behavior tested against authorized
deployments only.

The package scaffold declares Android, iOS, Windows, macOS, and Linux targets.
The connection control plane is wired consistently on every declared platform.
`getState` and `disconnect` are available on native adapters. The platform
channel `connect` is intentionally `unsupported`: the Dart connectors
(`ATrustConnector` / `EasyConnectConnector`) own the full login and tunnel
bring-up, and platform TUN adapters (`WintunDevice`, `TunDevice`,
`UtunDevice`, `AndroidVpnDevice`, `IosVpnDevice`) are invoked via FFI/IPC
after a `connected` session is established.

## API direction

The Dart API exposes structured connection state, authentication types, and
platform capability discovery. The protocol core is kept separate from Flutter
platform glue so it can be tested independently and reused by desktop and
mobile adapters.

The root package exposes `SangforAuthRequest` and `SangforAuthTransport` as the
transport boundary. The aTrust package now implements authenticated-server
discovery (`/public/manifest` and `/passport/v1/public/authConfig`) through a
platform-trusted HTTPS client. Primary password exchange, MFA step
normalization, interactive SMS verification, client-resource retrieval, and
L3VPN resource parsing are implemented. Authenticated Cookie/SID continuity,
environment reporting, and online-user lookup are also available.
`ATrustLoginSession` coordinates these steps into a password and SMS login
flow without reporting the VPN tunnel as connected. TOTP, RADIUS, and generic
code challenges are supported through explicit caller-provided callbacks.
`ATrustConnector` can run this Dart control plane when given an injected login
session and returns an `authenticated` state until a tunnel is established.
Access checks, enhanced-auth continuation, and binding the current device are
supported as server-directed steps. Device trust management and tunnel setup
remain separate work.

Authenticated state can be serialized with `ATrustSessionSnapshot`. Snapshots
contain server, username, device ID, CSRF token, and cookies, but never include
passwords or challenge codes. Resource parsing also exposes WAN/LAN node groups
with normalized tunnel endpoints.

The aTrust package includes a bounded, incremental tunnel-frame boundary,
transport lifecycle state machine, heartbeat/reconnect primitives, and a
packet-to-channel bridge. The frame envelope is an internal abstraction and is
not presented as the verified on-wire aTrust frame format; the codec remains
replaceable after authorized interoperability tests.

After a successful login, `ATrustConnector` now establishes the full L3
tunnel: it probes node groups (3x TCP latency with WAN-then-LAN fallback),
acquires the client virtual IP over a Query-IP TLS connection, opens a
tunnel connection per node group with the authTunnel handshake, and returns
a `connected` session carrying the virtual address and VPN DNS servers.
The running tunnel (`connector.tunnel`) exposes a merged raw IPv4 packet
stream, per-flow authenticated `sendPacket` routing through CIDR/range/
domain route matching, VIP update callbacks, and `dialTcp` for
SOCKS5-style per-connection tunneling. The TLS policy verifies against the
platform trust store by default and falls back to anti-MITM certificate
pinning when the platform validation fails.

The aTrust L3 wire protocol is additionally implemented from behavior
observed in the public zju-connect reference and unit-tested at the
byte level: the initial tunnel auth handshake (`0x05 0xD0` / `0x53`
envelope) with VIP parsing, per-flow authenticated data frames with
`xRequestSig` HMAC signing, the conntrack TCP state machine with
protocol-specific TTLs, raw IPv4/TCP/UDP packet parsing,
stream splitting for inbound IP packets, and the SOCKS5-like TCP tunnel with
its handshake, connect replies, data frames, and EOF signaling. Anti-MITM
verification now also pins the server certificate via
`ATrustApiClient.verifyServerCertificate` using a pinned `SecurityContext`
rather than the platform trust store.

The Easy Connect package implements the XML control plane (login with RSA
password encryption, SMS, and TOTP continuation) plus the data-plane
primitives guided by the public EasierConnect/NJUConnect/SHIEP-Pipeline
references: `conf.csp` and `rclist.csp` parsing (DNS servers, backup DNS,
multi-line server lists, routed resource entries with host/port ranges), the
48-byte tunnel token derivation from the TLS session id and TWFID, the
64-byte Query-IP/TX/RX/command-heartbeat handshake messages, Query-IP reply
parsing, native `AABB` control-frame parsing, the 76-byte ICMP TX heartbeat
with verified IP/ICMP checksums, and the `update_session.csp` HTTP keepalive.

The EasyConnect data channel itself runs on a minimal TLS 1.1/1.2 client
implemented per RFC 4346/5246 (`EasyConnectTlsClient`), because the servers
demultiplex on a ClientHello shape (`L3IP` session id, TLS 1.1, RC4-SHA)
that dart:io cannot emit. It performs RSA key exchange with RC4-SHA and
AES128-CBC-SHA record protection, and it fails closed: a certificate
validator is required unless unverified connections are explicitly opted
into. `EasyConnectTunnel` drives the full bring-up - token connection,
Query-IP over a long-lived command stream, RX/TX raw-IP streams with
12s/30s heartbeats, 60s HTTP keepalive - and exposes a raw IPv4 packet
stream. After login, `EasyConnectConnector` establishes the tunnel and
returns a `connected` session carrying the virtual address.

Both product packages support `dryRun` connections that validate options and
return an authenticated session without any network I/O.

## Using the tunnel

Both connectors expose `dialTcp(host, port)` after a `connected` session:
aTrust dials its native SOCKS5-like TCP tunnel, while EasyConnect
synthesizes TCP connections over the L3 packet stream (`EasyConnectTcpProxy`,
an RFC 793 client-role stack with retransmission, zero-window probing, and
out-of-order reassembly, plus UDP flows and an RFC 1035 DNS resolver that
queries the VPN DNS servers over the tunnel).

On top of that, the root package ships a userspace SOCKS5 frontend:

```dart
final socks5 = SangforSocks5Server(dialer: connector.dialTcp);
final port = await socks5.start(); // loopback; point apps/browsers at it
```

For system-wide routing, `SangforTunnelRouter` pumps packets between a
tunnel and a `SangforPacketDevice`: `WintunDevice` on Windows (requires the
official signed `wintun.dll` from wintun.net beside the executable, plus an
elevated process; address/route/DNS helpers use `netsh`), `TunDevice` on
Linux (`/dev/net/tun`, `CAP_NET_ADMIN`), `UtunDevice` on macOS (utun via
`AF_SYS_CONTROL`, requires root), and `AndroidVpnDevice` / `IosVpnDevice`
for the mobile VPN frameworks (VpnService / NetworkExtension). Desktop and
Android adapters run their read loops on a dedicated isolate; the iOS
adapter bridges `NEPacketFlow` over a loopback TCP socket. None have been
exercised against real interfaces yet.

```dart
final device = await WintunDevice.open(name: 'Sangfor');
await device.configureAddress(virtualAddress, '255.255.255.255');
await device.addRoute('10.0.0.0', 8);
await device.setDnsServers(dnsServers);
SangforTunnelRouter().start(device: device, tunnel: connector.tunnel!);
```

Both `SangforTunnelRouter` and `SangforSocks5Server` accept a
`SangforCancellationToken`; cancelling it stops the router and tears down
the proxy with all live sessions, including in-flight dials. The example
app (`example/`) ships a SOCKS5 demo with a loopback echo round-trip test.

## iOS system VPN setup

iOS system-level routing runs through a Packet Tunnel Provider app
extension (`NEPacketTunnelProvider`) managed by `NETunnelProviderManager`.
Entitlements belong to your App ID and targets, not to this pub package,
so the steps below happen in your app's Xcode project:

1. **Requirements**: a paid Apple Developer Program membership and a
   physical device (the Network Extension entitlement cannot be exercised
   in the simulator).
2. **Add the extension target**: in Xcode, `File > New > Target > Network
   Extension`, choose "Packet Tunnel Provider". Name it (conventionally
   `SangforPacketTunnel`); its bundle identifier must start with your
   app's bundle identifier (for example
   `com.example.app.SangforPacketTunnel`).
3. **Link the core**: the extension needs the Flutter-free
   `SangforTunnelCore` module. With Swift Package Manager add the local
   package at `<your pub cache>/flutter_sangfor/ios/flutter_sangfor` and
   link its `SangforTunnelCore` product to the extension target (see
   `example/ios` for a working setup). With CocoaPods, add to your
   `Podfile`:

   ```ruby
   target 'SangforPacketTunnel' do
     use_frameworks!
     pod 'SangforTunnelCore', :path => File.join('.symlinks', 'plugins', 'flutter_sangfor', 'ios')
   end
   ```
4. **Replace the generated provider** with the thin wrapper (templates in
   `ios/templates/`):

   ```swift
   import SangforTunnelCore

   final class PacketTunnelProvider: SangforPacketTunnelProvider {}
   ```
5. **Entitlements**: enable the Network Extensions capability
   (`packet-tunnel-provider`) and an App Group on both the Runner target
   and the extension target; use the same App Group identifier on both.
6. **Embed**: Xcode adds the extension to the app's Embed App Extensions
   build phase automatically when the target is created this way; verify it
   exists.
7. **Dart configuration**: pass `providerBundleIdentifier` and
   `appGroupIdentifier` to `IosVpnDevice.start`.
8. **First run**: the system shows a VPN permission prompt the first time
   a configuration is saved; the VPN entry then appears in
   Settings > General > VPN & Device Management.

The current iOS data plane forwards packets from the extension to your
Flutter app over a loopback TCP bridge (EXPERIMENTAL / FOREGROUND
BRIDGE): the Runner must stay alive, so treat it as a functional baseline
rather than a background-capable production architecture.

## Package family

Use `flutter_sangfor` for common lifecycle and platform abstractions. Add
`flutter_sangfor_atrust` for aTrust-specific authentication and
`flutter_sangfor_easy_connect` for Easy Connect-specific behavior. The product
packages depend on the root package and never depend on each other.

## License

The original Flutter integration is MIT licensed. This project does not grant
rights to Sangfor/Atrust trademarks, proprietary SDKs, binaries, or
service-side intellectual property.

## Acknowledgments

This project is an independent clean-room reimplementation of publicly
observed wire behavior; no source code is copied from the following
projects, which were used as behavior references:

- [Mythologyli/zju-connect](https://github.com/Mythologyli/zju-connect) (AGPL-3.0)
  — aTrust L3 tunnel, per-flow auth, conntrack, TCP tunnel.
- [GayStudio/EasierConnect](https://github.com/GayStudio/EasierConnect)
  — EasyConnect XML control plane reference.
- [lyc8503/NJUConnect](https://github.com/lyc8503/NJUConnect)
  — EasyConnect control plane reference.
- [Yan233th/SHIEP-Pipeline](https://github.com/Yan233th/SHIEP-Pipeline) (AGPL-3.0, Rust)
  — EasyConnect token, Query-IP, RX/TX stream, heartbeat.
- [WireGuard/wintun](https://www.wintun.net/)
  — Windows TUN adapter (official signed DLL loaded at runtime).
