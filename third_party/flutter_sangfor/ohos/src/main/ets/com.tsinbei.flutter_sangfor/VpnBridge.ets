import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

/// Ability name the plugin starts/stops; host apps declare an extension
/// ability with this name (see ohos/templates/).
export const VPN_EXTENSION_ABILITY_NAME = 'SangforVpnExtAbility';
export const VPN_CONFIG_FILE_NAME = 'flutter_sangfor_vpn.json';
export const VPN_SOCKET_FILE_NAME = 'flutter_sangfor_vpn.sock';

/// Hand-off contract between the app process and the VPN extension process.
/// Written to the app sandbox before the extension starts; the extension
/// reads it in onCreate (want.parameters is only delivered reliably from
/// API 22 onward, so the sandbox file is the source of truth).
export interface SangforVpnConfig {
  socketPath: string;
  address: string;
  prefixLength: number;
  routes: string[];
  dnsServers: string[];
  searchDomains: string[];
  mtu: number;
  blockedApplications: string[];
}

export function vpnConfigPath(context: common.Context): string {
  return context.filesDir + '/' + VPN_CONFIG_FILE_NAME;
}

export function vpnSocketPath(context: common.Context): string {
  return context.filesDir + '/' + VPN_SOCKET_FILE_NAME;
}

export function writeVpnConfig(context: common.Context, config: SangforVpnConfig): void {
  const file = fileIo.openSync(
    vpnConfigPath(context),
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    const encoder = new util.TextEncoder();
    const bytes = encoder.encodeInto(JSON.stringify(config));
    fileIo.writeSync(file.fd, bytes.buffer);
  } finally {
    fileIo.closeSync(file);
  }
}

export function readVpnConfig(context: common.Context): SangforVpnConfig | null {
  const path = vpnConfigPath(context);
  if (!fileIo.accessSync(path)) {
    return null;
  }
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const size = fileIo.statSync(path).size;
    if (size <= 0) {
      return null;
    }
    const buffer = new ArrayBuffer(size);
    fileIo.readSync(file.fd, buffer);
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(new Uint8Array(buffer));
    return JSON.parse(text) as SangforVpnConfig;
  } catch (e) {
    return null;
  } finally {
    fileIo.closeSync(file);
  }
}
