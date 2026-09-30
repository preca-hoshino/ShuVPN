import Foundation
import Network
import NetworkExtension

/// PacketTunnelProvider that bridges the iOS system VPN packet flow to the
/// Flutter app via a local TCP loopback socket. Each packet is framed with
/// a 4-byte big-endian length prefix in both directions.
///
/// This type lives in `SangforTunnelCore`, which deliberately does not
/// depend on Flutter: consumer apps embed a thin `.appex` wrapper around it
/// as their Packet Tunnel Provider extension target.
///
/// EXPERIMENTAL / FOREGROUND BRIDGE: the loopback design requires the
/// containing Flutter app to stay alive; see the repository docs before
/// relying on it for background VPN use.
open class SangforPacketTunnelProvider: NEPacketTunnelProvider {
  /// Fixed loopback port used by the Phase 2 bridge. Not a public API
  /// contract; future revisions may make it configurable or remove the
  /// loopback bridge entirely.
  private static let ipcPort: UInt16 = 6400

  /// Maximum accepted IPC frame payload (largest possible IP packet over
  /// the tunnel MTU plus headroom).
  private static let maxFrameLength = 0xffff

  /// Bounded queue of packets read from the system before the Dart bridge
  /// connects: at most 128 packets or 1 MB, whichever is hit first.
  private static let pendingPacketLimit = 128
  private static let pendingPacketByteLimit = 1 << 20

  /// Backpressure cap for packets waiting to be written into the IPC socket.
  private static let outgoingByteLimit = 4 << 20

  /// If the Dart bridge stays absent this long after tunnel start (or after
  /// a disconnect), the tunnel is torn down so users never see a connected
  /// VPN with a dead data plane.
  private static let bridgeReconnectTimeout: TimeInterval = 30

  /// Error domain shared with the Runner side.
  private static let errorDomain = "flutter_sangfor"

  private let queue = DispatchQueue(label: "com.tsinbei.flutter_sangfor.ne")

  private var listener: NWListener?
  private var bridge: IpcBridge?
  private var readLoopRunning = false

  // Packets from the system waiting for the Runner to connect.
  private var pendingPackets: [Data] = []
  private var pendingBytes = 0

  private var bridgeTimeoutWorkItem: DispatchWorkItem?

  // Runtime counters exposed through handleAppMessage. Guarded by `queue`.
  private var metrics = Metrics()

  /// IPC and packet statistics.
  public struct Metrics: Codable {
    public var packetsInFromSystem = 0
    public var bytesInFromSystem = 0
    public var packetsOutToSystem = 0
    public var bytesOutToSystem = 0
    public var droppedBeforeIpc = 0
    public var droppedBackpressure = 0
    public var droppedIPv6 = 0
    public var malformedFrames = 0
    public var ipcReconnects = 0
  }

  // MARK: - Tunnel lifecycle

  public override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let configuration = Self.configuration(from: options ?? [:])
    SangforLog.provider(
      "startTunnel: address=\(configuration.address)/\(configuration.prefixLength) routes=\(configuration.routes.count) dns=\(configuration.dnsServers.count) mtu=\(configuration.mtu ?? 0)"
    )

    // Fail closed: a malformed route is logged and skipped, never silently
    // turned into a default route.
    var invalidRouteCount = 0
    let parsedRoutes = SangforIPv4.parseRoutes(configuration.routes) { _ in
      invalidRouteCount += 1
    }
    if invalidRouteCount > 0 {
      SangforLog.routing(
        "route validation dropped \(invalidRouteCount) malformed entr(ies)"
      )
    }

