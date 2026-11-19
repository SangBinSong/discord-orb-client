import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/orb_error.dart';
import 'https_validator.dart';

/// HTTPS-enforcing [http.Client] wrapper with manual redirect validation and
/// strict TLS certificate verification.
class OrbHttpClient extends http.BaseClient {
  OrbHttpClient({
    http.Client? inner,
    this.maxRedirects = 5,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _inner = inner ?? _createSecureIoClient();

  static const Set<int> _redirectStatusCodes = <int>{
    HttpStatus.movedPermanently, // 301
    HttpStatus.found, // 302
    HttpStatus.seeOther, // 303
    HttpStatus.temporaryRedirect, // 307
    HttpStatus.permanentRedirect, // 308
  };

  final http.Client _inner;
  final int maxRedirects;
  final Duration requestTimeout;
  bool _closed = false;

  /// Creates the default `dart:io` client that never bypasses invalid TLS certs.
  static http.Client _createSecureIoClient() {
    final ioClient = createStrictIoHttpClient();
    return IOClient(ioClient);
  }

  /// Exposes a strictly configured [HttpClient] with `badCertificateCallback`
  /// rejecting all invalid certificates.
  static HttpClient createStrictIoHttpClient() {
    final client = HttpClient();
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => false;
    return client;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw StateError('OrbHttpClient has already been closed.');
    }

    HttpsValidator.validateRequestUri(request.url);

    // Buffer body bytes up front so 307/308 redirects can safely replay the body
    // if needed, and ensure automatic redirect following is always disabled.
    final Uint8List? initialBodyBytes =
        request is http.Request ? request.bodyBytes : null;

    var currentMethod = request.method;
    var currentUri = request.url;
    var currentHeaders = Map<String, String>.from(request.headers);
    var currentBodyBytes = initialBodyBytes;
    var isInitialAttempt = true;

    for (var redirectCount = 0;
        redirectCount <= maxRedirects;
        redirectCount++) {
      final http.BaseRequest outgoing;
      if (isInitialAttempt) {
        request.followRedirects = false;
        outgoing = request;
        isInitialAttempt = false;
      } else {
        final nextReq = http.Request(currentMethod, currentUri)
          ..followRedirects = false
          ..headers.addAll(currentHeaders);
        if (currentBodyBytes != null && currentMethod != 'GET') {
          nextReq.bodyBytes = currentBodyBytes;
        }
        outgoing = nextReq;
      }

      final http.StreamedResponse response;
      try {
        response = await _inner.send(outgoing).timeout(requestTimeout);
      } on OrbException {
        rethrow;
      } on TimeoutException {
        throw const OrbException(
          code: 'request_timeout',
          message: 'Request to backend timed out.',
          state: OrbPreviewState.networkError,
        );
      } on HandshakeException catch (error) {
        throw OrbException(
          code: 'tls_handshake_failed',
          message: 'TLS verification failed: ${error.message}',
          state: OrbPreviewState.networkError,
        );
      } on TlsException catch (error) {
        throw OrbException(
          code: 'tls_error',
          message: 'TLS error: ${error.message}',
          state: OrbPreviewState.networkError,
        );
      } on SocketException catch (error) {
        throw OrbException(
          code: 'network_error',
          message: 'Network error: ${error.message}',
          state: OrbPreviewState.networkError,
        );
      } on http.ClientException catch (error) {
        throw OrbException(
          code: 'network_error',
          message: 'HTTP client error: ${error.message}',
          state: OrbPreviewState.networkError,
        );
      }

      if (!_redirectStatusCodes.contains(response.statusCode)) {
        return response;
      }

      await _drainSafely(response);

      final location = _findHeaderCaseInsensitive(response.headers, 'location');
      if (location == null || location.trim().isEmpty) {
        throw OrbException(
          code: 'invalid_redirect',
          message:
              'Redirect status ${response.statusCode} missing Location header.',
          state: OrbPreviewState.networkError,
          statusCode: response.statusCode,
        );
      }

      if (redirectCount == maxRedirects) {
        throw const OrbException(
          code: 'too_many_redirects',
          message: 'Exceeded maximum redirect limit.',
          state: OrbPreviewState.networkError,
        );
      }

      // Validate target before building the next request or forwarding headers.
      final nextUri = HttpsValidator.validateRedirectUri(currentUri, location);

      if (!HttpsValidator.isSameOrigin(currentUri, nextUri)) {
        _stripSensitiveHeaders(currentHeaders);
      }

      if (response.statusCode == HttpStatus.movedPermanently ||
          response.statusCode == HttpStatus.found ||
          response.statusCode == HttpStatus.seeOther) {
        currentMethod = 'GET';
        currentBodyBytes = null;
        _removeHeaderCaseInsensitive(currentHeaders, 'content-length');
        _removeHeaderCaseInsensitive(currentHeaders, 'content-type');
      }

      currentUri = nextUri;
    }

    throw const OrbException(
      code: 'too_many_redirects',
      message: 'Exceeded maximum redirect limit.',
      state: OrbPreviewState.networkError,
    );
  }

  static Future<void> _drainSafely(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>();
    } catch (_) {
      // Ignore stream drain errors on abandoned redirect bodies.
    }
  }

