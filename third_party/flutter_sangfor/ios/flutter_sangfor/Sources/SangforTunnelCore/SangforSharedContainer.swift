import Foundation

/// Helpers for the App Group shared container used by the Runner and the
/// packet tunnel extension to exchange durable, non-secret state.
public enum SangforSharedContainer {
  /// Standard layout inside the shared container.
  public enum Path {
    public static let configuration = "configuration"
    public static let session = "session"
    public static let runtime = "runtime"
    public static let logs = "logs"
    public static let configFileName = "vpn-config.json"
  }

  /// Returns the shared container URL for [appGroupIdentifier], or `nil`
  /// when the group is not configured or not accessible.
  public static func containerURL(
    for appGroupIdentifier: String?
  ) -> URL? {
    guard
      let appGroupIdentifier,
      !appGroupIdentifier.isEmpty
    else {
      return nil
    }
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )
  }

  /// Writes JSON [data] to `configuration/vpn-config.json`, creating
  /// intermediate directories. Uses atomic replacement.
  public static func writeConfiguration(
    _ data: Data,
    appGroupIdentifier: String?
  ) throws {
    let url = try configurationURL(appGroupIdentifier)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
  }

  /// Reads the previously written configuration JSON, if any.
  public static func readConfiguration(
    appGroupIdentifier: String?
  ) -> Data? {
    guard let url = try? configurationURL(appGroupIdentifier) else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func configurationURL(
    _ appGroupIdentifier: String?
  ) throws -> URL {
    guard
      let base = containerURL(for: appGroupIdentifier)
    else {
      throw CocoaError(
        .fileNoSuchFile,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The App Group \(appGroupIdentifier ?? "") is unavailable."
        ]
      )
    }
    return base
      .appendingPathComponent(Path.configuration)
      .appendingPathComponent(Path.configFileName)
  }
}
