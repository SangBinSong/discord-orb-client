import 'dart:async';

import 'package:flutter/services.dart';

import '../app.dart';
import '../models/orb_error.dart';
import 'oauth_loopback_listener.dart';

/// Android custom-scheme (`discordorb://auth/callback`) deep-link listener
/// backed by `MethodChannel('discord_orb/auth_links')`.
class OAuthSchemeListener {
  OAuthSchemeListener({
    MethodChannel? channel,
    Stream<String>? linkStream,
    this._getInitialLinkOverride,
  })  : _channel = channel ?? const MethodChannel(OrbPlatformChannels.authLinks),
        _injectedLinkStream = linkStream;

  static final Uri defaultRedirectUri = Uri.parse('discordorb://auth/callback');

  final MethodChannel _channel;
  final Stream<String>? _injectedLinkStream;
  final Future<String?> Function()? _getInitialLinkOverride;

  final StreamController<String> _methodChannelLinks =
      StreamController<String>.broadcast();
  Completer<OAuthCallbackResult>? _pendingCompleter;
  StreamSubscription<String>? _activeSubscription;
  bool _handlerRegistered = false;

  Uri get redirectUri => defaultRedirectUri;

  /// Parses and validates a `discordorb://auth/callback` URI.
  static OAuthCallbackResult parseCallbackUri(
    Uri uri, {
    String? expectedState,
  }) {
    if (uri.scheme.toLowerCase() != 'discordorb' ||
        uri.host.toLowerCase() != 'auth' ||
        uri.path != '/callback') {
      throw OrbException(
        code: 'invalid_oauth_callback',
        message: 'Unexpected OAuth callback URI: $uri',
        state: OrbPreviewState.networkError,
      );
    }

    final params = uri.queryParameters;
    final oauthError = params['error'];
    if (oauthError != null && oauthError.isNotEmpty) {
      throw OrbException(
        code: 'oauth_denied',
        message: 'OAuth provider returned error: $oauthError',
        state: OrbPreviewState.idle,
      );
    }

    final ticket = params['ticket']?.trim();
    final state = params['state']?.trim();
    if (ticket == null || ticket.isEmpty || state == null || state.isEmpty) {
      throw const OrbException(
        code: 'invalid_oauth_callback',
        message: 'OAuth callback link was missing ticket or state.',
        state: OrbPreviewState.networkError,
      );
    }

    if (expectedState != null && state != expectedState) {
      throw const OrbException(
        code: 'oauth_state_mismatch',
        message: 'OAuth callback state did not match expected state.',
        state: OrbPreviewState.networkError,
      );
    }

    return OAuthCallbackResult(ticket: ticket, state: state);
  }

  /// Queries `getInitialLink` on `discord_orb/auth_links` (or the test
  /// override), returning `null` if unavailable or empty.
  Future<String?> getInitialLink() async {
    final override = _getInitialLinkOverride;
    if (override != null) {
      return override();
    }
    try {
      final result = await _channel.invokeMethod<String>('getInitialLink');
      if (result == null || result.trim().isEmpty) {
        return null;
      }
      return result;
    } on MissingPluginException {
      if (_injectedLinkStream != null) {
        return null;
      }
      rethrow;
    }
  }

  /// Stream of incoming link strings delivered via `onLink` or the injected
  /// test stream.
  Stream<String> get onLink {
    _ensureHandlerRegistered();
    return _injectedLinkStream ?? _methodChannelLinks.stream;
  }

  /// Waits for a `discordorb://auth/callback` link via `getInitialLink` or
  /// `onLink`.
  Future<OAuthCallbackResult> waitForCallback({
    Duration timeout = const Duration(minutes: 5),
    String? expectedState,
  }) async {
    await cancel();

    final completer = Completer<OAuthCallbackResult>();
    _pendingCompleter = completer;

    void handleRawLink(String rawLink) {
      if (completer.isCompleted) return;
      final parsed = Uri.tryParse(rawLink.trim());
      if (parsed == null) {
        return;
      }
      // Ignore unrelated deep links that are not OAuth callbacks.
      if (parsed.scheme.toLowerCase() != 'discordorb' ||
          parsed.host.toLowerCase() != 'auth' ||
          parsed.path != '/callback') {
        return;
      }

      try {
        final result = parseCallbackUri(parsed, expectedState: expectedState);
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } on OrbException catch (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      }
    }

    _activeSubscription = onLink.listen(
      handleRawLink,
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            OrbException(
              code: 'oauth_listener_error',
              message: 'Failed receiving OAuth deep link: $error',
              state: OrbPreviewState.networkError,
            ),
          );
        }
      },
    );

    try {
      final initialLink = await getInitialLink();
      if (initialLink != null) {
        handleRawLink(initialLink);
      }

      return await completer.future.timeout(timeout);
    } on TimeoutException {
      const timeoutError = OrbException(
        code: 'oauth_timeout',
        message: 'Timed out waiting for Discord OAuth deep link callback.',
        state: OrbPreviewState.networkError,
      );
      if (!completer.isCompleted) {
        completer.completeError(timeoutError);
      }
      throw timeoutError;
    } finally {
      await _cleanupActiveWait();
    }
  }

  /// Cancels any active deep-link wait.
  Future<void> cancel() async {
    final completer = _pendingCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        const OrbException(
          code: 'oauth_cancelled',
          message: 'Discord sign-in was cancelled.',
          state: OrbPreviewState.idle,
        ),
      );
    }
    await _cleanupActiveWait();
  }

  Future<void> dispose() async {
    await cancel();
    if (_handlerRegistered) {
      _channel.setMethodCallHandler(null);
      _handlerRegistered = false;
    }
    if (!_methodChannelLinks.isClosed) {
      await _methodChannelLinks.close();
    }
  }

  void _ensureHandlerRegistered() {
    if (_injectedLinkStream != null || _handlerRegistered) {
      return;
    }
    _handlerRegistered = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onLink') {
        final link = _extractLinkArgument(call.arguments);
        if (link != null && !_methodChannelLinks.isClosed) {
          _methodChannelLinks.add(link);
        }
      }
      return null;
    });
  }

  String? _extractLinkArgument(dynamic arguments) {
    if (arguments is String) {
      return arguments;
    }
    if (arguments is Map<Object?, Object?>) {
      final candidate =
          arguments['link'] ?? arguments['url'] ?? arguments['uri'];
      if (candidate is String) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> _cleanupActiveWait() async {
    _pendingCompleter = null;
    final sub = _activeSubscription;
    _activeSubscription = null;
    if (sub != null) {
      await sub.cancel();
    }
  }
}
