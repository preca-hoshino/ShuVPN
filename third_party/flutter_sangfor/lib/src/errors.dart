import 'dart:async';

enum SangforErrorCode {
  invalidOptions,
  unsupported,
  authenticationFailed,
  mfaRequired,
  sessionExpired,
  network,
  protocol,
  cancelled,
  timeout,
  platform,
  tunnelFailed,
  unknown,
}

class SangforException implements Exception {
  const SangforException(
    this.code,
    this.message, {
    this.cause,
    this.stackTrace,
  });

  final SangforErrorCode code;
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'SangforException($code): $message';
}

class SangforCancellationToken {
  SangforCancellationToken();

  final Completer<Object?> _completer = Completer<Object?>();

  bool get isCancelled => _completer.isCompleted;

  Future<Object?> get whenCancelled => _completer.future;

  void cancel([Object? reason]) {
    if (!isCancelled) _completer.complete(reason);
  }

  Future<T> race<T>(Future<T> operation) async {
    if (isCancelled) {
      throw SangforException(
        SangforErrorCode.cancelled,
        'The operation was cancelled',
      );
    }
    return Future.any<T>(<Future<T>>[
      operation,
      whenCancelled.then<T>((_) => throw SangforException(
            SangforErrorCode.cancelled,
            'The operation was cancelled',
          )),
    ]);
  }
}
