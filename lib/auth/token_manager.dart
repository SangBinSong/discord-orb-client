import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/device_identity_store.dart';
import '../core/http_client.dart';
import '../core/https_validator.dart';
import '../models/orb_error.dart';
import '../models/session_models.dart';

/// Manages access/refresh token rotation with single-flight serialization so
/// concurrent 401 or expiry triggers invoke `POST /api/v1/auth/refresh` once.
class TokenManager {
  TokenManager({
    required this._httpClient,
    required this._identityStore,
    DateTime Function()? now,
    this._onSessionInvalidated,
  }) : _now = now ?? DateTime.now;

  final OrbHttpClient _httpClient;
  final DeviceIdentityStore _identityStore;
  final DateTime Function() _now;
  final void Function()? _onSessionInvalidated;

  Completer<OrbSessionTokens>? _refreshCompleter;
  int _sessionEpoch = 0;

  /// Incremented whenever the active session changes (new sign-in, sign-out,
  /// backend switch, or terminal session expiry/revocation).
  int get sessionEpoch => _sessionEpoch;

  /// Loads stored tokens for [backendUrl], purging them if the overall
  /// session lifetime has already expired.
  Future<OrbSessionTokens?> loadStoredSession(String backendUrl) async {
    final tokens = await _identityStore.readSessionTokens(backendUrl);
    if (tokens == null) {
      return null;
    }
    if (tokens.isSessionExpired(now: _now())) {
      await invalidateSession(backendUrl);
      return null;
    }
    return tokens;
  }

  /// Stores freshly issued tokens for a newly authenticated session.
  Future<void> saveNewSession(
    String backendUrl,
    OrbSessionTokens tokens,
  ) async {
    _sessionEpoch++;
    await _identityStore.saveSessionTokens(backendUrl, tokens);
  }

  /// Returns a non-expired access token, refreshing serially if needed.
  Future<String> getValidAccessToken(
    String backendUrl, {
    Duration expirySkew = const Duration(seconds: 30),
  }) async {
    final tokens = await _identityStore.readSessionTokens(backendUrl);
    if (tokens == null) {
      throw const OrbException(
        code: 'session_expired',
        message: 'No active session tokens.',
        state: OrbPreviewState.sessionExpired,
        statusCode: HttpStatus.unauthorized,
      );
    }

    final currentTime = _now();
    if (tokens.isSessionExpired(now: currentTime)) {
      await invalidateSession(backendUrl);
      throw const OrbException(
        code: 'session_expired',
        message: 'Session has expired; please sign in again.',
        state: OrbPreviewState.sessionExpired,
        statusCode: HttpStatus.unauthorized,
      );
    }

    if (tokens.isAccessExpired(now: currentTime.add(expirySkew))) {
      final refreshed = await refreshAccessToken(backendUrl);
      return refreshed.accessToken;
    }

    return tokens.accessToken;
  }

  /// Rotates the session tokens via `POST /api/v1/auth/refresh`, serializing
  /// concurrent callers behind a single [Completer].
  Future<OrbSessionTokens> refreshAccessToken(
    String backendUrl, {
    String? failedAccessToken,
  }) async {
    final inFlight = _refreshCompleter;
    if (inFlight != null) {
      return inFlight.future;
    }

    // If a concurrent caller already rotated the token before this caller
    // entered refreshAccessToken, reuse the new tokens instead of replaying
    // the old refresh token.
    if (failedAccessToken != null) {
      final current = await _identityStore.readSessionTokens(backendUrl);
      final currentTime = _now();
      if (current != null &&
          current.accessToken != failedAccessToken &&
          !current.isSessionExpired(now: currentTime) &&
          !current.isAccessExpired(now: currentTime)) {
        return current;
      }
    }

    final completer = Completer<OrbSessionTokens>();
    _refreshCompleter = completer;

    _performRefresh(backendUrl).then(
      (OrbSessionTokens refreshed) {
        if (identical(_refreshCompleter, completer)) {
          _refreshCompleter = null;
        }
        if (!completer.isCompleted) {
          completer.complete(refreshed);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_refreshCompleter, completer)) {
          _refreshCompleter = null;
        }
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    return completer.future;
  }

  /// Clears stored tokens, increments [sessionEpoch], and notifies listeners.
  Future<void> invalidateSession(String? backendUrl) async {
    _sessionEpoch++;
    if (backendUrl != null) {
      await _identityStore.deleteSessionTokens(backendUrl);
    }
    _onSessionInvalidated?.call();
  }

  Future<OrbSessionTokens> _performRefresh(String backendUrl) async {
    final startEpoch = _sessionEpoch;
    final current = await _identityStore.readSessionTokens(backendUrl);
    if (current == null || current.isSessionExpired(now: _now())) {
      await invalidateSession(backendUrl);
      throw const OrbException(
        code: 'session_expired',
        message: 'Session expired; please sign in again.',
        state: OrbPreviewState.sessionExpired,
        statusCode: HttpStatus.unauthorized,
      );
    }

    final refreshUri =
        HttpsValidator.resolveEndpoint(backendUrl, '/api/v1/auth/refresh');
    final response = await _httpClient.post(
      refreshUri,
      headers: const <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json',
      },
      body: jsonEncode(<String, String>{
        'refresh_token': current.refreshToken,
      }),
    );

    if (_sessionEpoch != startEpoch) {
      throw const OrbException(
        code: 'session_expired',
        message: 'Session was cleared while refreshing tokens.',
        state: OrbPreviewState.sessionExpired,
        statusCode: HttpStatus.unauthorized,
      );
    }

    if (response.statusCode == HttpStatus.ok) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Expected JSON object from /auth/refresh');
        }
        final rotated = OrbSessionTokens.fromJson(decoded);
        await _identityStore.saveSessionTokens(backendUrl, rotated);
        return rotated;
      } on FormatException catch (error) {
        throw OrbException(
          code: 'invalid_response',
          message: 'Malformed token refresh response: ${error.message}',
          state: OrbPreviewState.networkError,
          statusCode: response.statusCode,
        );
      }
    }

    if (response.statusCode == HttpStatus.unauthorized) {
      await invalidateSession(backendUrl);
      throw OrbHttpClient.mapHttpError(response);
    }

    throw OrbHttpClient.mapHttpError(response);
  }
}
