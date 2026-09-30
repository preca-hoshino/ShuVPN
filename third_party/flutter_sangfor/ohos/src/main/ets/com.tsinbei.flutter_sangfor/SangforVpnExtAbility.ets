import { VpnExtensionAbility, vpnExtension, connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { SangforVpnConfig, readVpnConfig, vpnSocketPath } from './VpnBridge';
import { sendFd } from 'libflutter_sangfor.so';

const TAG = 'flutter_sangfor';
const SEND_FD_TIMEOUT_MS = 60000;
const MIN_MTU = 576;
const MAX_MTU = 1500;
const DEFAULT_MTU = 1400;
// connection.NetAddress.family is a plain number in the OHOS SDK (the
// FamilyType enum only exists for DNS queries): 1 = IPv4, 2 = IPv6.
const NET_FAMILY_IPV4 = 1;
const NET_FAMILY_IPV6 = 2;

/// VpnExtensionAbility base that establishes the system VPN and hands the
/// TUN descriptor to the app process. Declare a trivial subclass of this in
/// your entry module (see ohos/templates/) and register it in module.json5
/// with "type": "vpn" under the ability name
/// `SangforVpnExtAbility`.
///
/// The extension runs in its own process: the descriptor is transferred to
/// the app process over an AF_UNIX socket with SCM_RIGHTS
/// (libflutter_sangfor.so), where Dart reads and writes it directly through
/// FFI - the same shape as the Android VpnService adapter.
export class SangforVpnExtAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd = -1;

  onCreate(want: Want): void {
    const config = readVpnConfig(this.context);
    if (config == null) {
      console.error(TAG, 'vpn extension: config file is missing');
      return;
    }
    this.bringUp(config);
  }

  onDestroy(): void {
    const activeConnection = this.vpnConnection;
    this.vpnConnection = null;
    if (this.tunFd >= 0) {
      // The app process owns a duplicate received via SCM_RIGHTS; dropping
      // the local reference does not tear the interface down.
      try {
        fileIo.closeSync(this.tunFd);
      } catch (e) {
        // Already closed; nothing to do.
      }
      this.tunFd = -1;
    }
    if (activeConnection != null) {
      activeConnection.destroy().catch((error: BusinessError): void => {
        console.error(TAG, `vpn destroy failed: ${error.code} ${error.message}`);
      });
    }
  }

  private async bringUp(config: SangforVpnConfig): Promise<void> {
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      const vpnConfig = this.buildConfig(config);
      this.tunFd = await this.vpnConnection.create(vpnConfig);
      const socketPath = config.socketPath.length > 0 ? config.socketPath : vpnSocketPath(this.context);
      const sent = sendFd(socketPath, this.tunFd, SEND_FD_TIMEOUT_MS);
      console.info(TAG, `vpn extension: tun fd ${this.tunFd}, hand-off ${sent ? 'ok' : 'failed'}`);
    } catch (e) {
      const error = e as BusinessError;
      console.error(TAG, `vpn extension failed: ${error.code} ${error.message}`);
    }
  }

  private buildConfig(config: SangforVpnConfig): vpnExtension.VpnConfig {
    const family = SangforVpnExtAbility.netFamilyFor(config.address);
    const addresses: connection.LinkAddress[] = [{
      address: { address: config.address, family: family },
      prefixLength: config.prefixLength,
    }];
    const routes: connection.RouteInfo[] = [];
    for (const route of config.routes) {
      const parsed = SangforVpnExtAbility.parseRoute(route);
      if (parsed != null) {
        routes.push(parsed);
      }
    }
    const mtu = config.mtu >= MIN_MTU && config.mtu <= MAX_MTU ? config.mtu : DEFAULT_MTU;
    return {
      addresses: addresses,
      routes: routes,
      dnsAddresses: config.dnsServers,
      searchDomains: config.searchDomains,
      mtu: mtu,
      isIPv4Accepted: family === NET_FAMILY_IPV4,
      isIPv6Accepted: family === NET_FAMILY_IPV6,
      blockedApplications: config.blockedApplications,
    };
  }

  private static netFamilyFor(address: string): number {
    return address.indexOf(':') >= 0 ? NET_FAMILY_IPV6 : NET_FAMILY_IPV4;
  }

  private static parseRoute(route: string): connection.RouteInfo | null {
    const separator = route.lastIndexOf('/');
    if (separator <= 0) {
      return null;
    }
    const address = route.substring(0, separator);
    const prefixLength = Number.parseInt(route.substring(separator + 1));
    if (Number.isNaN(prefixLength)) {
      return null;
    }
    const family = SangforVpnExtAbility.netFamilyFor(address);
    const destination: connection.LinkAddress = {
      address: { address: address, family: family },
      prefixLength: prefixLength,
    };
    return {
      interface: 'vpn-tun',
      destination: destination,
      // RouteInfo.gateway is mandatory in the SDK type even when
      // hasGateway is false; supply the unspecified address.
      gateway: {
        address: family === NET_FAMILY_IPV6 ? '::' : '0.0.0.0',
        family: family,
      },
      hasGateway: false,
      isDefaultRoute: route === '0.0.0.0/0' || route === '::/0',
    };
  }
}
