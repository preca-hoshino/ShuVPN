import 'models.dart';

enum SangforConnectionEventType {
  stateChanged,
  authenticationRequired,
  resourcesLoaded,
  tunnelEstablished,
  error,
}

class SangforConnectionEvent {
  const SangforConnectionEvent({
    required this.type,
    required this.state,
    required this.timestamp,
    this.message,
    this.errorCode,
  });

  final SangforConnectionEventType type;
  final SangforConnectionState state;
  final DateTime timestamp;
  final String? message;
  final String? errorCode;
}
