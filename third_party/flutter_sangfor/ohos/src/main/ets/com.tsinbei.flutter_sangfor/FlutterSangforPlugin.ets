import {
  FlutterPlugin,
  FlutterPluginBinding
} from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodChannel, {
  MethodCallHandler,
  MethodResult
} from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { startFdListener, pollFd, stopFdListener } from 'libflutter_sangfor.so';
import {
  SangforVpnConfig,
  VPN_EXTENSION_ABILITY_NAME,
  vpnSocketPath,
  writeVpnConfig
} from './VpnBridge';

/// Method-channel glue mirroring the Android plugin: the Dart side drives
/// `vpnStart` / `vpnStop`; the plugin starts the host-declared
/// VpnExtensionAbility, then polls the SCM_RIGHTS hand-off socket until the
/// extension delivers the TUN descriptor.
export class FlutterSangforPlugin implements FlutterPlugin, MethodCallHandler {
  private static readonly CHANNEL_NAME = 'flutter_sangfor';
  private static readonly SERVICE_CHANNEL_NAME = 'flutter_sangfor/service';
  // First start includes the system authorization dialog; give users time.
  private static readonly START_TIMEOUT_MS = 120000;
  private static readonly POLL_INTERVAL_MS = 100;

  private channel: MethodChannel | null = null;
  private serviceChannel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private bundleName = '';
  private state = 'disconnected';

  getUniqueClassName(): string {
    return 'FlutterSangforPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    try {
      this.bundleName =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).name;
    } catch (e) {
      this.bundleName = '';
    }
    this.channel = new MethodChannel(binding.getBinaryMessenger(), FlutterSangforPlugin.CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.serviceChannel =
      new MethodChannel(binding.getBinaryMessenger(), FlutterSangforPlugin.SERVICE_CHANNEL_NAME);
    this.serviceChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        result.notImplemented();
      }
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    stopFdListener();
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    if (this.serviceChannel != null) {
      this.serviceChannel.setMethodCallHandler(null);
      this.serviceChannel = null;
    }
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'getState':
        result.success(this.state);
        break;
      case 'getCapabilities':
        result.success(this.capabilities());
        break;
      case 'connect':
        result.error(
          'unsupported',
          'The aTrust transport is not implemented on OpenHarmony yet.',
          null);
        break;
      case 'disconnect':
        this.state = 'disconnected';
        result.success(null);
        break;
      case 'vpnPrepare':
        // No pre-grant step exists: the system prompts for authorization
        // when the extension starts for the first time.
        result.success(true);
        break;
      case 'vpnRequestPermission':
        result.success(true);
        break;
      case 'vpnStart':
        this.handleVpnStart(call, result);
        break;
      case 'vpnStop':
        this.handleVpnStop(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private capabilities(): Map<string, Object> {
    const capabilities = new Map<string, Object>();
    capabilities.set('platform', 'ohos');
    capabilities.set('supportsVpn', true);
    capabilities.set('supportsTun', true);
    capabilities.set('supportsSocks5', true);
    capabilities.set('supportedAuthTypes', new Array<string>());
    return capabilities;
  }

  private async handleVpnStart(call: MethodCall, result: MethodResult): Promise<void> {
    const context = this.context;
    if (context == null || this.bundleName.length === 0) {
      result.error('no_context', 'The plugin is not attached.', null);
      return;
    }
    const socketPath = vpnSocketPath(context);
    const config: SangforVpnConfig = {
      socketPath: socketPath,
      address: (call.argument('address') as string) ?? '10.0.0.2',
      prefixLength: (call.argument('prefixLength') as number) ?? 32,
      routes: (call.argument('routes') as string[]) ?? new Array<string>(),
      dnsServers: (call.argument('dnsServers') as string[]) ?? new Array<string>(),
      searchDomains: (call.argument('searchDomains') as string[]) ?? new Array<string>(),
      mtu: (call.argument('mtu') as number) ?? 0,
      blockedApplications: (call.argument('blockedApplications') as string[]) ?? new Array<string>(),
    };
    try {
      writeVpnConfig(context, config);
    } catch (e) {
      result.error('vpn_config_failed', 'Could not write the VPN config file.', null);
      return;
    }
    if (!startFdListener(socketPath)) {
      result.error('vpn_listener_failed', 'Could not bind the fd hand-off socket.', null);
      return;
    }
    const want: Want = {
      bundleName: this.bundleName,
      abilityName: VPN_EXTENSION_ABILITY_NAME,
    };
    try {
      await vpnExtension.startVpnExtensionAbility(want);
    } catch (e) {
      const error = e as BusinessError;
      stopFdListener();
      result.error(
        'vpn_start_failed',
        `startVpnExtensionAbility failed: ${error.code} ${error.message}`,
        null);
      return;
    }
    const deadline = Date.now() + FlutterSangforPlugin.START_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const fd = pollFd();
      if (fd >= 0) {
        this.state = 'connected';
        result.success(fd);
        return;
      }
      await FlutterSangforPlugin.delay(FlutterSangforPlugin.POLL_INTERVAL_MS);
    }
    stopFdListener();
    result.error(
      'vpn_start_failed',
      'The VPN extension did not hand off a TUN descriptor (authorization denied or timeout).',
      null);
  }

  private async handleVpnStop(result: MethodResult): Promise<void> {
    stopFdListener();
    if (this.bundleName.length > 0) {
      const want: Want = {
        bundleName: this.bundleName,
        abilityName: VPN_EXTENSION_ABILITY_NAME,
      };
      try {
        await vpnExtension.stopVpnExtensionAbility(want);
      } catch (e) {
        // Not started or already stopped; nothing to do.
      }
    }
    this.state = 'disconnected';
    result.success(null);
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }
}