    guard
      let subnetMask = SangforIPv4.mask(
        forPrefixLength: configuration.prefixLength
      )
    else {
      completionHandler(
        NSError(
          domain: Self.errorDomain,
          code: Self.SettingsError.invalidPrefixLength.rawValue,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Invalid tunnel prefix length \(configuration.prefixLength)."
          ]
        )
      )
      return
    }

    let settings = NEPacketTunnelNetworkSettings(
      tunnelRemoteAddress: configuration.address
    )
    let ipv4 = NEIPv4Settings(
      addresses: [configuration.address],
      subnetMasks: [subnetMask]
    )
    ipv4.includedRoutes = parsedRoutes.map { route in
      NEIPv4Route(
        destinationAddress: route.destinationAddress,
        subnetMask: SangforIPv4.mask(forPrefixLength: route.prefixLength)!
      )
    }
    settings.ipv4Settings = ipv4
    if !configuration.dnsServers.isEmpty {
      let dns = NEDNSSettings(servers: configuration.dnsServers)
      dns.searchDomains = configuration.searchDomains.isEmpty
        ? nil
        : configuration.searchDomains
      settings.dnsSettings = dns
    }
    if let mtu = configuration.mtu, mtu > 0 {
      settings.mtu = mtu as NSNumber
    }
    // IPv4-only MVP: a documented limitation. IPv6 packets are dropped
    // with a counter instead of being mislabeled as IPv4.

    setTunnelNetworkSettings(settings) { [weak self] error in
      if let error {
        SangforLog.network(
          "applying tunnel settings failed: \(error.localizedDescription)"
        )
        completionHandler(error)
        return
      }
      guard let self else {
        completionHandler(nil)
        return
      }
      self.startIpcListener()
      self.startPacketFlowReadLoop()
      self.scheduleBridgeTimeout()
      completionHandler(nil)
    }
  }

  public override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    SangforLog.provider("stopping tunnel, reason: \(Self.describe(reason))")
    cancelBridgeTimeout()
    readLoopRunning = false
    listener?.cancel()
    listener = nil
    bridge?.close()
    bridge = nil
    completionHandler()
  }

  /// Settings validation failures reported from `startTunnel`.
  public enum SettingsError: Int {
    case invalidPrefixLength = 1
    case invalidAddress = 2
  }

  /// Answers control messages from the Runner (via
  /// `NETunnelProviderSession.sendProviderMessage`). Currently supports
  /// `{"action": "getStats"}`.
  override open func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)? = nil
  ) {
    guard
      let message = try? JSONDecoder().decode(
        ProviderMessage.self,
        from: messageData
      ),
      message.action == "getStats"
    else {
      completionHandler?(nil)
      return
    }
    let snapshot = queue.sync { metrics }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    completionHandler?(try? encoder.encode(snapshot))
  }

  private struct ProviderMessage: Codable {
    var action: String
  }

  // MARK: - Configuration

  private static func configuration(
    from options: [String: NSObject]
  ) -> SangforTunnelConfiguration {
    SangforTunnelConfiguration(
      address: (options["address"] as? String) ?? "10.0.0.2",
      prefixLength: (options["prefixLength"] as? Int) ?? 32,
      routes: (options["routes"] as? [String]) ?? [],
      dnsServers: (options["dnsServers"] as? [String]) ?? [],
      searchDomains: (options["searchDomains"] as? [String]) ?? [],
      mtu: (options["mtu"] as? Int).flatMap { $0 > 0 ? $0 : nil }
    )
  }

  // MARK: - System packet flow

  private func startPacketFlowReadLoop() {
    guard !readLoopRunning else { return }
    readLoopRunning = true
    readPackets()
  }

  private func readPackets() {
    packetFlow.readPackets { [weak self] packets, _ in
      guard let self, self.readLoopRunning else { return }
      for packet in packets {
        // IPv4 only in this milestone: drop IPv6 with a counter instead of
        // mislabeling it when writing back.
        guard SangforIPv4.packetFamily(packet) == 4 else {
          self.queue.async { self.metrics.droppedIPv6 += 1 }
          continue
        }
        self.queue.async {
          self.metrics.packetsInFromSystem += 1
          self.metrics.bytesInFromSystem += packet.count
          self.enqueueToBridge(packet)
        }
      }
      self.readPackets()
    }
  }

  /// Must run on `queue`.
  private func enqueueToBridge(_ packet: Data) {
    if let bridge, bridge.isConnected {
      bridge.send(framed: packet) { self.metrics.droppedBackpressure += 1 }
      return
    }
    // The Runner has not connected yet: buffer a bounded amount and flush
    // once it does; anything beyond the cap is dropped with a counter.
    if pendingPackets.count >= Self.pendingPacketLimit
      || pendingBytes + packet.count > Self.pendingPacketByteLimit {
      metrics.droppedBeforeIpc += 1
      return
    }
    pendingPackets.append(packet)
    pendingBytes += packet.count
  }

  // MARK: - IPC bridge

  private func startIpcListener() {
    do {
      let params = NWParameters.tcp
      // The bridge is strictly local to the device. Without pinning the
      // endpoint to loopback, Network.framework registers the listener on
      // the primary interface only (en0), which both drops connections from
      // the Runner to 127.0.0.1 and exposes the port to the local network.
      params.requiredLocalEndpoint = NWEndpoint.hostPort(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: Self.ipcPort)!
      )
      params.requiredInterfaceType = .loopback
      let listener = try NWListener(using: params)
      listener.newConnectionHandler = { [weak self] connection in
        self?.acceptBridgeConnection(connection)
      }
      listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
          SangforLog.ipcError("listener failed: \(error.localizedDescription)")
        }
      }
      listener.start(queue: queue)
      self.listener = listener
      SangforLog.ipc("listening on loopback:\(Self.ipcPort)")
    } catch {
      SangforLog.ipcError("IPC listener error: \(error.localizedDescription)")
    }
  }

  /// Must run on `queue`.
  private func acceptBridgeConnection(_ connection: NWConnection) {
    // New connection wins: cancel the previous generation and start a new
    // one so a Runner restart recovers cleanly.
    if bridge != nil {
      metrics.ipcReconnects += 1
    }
    bridge?.close()
    bridge = nil
    cancelBridgeTimeout()

    let bridge = IpcBridge(
      connection: connection,
      maxFrameLength: Self.maxFrameLength,
      outgoingByteLimit: Self.outgoingByteLimit
    )
    let bridgeBox = ObjectIdentifier(bridge)
    bridge.onPacket = { [weak self] packet in
      self?.inject(packet: packet)
    }
    bridge.onMalformedFrame = { [weak self] in
      self?.queue.async { self?.metrics.malformedFrames += 1 }
    }
    bridge.onReady = { [weak self] in
      guard let self else { return }
      self.flushPendingPackets()
      SangforLog.ipc("bridge connected")
    }
    bridge.onClosed = { [weak self, weak bridge] in
      guard let self else { return }
      if let current = self.bridge, ObjectIdentifier(current) == bridgeBox {
        self.bridge = nil
        // The Runner may restart and reconnect; give it a bounded window
        // before failing the tunnel.
        self.scheduleBridgeTimeout()
      }
    }
    bridge.start(queue: queue)
    self.bridge = bridge
  }

  private func inject(packet: Data) {
    guard !packet.isEmpty else { return }
    let family = SangforIPv4.packetFamily(packet) ?? 4
    let protocolFamily = family == 6 ? AF_INET6 : AF_INET
    packetFlow.writePackets([packet], withProtocols: [protocolFamily as NSNumber])
    queue.async {
      self.metrics.packetsOutToSystem += 1
      self.metrics.bytesOutToSystem += packet.count
    }
  }

  /// Must run on `queue`.
  private func flushPendingPackets() {
    guard !pendingPackets.isEmpty else { return }
    SangforLog.ipc("flushing \(pendingPackets.count) buffered packet(s)")
    for packet in pendingPackets {
      bridge?.send(framed: packet) { self.metrics.droppedBackpressure += 1 }
    }
    pendingPackets.removeAll()
    pendingBytes = 0
  }

  // MARK: - Bridge timeout

  /// Must run on `queue`.
  private func scheduleBridgeTimeout() {
    cancelBridgeTimeout()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.bridge == nil else { return }
      SangforLog.providerError(
        "no Dart bridge within \(Int(Self.bridgeReconnectTimeout))s; "
          + "cancelling tunnel"
      )
      self.cancelTunnelWithError(
        NSError(
          domain: Self.errorDomain,
          code: 100,
          userInfo: [
            NSLocalizedDescriptionKey:
              "The VPN data bridge (app side) did not connect in time."
          ]
        )
      )
    }
    bridgeTimeoutWorkItem = work
    queue.asyncAfter(
      deadline: .now() + Self.bridgeReconnectTimeout,
      execute: work
    )
  }

  /// Must run on `queue`.
  private func cancelBridgeTimeout() {
    bridgeTimeoutWorkItem?.cancel()
    bridgeTimeoutWorkItem = nil
  }

  private static func describe(_ reason: NEProviderStopReason) -> String {
    switch reason {
    case .none: "none"
    case .userInitiated: "userInitiated"
    case .providerFailed: "providerFailed"
    case .noNetworkAvailable: "noNetworkAvailable"
    case .unrecoverableNetworkChange: "unrecoverableNetworkChange"
    case .providerDisabled: "providerDisabled"
    case .authenticationCanceled: "authenticationCanceled"
    case .configurationFailed: "configurationFailed"
    case .idleTimeout: "idleTimeout"
    case .connectionFailed: "connectionFailed"
    case .appUpdate: "appUpdate"
    default: "reason(\(reason.rawValue))"
    }
  }
}