  static String? _findHeaderCaseInsensitive(
    Map<String, String> headers,
    String targetName,
  ) {
    final lowerTarget = targetName.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lowerTarget) {
        return entry.value;
      }
    }
    return null;
  }

  static void _removeHeaderCaseInsensitive(
    Map<String, String> headers,
    String targetName,
  ) {
    final lowerTarget = targetName.toLowerCase();
    headers.removeWhere((key, _) => key.toLowerCase() == lowerTarget);
  }

  static void _stripSensitiveHeaders(Map<String, String> headers) {
    _removeHeaderCaseInsensitive(headers, 'authorization');
    _removeHeaderCaseInsensitive(headers, 'cookie');
  }

  /// Parses optional `code` and `detail`/`message` fields from a JSON error
  /// response body.
  static ({String? code, String? detail}) parseErrorPayload(String body) {
    if (body.trim().isEmpty) {
      return (code: null, detail: null);
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['code'] as String?;
        final detail =
            (decoded['detail'] ?? decoded['message'] ?? decoded['error'])
                as String?;
        return (code: code, detail: detail);
      }
    } catch (_) {
      // Ignore non-JSON error payloads.
    }
    return (code: null, detail: null);
  }

  /// Parses an HTTP `Retry-After` header (integer seconds or HTTP date).
  static Duration? parseRetryAfter(Map<String, String> headers) {
    final raw = _findHeaderCaseInsensitive(headers, 'retry-after')?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final seconds = int.tryParse(raw);
    if (seconds != null) {
      return Duration(seconds: seconds < 0 ? 0 : seconds);
    }
    try {
      final retryAt = HttpDate.parse(raw).toUtc();
      final diff = retryAt.difference(DateTime.now().toUtc());
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }

  /// Maps a non-2xx backend HTTP [response] to a typed [OrbException].
  static OrbException mapHttpError(http.Response response) {
    final parsed = parseErrorPayload(response.body);
    switch (response.statusCode) {
      case HttpStatus.unauthorized:
        return OrbException(
          code: parsed.code ?? 'session_expired',
          message: parsed.detail ?? 'Authentication session expired.',
          state: OrbPreviewState.sessionExpired,
          statusCode: response.statusCode,
        );
      case HttpStatus.forbidden:
        return OrbException(
          code: parsed.code ?? 'access_denied',
          message: parsed.detail ?? 'Access to this channel was denied.',
          state: OrbPreviewState.accessDenied,
          statusCode: response.statusCode,
        );
      case HttpStatus.serviceUnavailable:
        return OrbException(
          code: parsed.code ?? 'bot_unavailable',
          message: parsed.detail ?? 'Discord bot preview service is unavailable.',
          state: OrbPreviewState.botUnavailable,
          statusCode: response.statusCode,
        );
      case HttpStatus.tooManyRequests:
        return OrbException(
          code: parsed.code ?? 'rate_limited',
          message: parsed.detail ?? 'Too many requests; please retry shortly.',
          state: OrbPreviewState.rateLimited,
          retryAfter: parseRetryAfter(response.headers),
          statusCode: response.statusCode,
        );
      default:
        return OrbException(
          code: parsed.code ?? 'http_${response.statusCode}',
          message:
              parsed.detail ?? 'Backend returned HTTP ${response.statusCode}.',
          state: OrbPreviewState.networkError,
          statusCode: response.statusCode,
        );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _inner.close();
  }
}
