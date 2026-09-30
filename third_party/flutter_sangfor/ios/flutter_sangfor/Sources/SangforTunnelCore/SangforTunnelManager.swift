import Foundation
import NetworkExtension

/// Stable string names mirrored by the Dart `IosVpnStatus` enum.
extension NEVPNStatus {
  /// Machine-readable name matching `NEVPNStatus` case names.
  public var sangforName: String {
    switch self {
    case .invalid: "invalid"
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    case .reasserting: "reasserting"
    case .disconnecting: "disconnecting"
    @unknown default: "invalid"
    }
  }
}

/// Errors surfaced by the tunnel manager and translated into method-channel
/// error codes for the Dart side.
public enum SangforTunnelError: Error, CustomStringConvertible, Equatable {
  /// The provider bundle identifier could not be resolved.
  case providerNotConfigured
  /// Saving or loading the VPN configuration failed.
  case managerSaveFailed(String)
  /// Loading existing managers failed.
  case managerLoadFailed(String)
  /// Starting the VPN tunnel failed.
  case tunnelStartFailed(String)
  /// Applying the tunnel network settings failed.
  case networkSettingsFailed(String)

  public var description: String {
    switch self {
    case .providerNotConfigured:
      "The packet tunnel provider extension is not configured for this app."
    case .managerSaveFailed(let detail):
      "Saving the VPN configuration failed: \(detail)"
    case .managerLoadFailed(let detail):
      "Loading existing VPN configurations failed: \(detail)"
    case .tunnelStartFailed(let detail):
      "Starting the VPN tunnel failed: \(detail)"
    case .networkSettingsFailed(let detail):
      "Applying tunnel network settings failed: \(detail)"
    }
  }

  /// Stable machine-readable code mirrored on the Dart side.
  public var code: String {
    switch self {
    case .providerNotConfigured: "providerNotFound"
    case .managerSaveFailed: "managerSaveFailed"
    case .managerLoadFailed: "managerLoadFailed"
    case .tunnelStartFailed: "tunnelStartFailed"
    case .networkSettingsFailed: "networkSettingsFailed"
    }
  }
}

/// Owns the `NETunnelProviderManager` lifecycle for the Runner side: load,
/// create, install, start, stop, remove, and status. The Flutter plugin is a
/// thin adapter over this type; it must never implement manager logic itself.
public final class SangforTunnelManager {
  /// The bundle identifier of the consumer's packet tunnel `.appex` target.
  public let providerBundleIdentifier: String

  /// Optional app group shared with the extension.
  public let appGroupIdentifier: String?

  /// The localized description shown in iOS Settings for the VPN entry.
  public let localizedDescription: String

  /// Opaque server identifier required by `NETunnelProviderProtocol` before
  /// the configuration can be saved. Shown in iOS Settings' VPN entry.
  public let serverAddress: String

  /// The loaded manager, if one has been loaded or installed.
  private(set) public var manager: NETunnelProviderManager?

  private var statusObserver: NSObjectProtocol?

  public init(
    providerBundleIdentifier: String,
    appGroupIdentifier: String? = nil,
    localizedDescription: String = "flutter_sangfor",
    serverAddress: String = "flutter_sangfor"
  ) {
    self.providerBundleIdentifier = providerBundleIdentifier
    self.appGroupIdentifier = appGroupIdentifier
    self.localizedDescription = localizedDescription
    self.serverAddress = serverAddress
  }

