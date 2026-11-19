/// UI and repository states for the Discord Orb message preview panel.
enum OrbPreviewState {
  idle,
  loading,
  loaded,
  emptyChannel,
  sessionExpired,
  accessDenied,
  botUnavailable,
  rateLimited,
  networkError,
}

/// Typed exception surfaced by repositories and mapped to [OrbPreviewState].
class OrbException implements Exception {
  const OrbException({
    required this.code,
    required this.message,
    required this.state,
    this.retryAfter,
    this.statusCode,
  });

  final String code;
  final String message;
  final OrbPreviewState state;
  final Duration? retryAfter;
  final int? statusCode;

  @override
  String toString() =>
      'OrbException(code: $code, state: ${state.name}, statusCode: $statusCode, retryAfter: $retryAfter, message: $message)';
}
