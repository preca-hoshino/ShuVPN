import 'models.dart';

/// Immutable input for the aTrust authentication transport.
class SangforAuthRequest {
  const SangforAuthRequest({
    required this.server,
    required this.username,
    required this.password,
    this.loginDomain,
    this.authType = SangforAuthType.password,
  });

  final Uri server;
  final String username;
  final String password;
  final String? loginDomain;
  final SangforAuthType authType;

  /// Resolves the authentication endpoint below the supplied server root.
  Uri get endpoint {
    final rootPath =
        server.path.endsWith('/') ? server.path : '${server.path}/';
    return server
        .replace(
          path: rootPath,
          query: '',
          fragment: '',
        )
        .resolve(authType.value);
  }

  /// Produces the transport-neutral request fields.
  Map<String, String> get fields => <String, String>{
        'username': username,
        'password': password,
        'authType': authType.value,
        if (loginDomain != null) 'loginDomain': loginDomain!,
      };
}

/// Minimal normalized result returned by an authentication transport.
class SangforAuthResponse {
  const SangforAuthResponse({
    required this.authenticated,
    this.sessionId,
    this.message,
  });

  factory SangforAuthResponse.fromMap(Map<String, Object?> map) {
    return SangforAuthResponse(
      authenticated: map['authenticated'] as bool? ?? false,
      sessionId: map['sessionId'] as String?,
      message: map['message'] as String?,
    );
  }

  final bool authenticated;
  final String? sessionId;
  final String? message;
}

/// Boundary for protocol implementations that run on each native platform.
abstract interface class SangforAuthTransport {
  Future<SangforAuthResponse> authenticate(SangforAuthRequest request);
}
