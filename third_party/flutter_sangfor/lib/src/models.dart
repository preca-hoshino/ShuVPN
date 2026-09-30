/// Authentication mechanisms exposed by aTrust deployments.
enum SangforAuthType {
  password('auth/psw'),
  cas('auth/cas'),
  sms('auth/smsCheckCode');

  const SangforAuthType(this.value);

  final String value;
}

/// Lifecycle state of the connection.
enum SangforConnectionState {
  disconnected,
  connecting,
  authenticated,
  connected,
  disconnecting,
  error;

  static SangforConnectionState fromValue(String? value) =>
      SangforConnectionState.values.firstWhere(
        (state) => state.name == value,
        orElse: () => SangforConnectionState.disconnected,
      );
}

/// Native networking capabilities exposed by the current platform adapter.
class SangforPlatformCapabilities {
  const SangforPlatformCapabilities({
    required this.platform,
    this.supportsVpn = false,
    this.supportsTun = false,
    this.supportsSocks5 = false,
    this.supportedAuthTypes = const <SangforAuthType>[],
  });

  factory SangforPlatformCapabilities.fromMap(Map<String, Object?> map) {
    final authTypes = (map['supportedAuthTypes'] as List<Object?>? ?? const [])
        .whereType<String>()
        .map((value) => SangforAuthType.values.firstWhere(
              (type) => type.value == value,
              orElse: () => SangforAuthType.password,
            ))
        .toSet()
        .toList(growable: false);
    return SangforPlatformCapabilities(
      platform: map['platform'] as String? ?? 'unknown',
      supportsVpn: map['supportsVpn'] as bool? ?? false,
      supportsTun: map['supportsTun'] as bool? ?? false,
      supportsSocks5: map['supportsSocks5'] as bool? ?? false,
      supportedAuthTypes: authTypes,
    );
  }

  final String platform;
  final bool supportsVpn;
  final bool supportsTun;
  final bool supportsSocks5;
  final List<SangforAuthType> supportedAuthTypes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SangforPlatformCapabilities &&
          other.platform == platform &&
          other.supportsVpn == supportsVpn &&
          other.supportsTun == supportsTun &&
          other.supportsSocks5 == supportsSocks5 &&
          _sameAuthTypes(other.supportedAuthTypes, supportedAuthTypes);

  @override
  int get hashCode => Object.hash(
        platform,
        supportsVpn,
        supportsTun,
        supportsSocks5,
        Object.hashAll(supportedAuthTypes),
      );

  static bool _sameAuthTypes(
    List<SangforAuthType> left,
    List<SangforAuthType> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

/// Result returned after a successful connection setup.
class SangforSession {
  const SangforSession({
    required this.state,
    this.virtualAddress,
    this.dnsServers = const <String>[],
    this.dryRun = false,
  });

  factory SangforSession.fromMap(Map<String, Object?> map) => SangforSession(
        state: SangforConnectionState.fromValue(map['state'] as String?),
        virtualAddress: map['virtualAddress'] as String?,
        dnsServers: (map['dnsServers'] as List<Object?>? ?? const <Object?>[])
            .whereType<String>()
            .toList(growable: false),
        dryRun: map['dryRun'] as bool? ?? false,
      );

  final SangforConnectionState state;
  final String? virtualAddress;
  final List<String> dnsServers;
  final bool dryRun;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SangforSession &&
          other.state == state &&
          other.virtualAddress == virtualAddress &&
          other.dryRun == dryRun &&
          _sameStrings(other.dnsServers, dnsServers);

  @override
  int get hashCode => Object.hash(
        state,
        virtualAddress,
        dryRun,
        Object.hashAll(dnsServers),
      );

  static bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
