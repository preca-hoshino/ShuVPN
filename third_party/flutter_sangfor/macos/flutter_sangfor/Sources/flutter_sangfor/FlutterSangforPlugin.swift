import Cocoa
import FlutterMacOS

public class FlutterSangforPlugin: NSObject, FlutterPlugin {
  private var state = "disconnected"
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_sangfor", binaryMessenger: registrar.messenger)
    let instance = FlutterSangforPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getState":
      result(state)
    case "getCapabilities":
      result([
        "platform": "macos",
        "supportsVpn": false,
        "supportsTun": true,
        "supportsSocks5": true,
        "supportedAuthTypes": []
      ])
    case "disconnect":
      state = "disconnected"
      result(nil)
    case "connect":
      result(FlutterError(code: "unsupported", message: "The aTrust transport is not implemented on macOS yet.", details: nil))
    case "vpnStart", "vpnStop", "vpnPrepare", "vpnRequestPermission":
      // The macOS TUN (utun) is driven entirely from Dart via FFI; no
      // method-channel action is needed.
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