/// One framed TCP connection to the Runner's Dart bridge.
private final class IpcBridge {
  private let connection: NWConnection
  private let maxFrameLength: Int
  private let outgoingByteLimit: Int

  private var outgoing: [Data] = []
  private var outgoingBytes = 0
  private var writing = false
  private var ready = false
  private var closed = false

  var onPacket: ((Data) -> Void)?
  var onMalformedFrame: (() -> Void)?
  var onReady: (() -> Void)?
  var onClosed: (() -> Void)?

  var isConnected: Bool { ready && !closed }

  init(
    connection: NWConnection,
    maxFrameLength: Int,
    outgoingByteLimit: Int
  ) {
    self.connection = connection
    self.maxFrameLength = maxFrameLength
    self.outgoingByteLimit = outgoingByteLimit
  }

  func start(queue: DispatchQueue) {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self, !self.closed else { return }
      switch state {
      case .ready:
        self.ready = true
        self.onReady?()
        self.receiveFrameHeader()
      case .failed(let error):
        SangforLog.ipcError("bridge failed: \(error.localizedDescription)")
        self.finish()
      case .cancelled:
        self.finish()
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  func close() {
    connection.cancel()
  }

  /// Sends one length-framed packet, dropping it when the outgoing queue
  /// exceeds the byte cap (bounded backpressure with a drop policy).
  func send(framed packet: Data, onDrop: @escaping () -> Void) {
    guard ready, !closed else {
      onDrop()
      return
    }
    var frame = Data(capacity: 4 + packet.count)
    var length = UInt32(packet.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(packet)
    if outgoingBytes + frame.count > outgoingByteLimit {
      // The consumer cannot keep up; drop rather than buffer unboundedly.
      onDrop()
      return
    }
    outgoing.append(frame)
    outgoingBytes += frame.count
    drainWrites()
  }

  private func drainWrites() {
    guard !writing, !outgoing.isEmpty else { return }
    writing = true
    let frame = outgoing.removeFirst()
    outgoingBytes -= frame.count
    connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
      guard let self else { return }
      self.writing = false
      self.drainWrites()
    })
  }

  private func receiveFrameHeader() {
    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
      [weak self] data, _, isComplete, error in
      guard let self, !self.closed else { return }
      if let error {
        SangforLog.ipcError("bridge read error: \(error.localizedDescription)")
        return
      }
      if isComplete {
        // Peer closed the stream mid-session.
        self.finish()
        return
      }
      guard let data, data.count == 4 else {
        // A short, non-final header read: malformed framing.
        self.onMalformedFrame?()
        self.receiveFrameHeader()
        return
      }
      data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let length = UInt32(bigEndian: raw.load(as: UInt32.self))
        guard length > 0, length <= self.maxFrameLength else {
          // Zero-length or oversized: reject the frame and keep the
          // stream readable.
          self.onMalformedFrame?()
          self.receiveFrameHeader()
          return
        }
        self.receiveFramePayload(Int(length))
      }
    }
  }

  private func receiveFramePayload(_ length: Int) {
    connection.receive(
      minimumIncompleteLength: length,
      maximumLength: length
    ) { [weak self] data, _, isComplete, error in
      guard let self, !self.closed else { return }
      if let error {
        SangforLog.ipcError(
          "bridge payload error: \(error.localizedDescription)"
        )
        return
      }
      if let data, data.count == length {
        self.onPacket?(data)
      } else {
        self.onMalformedFrame?()
      }
      if isComplete {
        self.finish()
        return
      }
      self.receiveFrameHeader()
    }
  }

  private func finish() {
    guard !closed else { return }
    closed = true
    outgoing.removeAll()
    outgoingBytes = 0
    onClosed?()
  }
}
