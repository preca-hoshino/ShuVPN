import Flutter
import NetworkExtension
import UIKit

#if SWIFT_PACKAGE
import SangforTunnelCore
#endif

/// Runner-side adapter: translates method-channel calls into
/// `SangforTunnelManager` operations. All manager logic lives in the core
/// module so extension targets can reuse it without Flutter.
public class FlutterSangforPlugin: NSObject, FlutterPlugin {
  private var tunnelManager: SangforTunnelManager?
  private var statusSink: FlutterEventSink?

  /// Legacy fallback suffix appended to the app's bundle identifier when
  /// neither the Dart call nor the Runner Info.plist names a provider.
  private static let legacyProviderSuffix = "SangforPacketTunnelProvider"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_sangfor", binaryMessenger: registrar.messenger())
    let instance = FlutterSangforPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    let statusChannel = FlutterEventChannel(
      name: "flutter_sangfor/vpn_status",
      binaryMessenger: registrar.messenger()
    )
    statusChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getState":
      result(statusString)
    case "getCapabilities":
      result(capabilities)
    case "disconnect":
      tunnelManager?.stop()
      result(nil)
    case "connect":
      result(FlutterError(code: "unsupported", message: "The aTrust transport is not implemented on iOS yet.", details: nil))
    case "vpnPrepare":
      // On iOS the VPN permission is requested when a configuration is
      // first saved; report whether one of ours is installed and enabled.
      prepare(call, result: result)
    case "vpnInstall":
      install(call, result: result)
    case "vpnStart":
      startVpn(call, result: result)
    case "vpnStop":
      tunnelManager?.stop()
      result(nil)
    case "vpnStats":
      requestStats(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Capability reporting

  private var statusString: String {
    tunnelManager?.status.sangforName ?? "invalid"
  }

  private var capabilities: [String: Any] {
    [
      "platform": "ios",
      "supportsVpn": true,
      "supportsTun": true,
      "supportsSocks5": true,
      "supportedAuthTypes": [String](),
      "packetTunnelProviderInstalled": packetTunnelProviderInstalled,
      "vpnConfigurationInstalled": tunnelManager != nil,
    ]
  }

  /// Whether the configured provider extension is actually embedded in
  /// the app bundle (PlugIns/<name>.appex).
  private var packetTunnelProviderInstalled: Bool {
    guard let provider = resolvedProviderBundleIdentifier(nil) else {
      return false
    }
    let name = (provider as NSString).lastPathComponent
    let pluginsURL = Bundle.main.builtInPlugInsURL
      ?? Bundle.main.bundleURL.appendingPathComponent("PlugIns")
    return Bundle(url: pluginsURL.appendingPathComponent("\(name).appex")) != nil
  }

  // MARK: - Identifier resolution

  /// Priority: explicit Dart argument > Runner Info.plist > legacy default.
  private func resolvedProviderBundleIdentifier(_ argument: String?) -> String? {
    if let argument, !argument.isEmpty {
      return argument
    }
    if let fromPlist = Bundle.main.object(
      forInfoDictionaryKey: "SangforPacketTunnelBundleIdentifier"
    ) as? String, !fromPlist.isEmpty {
      return fromPlist
    }
    return Bundle.main.bundleIdentifier.map { "\($0).\(Self.legacyProviderSuffix)" }
  }

  private func resolvedAppGroupIdentifier(_ argument: String?) -> String? {
    if let argument, !argument.isEmpty {
      return argument
    }
    if let fromPlist = Bundle.main.object(
      forInfoDictionaryKey: "SangforAppGroupIdentifier"
    ) as? String, !fromPlist.isEmpty {
      return fromPlist
    }
    return nil
  }

  private func ensureManager(_ call: FlutterMethodCall) -> SangforTunnelManager? {
    let args = call.arguments as? [String: Any] ?? [:]
    guard
      let provider = resolvedProviderBundleIdentifier(args["providerBundleIdentifier"] as? String)
    else {
      return nil
    }
    let appGroup = resolvedAppGroupIdentifier(args["appGroupIdentifier"] as? String)
    let description = (args["localizedDescription"] as? String).flatMap {
      $0.isEmpty ? nil : $0
    }
    if let tunnelManager {
      // Keep the existing manager unless the identity changed.
      if tunnelManager.providerBundleIdentifier == provider,
        tunnelManager.appGroupIdentifier == appGroup {
        return tunnelManager
      }
    }
    let manager = SangforTunnelManager(
      providerBundleIdentifier: provider,
      appGroupIdentifier: appGroup,
      localizedDescription: description ?? "flutter_sangfor"
    )
    manager.onStatusChange { [weak self] status in
      self?.statusSink?(status.sangforName)
    }
    tunnelManager = manager
    return manager
  }

  // MARK: - Method implementations

  private func prepare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let manager = ensureManager(call) else {
      result(
        FlutterError(
          code: "providerNotFound",
          message: "The packet tunnel provider extension is not configured for this app.",
          details: nil
        )
      )
      return
    }
    manager.install { error in
      if let error {
        result(self.flutterError(for: error))
        return
      }
      result(true)
    }
  }

  private func install(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let manager = ensureManager(call) else {
      result(
        FlutterError(
          code: "providerNotFound",
          message: "The packet tunnel provider extension is not configured for this app.",
          details: nil
        )
      )
      return
    }
    manager.install { error in
      if let error {
        result(self.flutterError(for: error))
        return
      }
      result(true)
    }
  }

  private func startVpn(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let manager = ensureManager(call) else {
      result(
        FlutterError(
          code: "providerNotFound",
          message: "The packet tunnel provider extension is not configured for this app.",
          details: nil
        )
      )
      return
    }
    let options: [String: NSObject] = [
      "address": (args["address"] as? String ?? "10.0.0.2") as NSString,
      "prefixLength": (args["prefixLength"] as? Int ?? 32) as NSNumber,
      "routes": (args["routes"] as? [String] ?? []) as NSArray,
      "dnsServers": (args["dnsServers"] as? [String] ?? []) as NSArray,
      "searchDomains": (args["searchDomains"] as? [String] ?? []) as NSArray,
      "mtu": (args["mtu"] as? Int ?? 0) as NSNumber,
    ]
    manager.start(options: options) { error in
      if let error {
        result(self.flutterError(for: error))
        return
      }
      result(true)
    }
  }

  private func flutterError(for error: Error) -> FlutterError {
    if let tunnelError = error as? SangforTunnelError {
      return FlutterError(
        code: tunnelError.code,
        message: tunnelError.description,
        details: nil
      )
    }
    return FlutterError(code: "tunnelStartFailed", message: error.localizedDescription, details: nil)
  }

  /// Forwards a getStats control message to the running provider.
  private func requestStats(result: @escaping FlutterResult) {
    guard let tunnelManager else {
      result(nil)
      return
    }
    struct StatsRequest: Codable {
      var action: String
    }
    let encoder = JSONEncoder()
    guard let message = try? encoder.encode(StatsRequest(action: "getStats")) else {
      result(nil)
      return
    }
    tunnelManager.sendProviderMessage(message) { data, error in
      if let error {
        result(self.flutterError(for: error))
        return
      }
      guard
        let data,
        let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        result(nil)
        return
      }
      result(stats)
    }
  }
}

/// Streams NEVPNStatus changes to Dart.
extension FlutterSangforPlugin: FlutterStreamHandler {
  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    statusSink = events
    if let tunnelManager {
      events(tunnelManager.status.sangforName)
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    statusSink = nil
    return nil
  }
}
