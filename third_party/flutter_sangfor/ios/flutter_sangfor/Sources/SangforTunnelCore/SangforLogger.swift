import Foundation
import os

/// Unified os_log wrapper for the Runner and the packet tunnel extension.
/// Never log secrets (passwords, MFA codes, cookies, SIDs, signing keys).
public enum SangforLog {
  public static let subsystem = "com.tsinbei.flutter_sangfor"

  /// Log categories.
  public enum Category {
    public static let manager = "manager"
    public static let provider = "provider"
    public static let network = "network"
    public static let ipc = "ipc"
    public static let routing = "routing"
  }

  private static let managerLogger = Logger(
    subsystem: subsystem,
    category: Category.manager
  )
  private static let providerLogger = Logger(
    subsystem: subsystem,
    category: Category.provider
  )
  private static let networkLogger = Logger(
    subsystem: subsystem,
    category: Category.network
  )
  private static let ipcLogger = Logger(
    subsystem: subsystem,
    category: Category.ipc
  )
  private static let routingLogger = Logger(
    subsystem: subsystem,
    category: Category.routing
  )

  /// Logs a manager-lifecycle message.
  public static func manager(_ message: String) {
    managerLogger.info("\(message, privacy: .public)")
  }

  /// Logs a provider-lifecycle message.
  public static func provider(_ message: String) {
    providerLogger.info("\(message, privacy: .public)")
  }

  /// Logs a network-settings message.
  public static func network(_ message: String) {
    networkLogger.info("\(message, privacy: .public)")
  }

  /// Logs an IPC bridge message.
  public static func ipc(_ message: String) {
    ipcLogger.info("\(message, privacy: .public)")
  }

  /// Logs a routing message.
  public static func routing(_ message: String) {
    routingLogger.info("\(message, privacy: .public)")
  }

  /// Logs a provider-lifecycle error.
  public static func providerError(_ message: String) {
    providerLogger.error("\(message, privacy: .public)")
  }

  /// Logs an IPC bridge error.
  public static func ipcError(_ message: String) {
    ipcLogger.error("\(message, privacy: .public)")
  }

  /// Logs a manager-lifecycle error.
  public static func managerError(_ message: String) {
    managerLogger.error("\(message, privacy: .public)")
  }
}
