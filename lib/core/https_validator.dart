import '../models/orb_error.dart';

/// Enforces Discord Orb's HTTPS-only transport and redirect security policy.
abstract final class HttpsValidator {
  static const Set<String> _disallowedBackendHosts = <String>{
    '127.0.0.1',
    '::1',
  };

  /// Validates and normalizes a user-configured backend base URL.
  ///
  /// Only `https://` URLs with a valid host and no userinfo, query, fragment,
  /// or loopback-only host (`127.0.0.1`) are accepted.
  static Uri validateBackendBaseUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const OrbException(
        code: 'invalid_backend_url',
        message: 'Backend URL must not be empty.',
        state: OrbPreviewState.networkError,
      );
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      throw const OrbException(
        code: 'invalid_backend_url',
        message: 'Backend URL is malformed.',
        state: OrbPreviewState.networkError,
      );
    }

    _validateHttpsUri(uri, allowQueryAndFragment: false);

    final normalizedPath = _stripTrailingSlashes(uri.path);
    return uri.replace(
      scheme: 'https',
      host: uri.host.toLowerCase(),
      path: normalizedPath,
      query: null,
      fragment: null,
    );
  }

  /// Validates an outbound backend API/auth request [Uri] prior to sending.
  static Uri validateRequestUri(Uri uri) {
    _validateHttpsUri(uri, allowQueryAndFragment: true);
    return uri;
  }

  /// Validates a redirect `Location` target against [currentUri].
  ///
  /// Plaintext `http://` downgrade redirects and other non-HTTPS schemes are
  /// rejected immediately so no credentials are sent to the redirect target.
  static Uri validateRedirectUri(Uri currentUri, String locationHeader) {
    final trimmedLocation = locationHeader.trim();
    if (trimmedLocation.isEmpty) {
      throw const OrbException(
        code: 'invalid_redirect',
        message: 'Redirect response contained an empty Location header.',
        state: OrbPreviewState.networkError,
      );
    }

    final parsedLocation = Uri.tryParse(trimmedLocation);
    if (parsedLocation == null) {
      throw const OrbException(
        code: 'invalid_redirect',
        message: 'Redirect Location header is malformed.',
        state: OrbPreviewState.networkError,
      );
    }

    final resolved = currentUri.resolveUri(parsedLocation);
    if (resolved.scheme.toLowerCase() == 'http') {
      throw const OrbException(
        code: 'https_downgrade_redirect',
        message: 'Blocked insecure http:// downgrade redirect.',
        state: OrbPreviewState.networkError,
      );
    }

    _validateHttpsUri(resolved, allowQueryAndFragment: true);
    return resolved;
  }

  /// Resolves an API or OAuth [endpointPath] against a validated
  /// [backendBaseUrl] and validates the resulting HTTPS URI.
  static Uri resolveEndpoint(
    String backendBaseUrl,
    String endpointPath, {
    Map<String, String>? queryParameters,
  }) {
    final baseUri = validateBackendBaseUrl(backendBaseUrl);
    final normalizedEndpoint =
        endpointPath.startsWith('/') ? endpointPath : '/$endpointPath';
    final fullPath = baseUri.path.isEmpty
        ? normalizedEndpoint
        : '${baseUri.path}$normalizedEndpoint';
    final resolved = baseUri.replace(
      path: fullPath,
      queryParameters:
          queryParameters != null && queryParameters.isNotEmpty
              ? queryParameters
              : null,
    );
    return validateRequestUri(resolved);
  }

  /// Returns `true` when [a] and [b] share the exact same scheme, host, and port.
  static bool isSameOrigin(Uri a, Uri b) {
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        a.port == b.port;
  }

  static void _validateHttpsUri(
    Uri uri, {
    required bool allowQueryAndFragment,
  }) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http') {
      throw const OrbException(
        code: 'insecure_http_scheme',
        message: 'Plaintext http:// URLs are not allowed; use https://.',
        state: OrbPreviewState.networkError,
      );
    }
    if (scheme != 'https') {
      throw OrbException(
        code: 'unsupported_scheme',
        message: 'Unsupported URL scheme "$scheme"; only https:// is allowed.',
        state: OrbPreviewState.networkError,
      );
    }

    if (!uri.hasAuthority || uri.host.isEmpty) {
      throw const OrbException(
        code: 'missing_host',
        message: 'HTTPS URL must include a valid host.',
        state: OrbPreviewState.networkError,
      );
    }

    if (uri.userInfo.isNotEmpty) {
      throw const OrbException(
        code: 'userinfo_not_allowed',
        message: 'URLs containing userinfo credentials are not allowed.',
        state: OrbPreviewState.networkError,
      );
    }

    final hostLower = uri.host.toLowerCase();
    if (_disallowedBackendHosts.contains(hostLower)) {
      throw const OrbException(
        code: 'loopback_backend_not_allowed',
        message:
            '127.0.0.1 is reserved for local OAuth callback listeners and cannot be used as a backend URL.',
        state: OrbPreviewState.networkError,
      );
    }

    if (!allowQueryAndFragment && (uri.hasQuery || uri.hasFragment)) {
      throw const OrbException(
        code: 'invalid_backend_url',
        message: 'Backend base URL must not contain query parameters or fragments.',
        state: OrbPreviewState.networkError,
      );
    }
  }

  static String _stripTrailingSlashes(String path) {
    var result = path;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