  deinit {
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
    }
  }

  /// Returns `true` when [manager] was created by this package and points at
  /// the expected provider extension.
  public static func isSangforManager(
    _ manager: NETunnelProviderManager,
    providerBundleIdentifier: String
  ) -> Bool {
    guard
      let protocolConfiguration = manager.protocolConfiguration
        as? NETunnelProviderProtocol
    else {
      return false
    }
    guard
      protocolConfiguration.providerBundleIdentifier == providerBundleIdentifier
    else {
      return false
    }
    let implementation = protocolConfiguration.providerConfiguration?[
      SangforTunnelConfigurationKeys.implementation
    ] as? String
    return implementation == SangforTunnelConfigurationKeys.implementationValue
  }

  /// Finds this package's manager among all saved VPN managers.
  public static func findSangforManager(
    _ managers: [NETunnelProviderManager],
    providerBundleIdentifier: String
  ) -> NETunnelProviderManager? {
    managers.first {
      isSangforManager($0, providerBundleIdentifier: providerBundleIdentifier)
    }
  }

  /// Loads the existing manager for this provider, or creates and saves a
  /// fresh one. Saving for the first time triggers the system's VPN
  /// permission prompt.
  public func install(completion: @escaping (Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      guard let self else { return }
      if let error {
        completion(
          SangforTunnelError.managerLoadFailed(error.localizedDescription)
        )
        return
      }
      if let existing = Self.findSangforManager(
        managers ?? [],
        providerBundleIdentifier: self.providerBundleIdentifier
      ) {
        self.manager = existing
        self.observeStatus(of: existing)
        completion(nil)
        return
      }
      let manager = NETunnelProviderManager()
      self.configure(manager)
      manager.saveToPreferences { saveError in
        if let saveError {
          completion(
            SangforTunnelError.managerSaveFailed(saveError.localizedDescription)
          )
          return
        }
        // Reload so the system-assigned reference is picked up before start.
        manager.loadFromPreferences { loadError in
          if let loadError {
            completion(
              SangforTunnelError.managerLoadFailed(loadError.localizedDescription)
            )
            return
          }
          self.manager = manager
          self.observeStatus(of: manager)
          completion(nil)
        }
      }
    }
  }

  /// Starts the tunnel, installing the configuration first when needed.
  public func start(
    options: [String: NSObject],
    completion: @escaping (Error?) -> Void
  ) {
    func startLoaded() {
      guard let manager else {
        completion(SangforTunnelError.providerNotConfigured)
        return
      }
      manager.isEnabled = true
      manager.saveToPreferences { saveError in
        if let saveError {
          completion(
            SangforTunnelError.managerSaveFailed(saveError.localizedDescription)
          )
          return
        }
        do {
          try manager.connection.startVPNTunnel(options: options)
          completion(nil)
        } catch {
          completion(
            SangforTunnelError.tunnelStartFailed(error.localizedDescription)
          )
        }
      }
    }

    if manager != nil {
      startLoaded()
      return
    }
    install { error in
      if let error {
        completion(error)
        return
      }
      startLoaded()
    }
  }

  /// Stops the running tunnel, if any.
  public func stop() {
    manager?.connection.stopVPNTunnel()
  }

  /// Removes the saved VPN configuration.
  public func remove(completion: @escaping (Error?) -> Void) {
    guard let manager else {
      completion(nil)
      return
    }
    manager.removeFromPreferences(completionHandler: completion)
  }

  /// Sends a control message to the running provider via
  /// NETunnelProviderSession. Data-plane traffic stays on the loopback
  /// bridge; this is the control-plane channel.
  public func sendProviderMessage(
    _ data: Data,
    completion: @escaping (Data?, Error?) -> Void
  ) {
    guard let session = manager?.connection as? NETunnelProviderSession else {
      completion(
        nil,
        SangforTunnelError.tunnelStartFailed("The tunnel is not running.")
      )
      return
    }
    do {
      try session.sendProviderMessage(data) { responseData in
        completion(responseData, nil)
      }
    } catch {
      completion(nil, error)
    }
  }

  /// The current connection status.
  public var status: NEVPNStatus {
    manager?.connection.status ?? .invalid
  }

  /// Calls [handler] on every status change until the manager is released.
  public func onStatusChange(_ handler: @escaping (NEVPNStatus) -> Void) {
    statusHandler = handler
    if let manager {
      observeStatus(of: manager)
    }
  }

  private var statusHandler: ((NEVPNStatus) -> Void)?

  private func observeStatus(of manager: NETunnelProviderManager) {
    if statusObserver == nil {
      statusObserver = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: nil,
        queue: nil
      ) { [weak self] notification in
        guard
          let connection = notification.object as? NEVPNConnection,
          connection == self?.manager?.connection
        else {
          return
        }
        self?.statusHandler?(connection.status)
      }
    }
    statusHandler?(manager.connection.status)
  }

  private func configure(_ manager: NETunnelProviderManager) {
    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerBundleIdentifier = providerBundleIdentifier
    // iOS rejects configurations without a server address ("Missing server
    // address" on save); the value is opaque for custom providers.
    protocolConfiguration.serverAddress = serverAddress
    let configuration = SangforTunnelConfiguration(address: "0.0.0.0")
    protocolConfiguration.providerConfiguration =
      configuration.providerConfiguration(appGroupIdentifier: appGroupIdentifier)
    manager.protocolConfiguration = protocolConfiguration
    manager.localizedDescription = localizedDescription
    manager.isEnabled = true
  }
}
