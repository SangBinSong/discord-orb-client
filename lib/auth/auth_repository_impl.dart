import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../contracts/auth_repository.dart';
import '../core/device_identity_store.dart';
import '../core/http_client.dart';
import '../core/https_validator.dart';
import '../models/orb_error.dart';
import '../models/session_models.dart';
import 'oauth_loopback_listener.dart';
import 'oauth_scheme_listener.dart';
import 'pkce.dart';
import 'token_manager.dart';

/// Concrete [AuthRepository] coordinating HTTPS backend probing, RFC 8252
/// OAuth sign-in, token rotation, and backend-scoped credential cleanup.
class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({
    required this._identityStore,
    required this._httpClient,
    required this._tokenManager,
    required this._browserLauncher,
    OAuthLoopbackListener Function()? loopbackListenerFactory,
    OAuthSchemeListener? schemeListener,
    OrbPlatform? platform,
    this._oauthTimeout = const Duration(minutes: 5),
    this._onSessionInvalidated,
  })  : _loopbackListenerFactory =
            loopbackListenerFactory ?? OAuthLoopbackListener.new,
        _schemeListener = schemeListener ?? OAuthSchemeListener(),
        _platform = platform ?? DeviceIdentityStore.detectCurrentPlatform();

  final DeviceIdentityStore _identityStore;
  final OrbHttpClient _httpClient;
  final TokenManager _tokenManager;
  final SystemBrowserLauncher _browserLauncher;
  final OAuthLoopbackListener Function() _loopbackListenerFactory;
  final OAuthSchemeListener _schemeListener;
  final OrbPlatform _platform;
  final Duration _oauthTimeout;
  final void Function()? _onSessionInvalidated;

  String? _backendBaseUrl;
  DeviceIdentity? _currentDeviceIdentity;
  Future<void> Function()? _activeSignInCancel;

  @override
  String? get backendBaseUrl => _backendBaseUrl;

  @override
  DeviceIdentity? get currentDeviceIdentity => _currentDeviceIdentity;

  @override
  Future<BackendHealthStatus> validateAndProbeBackend(String url) async {
    final normalizedBase = HttpsValidator.validateBackendBaseUrl(url).toString();
    final healthUri = HttpsValidator.resolveEndpoint(normalizedBase, '/healthz');

    final response = await _httpClient.get(
      healthUri,
      headers: const <String, String>{'accept': 'application/json'},
    );

    if (response.statusCode != HttpStatus.ok) {
      throw OrbHttpClient.mapHttpError(response);
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected JSON object from /healthz');
      }
      final status = decoded['status'];
      if (status != null && status != 'ok') {
        throw OrbException(
          code: 'backend_unhealthy',
          message: 'Backend health check reported status "$status".',
          state: OrbPreviewState.networkError,
          statusCode: response.statusCode,
        );
      }
      return BackendHealthStatus.fromJson(decoded);
    } on OrbException {
      rethrow;
    } on FormatException catch (error) {
      throw OrbException(
        code: 'invalid_health_response',
        message: 'Invalid /healthz payload: ${error.message}',
        state: OrbPreviewState.networkError,
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> configureBackend(String url, {String? deviceName}) async {
    final normalized = HttpsValidator.validateBackendBaseUrl(url).toString();
    final existingBackend =
        _backendBaseUrl ?? await _identityStore.readActiveBackendUrl();

    if (existingBackend != null && existingBackend != normalized) {
      await clearLocalStateForBackendChange();
    }

    final identity = await _identityStore.configureBackend(
      normalized,
      deviceName: deviceName,
      platform: _platform,
    );
    _backendBaseUrl = normalized;
    _currentDeviceIdentity = identity;
  }

  @override
  Future<OrbSessionTokens> signInWithDiscord({
    bool launchBrowser = true,
    void Function(Uri authorizationUri)? onAuthorizationUriReady,
  }) async {
    final backendUrl = await _requireBackendUrl();
    final identity = _currentDeviceIdentity ??
        await _identityStore.getOrCreateDeviceIdentity(
          backendUrl,
          platform: _platform,
        );
    _currentDeviceIdentity = identity;

    await cancelPendingSignIn();

    final pkce = PkcePair.generate();
    final OAuthCallbackResult callbackResult;

    if (_platform == OrbPlatform.android) {
      callbackResult = await _signInViaSchemeListener(
        backendUrl: backendUrl,
        pkce: pkce,
        launchBrowser: launchBrowser,
        onAuthorizationUriReady: onAuthorizationUriReady,
      );
    } else {
      callbackResult = await _signInViaLoopbackListener(
        backendUrl: backendUrl,
        pkce: pkce,
        launchBrowser: launchBrowser,
        onAuthorizationUriReady: onAuthorizationUriReady,
      );
    }

    if (callbackResult.state != pkce.state || callbackResult.ticket.isEmpty) {
      throw const OrbException(
        code: 'oauth_state_mismatch',
        message: 'OAuth callback state verification failed.',
        state: OrbPreviewState.networkError,
      );
    }

    return _exchangeTicketForTokens(
      backendUrl: backendUrl,
      ticket: callbackResult.ticket,
      codeVerifier: pkce.codeVerifier,
      identity: identity,
    );
  }

  @override
  Future<void> cancelPendingSignIn() async {
    final cancel = _activeSignInCancel;
    _activeSignInCancel = null;
    if (cancel != null) {
      await cancel();
    }
  }

  @override
  Future<OrbSessionTokens?> loadStoredSession() async {
    final backendUrl =
        _backendBaseUrl ?? await _identityStore.readActiveBackendUrl();
    if (backendUrl == null) {
      return null;
    }
    _backendBaseUrl = backendUrl;
    _currentDeviceIdentity ??=
        await _identityStore.readDeviceIdentity(backendUrl);

    return _tokenManager.loadStoredSession(backendUrl);
  }

  @override
  Future<OrbSessionTokens> refreshAccessToken() async {
    final backendUrl = _backendBaseUrl ??
        await _identityStore.readActiveBackendUrl();
    if (backendUrl == null) {
      throw const OrbException(
        code: 'session_expired',
        message: 'No configured backend for session refresh.',
        state: OrbPreviewState.sessionExpired,
        statusCode: HttpStatus.unauthorized,
      );
    }
    _backendBaseUrl = backendUrl;
    return _tokenManager.refreshAccessToken(backendUrl);
  }

  @override
  Future<void> signOut() async {
    await cancelPendingSignIn();

    final backendUrl =
        _backendBaseUrl ?? await _identityStore.readActiveBackendUrl();
    if (backendUrl != null) {
      final tokens = await _identityStore.readSessionTokens(backendUrl);
      if (tokens != null) {
        try {
          final logoutUri =
              HttpsValidator.resolveEndpoint(backendUrl, '/api/v1/auth/logout');
          await _httpClient.post(
            logoutUri,
            headers: <String, String>{
              'authorization': 'Bearer ${tokens.accessToken}',
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode(<String, String>{
              'refresh_token': tokens.refreshToken,
            }),
          );
        } catch (_) {
          // Local cleanup must always proceed even if remote logout fails.
        }
      }
      await _tokenManager.invalidateSession(backendUrl);
      await _identityStore.deleteSelectedChannel(backendUrl: backendUrl);
    } else {
      await _tokenManager.invalidateSession(null);
      await _identityStore.deleteSelectedChannel();
    }

    _onSessionInvalidated?.call();
  }

  @override
  Future<void> clearLocalStateForBackendChange() async {
    await cancelPendingSignIn();
    final previousUrl =
        _backendBaseUrl ?? await _identityStore.readActiveBackendUrl();
    await _tokenManager.invalidateSession(previousUrl);
    await _identityStore.clearForBackendChange(previousBackendUrl: previousUrl);
    _backendBaseUrl = null;
    _currentDeviceIdentity = null;
    _onSessionInvalidated?.call();
  }

  Future<String> _requireBackendUrl() async {
    final url = _backendBaseUrl ?? await _identityStore.readActiveBackendUrl();
    if (url == null) {
      throw const OrbException(
        code: 'backend_not_configured',
        message: 'Backend URL must be configured before signing in.',
        state: OrbPreviewState.networkError,
      );
    }
    _backendBaseUrl = url;
    return url;
  }

  Future<OAuthCallbackResult> _signInViaLoopbackListener({
    required String backendUrl,
    required PkcePair pkce,
    required bool launchBrowser,
    void Function(Uri authorizationUri)? onAuthorizationUriReady,
  }) async {
    final listener = _loopbackListenerFactory();
    _activeSignInCancel = listener.cancel;
    try {
      final redirectUri = await listener.start();
      final loginUri = _buildLoginUri(
        backendUrl: backendUrl,
        redirectUri: redirectUri,
        pkce: pkce,
      );
      final waitFuture = listener.waitForCallback(
        timeout: _oauthTimeout,
        expectedState: pkce.state,
      );
      onAuthorizationUriReady?.call(loginUri);
      if (launchBrowser) {
        try {
          await _browserLauncher.launch(loginUri);
        } catch (error) {
          await listener.cancel();
          // Drain waitFuture error if launch failed so no unhandled error escapes.
          await waitFuture.catchError((Object _) => const OAuthCallbackResult(
                ticket: '',
                state: '',
              ));
          if (error is OrbException) rethrow;
          throw OrbException(
            code: 'browser_launch_failed',
            message: 'Failed to launch system browser for OAuth: $error',
            state: OrbPreviewState.networkError,
          );
        }
      }
      return await waitFuture;
    } finally {
      if (identical(_activeSignInCancel, listener.cancel)) {
        _activeSignInCancel = null;
      }
      await listener.close();
    }
  }

  Future<OAuthCallbackResult> _signInViaSchemeListener({
    required String backendUrl,
    required PkcePair pkce,
    required bool launchBrowser,
    void Function(Uri authorizationUri)? onAuthorizationUriReady,
  }) async {
    _activeSignInCancel = _schemeListener.cancel;
    try {
      final loginUri = _buildLoginUri(
        backendUrl: backendUrl,
        redirectUri: _schemeListener.redirectUri,
        pkce: pkce,
      );
      final waitFuture = _schemeListener.waitForCallback(
        timeout: _oauthTimeout,
        expectedState: pkce.state,
      );
      onAuthorizationUriReady?.call(loginUri);
      if (launchBrowser) {
        try {
          await _browserLauncher.launch(loginUri);
        } catch (error) {
          await _schemeListener.cancel();
          await waitFuture.catchError((Object _) => const OAuthCallbackResult(
                ticket: '',
                state: '',
              ));
          if (error is OrbException) rethrow;
          throw OrbException(
            code: 'browser_launch_failed',
            message: 'Failed to launch system browser for OAuth: $error',
            state: OrbPreviewState.networkError,
          );
        }
      }
      return await waitFuture;
    } finally {
      if (identical(_activeSignInCancel, _schemeListener.cancel)) {
        _activeSignInCancel = null;
      }
    }
  }

  Uri _buildLoginUri({
    required String backendUrl,
    required Uri redirectUri,
    required PkcePair pkce,
  }) {
    return HttpsValidator.resolveEndpoint(
      backendUrl,
      '/auth/discord/login',
      queryParameters: <String, String>{
        'redirect_uri': redirectUri.toString(),
        'code_challenge': pkce.codeChallenge,
        'code_challenge_method': pkce.codeChallengeMethod,
        'state': pkce.state,
      },
    );
  }

  Future<OrbSessionTokens> _exchangeTicketForTokens({
    required String backendUrl,
    required String ticket,
    required String codeVerifier,
    required DeviceIdentity identity,
  }) async {
    final exchangeUri =
        HttpsValidator.resolveEndpoint(backendUrl, '/api/v1/auth/exchange');
    final response = await _httpClient.post(
      exchangeUri,
      headers: const <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json',
      },
      body: jsonEncode(<String, String>{
        'ticket': ticket,
        'code_verifier': codeVerifier,
        'device_name': identity.deviceName,
        'device_id': identity.deviceId,
        'platform': identity.platform.wireName,
      }),
    );

    if (response.statusCode != HttpStatus.ok) {
      throw OrbHttpClient.mapHttpError(response);
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected JSON object from /auth/exchange');
      }
      final tokens = OrbSessionTokens.fromJson(decoded);
      await _tokenManager.saveNewSession(backendUrl, tokens);
      return tokens;
    } on FormatException catch (error) {
      throw OrbException(
        code: 'invalid_exchange_response',
        message: 'Invalid /auth/exchange response: ${error.message}',
        state: OrbPreviewState.networkError,
        statusCode: response.statusCode,
      );
    }
  }
}
