import 'dart:async';
import 'dart:io';

import '../models/orb_error.dart';

/// Parsed OAuth callback payload returned from the local redirect listener.
class OAuthCallbackResult {
  const OAuthCallbackResult({
    required this.ticket,
    required this.state,
  });

  final String ticket;
  final String state;
}

/// Ephemeral RFC 8252 loopback HTTP listener (`http://127.0.0.1:<port>/callback`)
/// for desktop Discord OAuth sign-in.
class OAuthLoopbackListener {
  HttpServer? _server;
  Completer<OAuthCallbackResult>? _completer;
  String _callbackPath = '/callback';
  String? _expectedState;
  bool _closed = false;

  Uri? get redirectUri {
    final server = _server;
    if (server == null) return null;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      path: _callbackPath,
    );
  }

  /// Binds an ephemeral loopback port on `127.0.0.1` and returns the callback URI.
  Future<Uri> start({String callbackPath = '/callback'}) async {
    if (_server != null) {
      return redirectUri!;
    }
    _closed = false;
    _callbackPath = callbackPath.startsWith('/') ? callbackPath : '/$callbackPath';
    _completer = Completer<OAuthCallbackResult>();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;

    server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stackTrace) {
        _completeErrorIfPending(
          OrbException(
            code: 'oauth_listener_error',
            message: 'Loopback OAuth listener failed: $error',
            state: OrbPreviewState.networkError,
          ),
        );
      },
      onDone: () {
        _completeErrorIfPending(
          const OrbException(
            code: 'oauth_cancelled',
            message: 'OAuth loopback listener closed before callback arrived.',
            state: OrbPreviewState.idle,
          ),
        );
      },
      cancelOnError: true,
    );

    return redirectUri!;
  }

  /// Waits for the OAuth callback `(ticket, state)` up to [timeout].
  Future<OAuthCallbackResult> waitForCallback({
    Duration timeout = const Duration(minutes: 5),
    String? expectedState,
  }) async {
    final completer = _completer;
    if (_server == null || completer == null) {
      throw const OrbException(
        code: 'oauth_listener_not_started',
        message: 'Loopback OAuth listener has not been started.',
        state: OrbPreviewState.networkError,
      );
    }

    _expectedState = expectedState;

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      const timeoutError = OrbException(
        code: 'oauth_timeout',
        message: 'Timed out waiting for Discord OAuth callback.',
        state: OrbPreviewState.networkError,
      );
      _completeErrorIfPending(timeoutError);
      throw timeoutError;
    } finally {
      await close();
    }
  }

  /// Cancels any pending OAuth sign-in wait and closes the loopback server.
  Future<void> cancel() async {
    _completeErrorIfPending(
      const OrbException(
        code: 'oauth_cancelled',
        message: 'Discord sign-in was cancelled.',
        state: OrbPreviewState.idle,
      ),
    );
    await close();
  }

  /// Closes the underlying [HttpServer] idempotently.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path != _callbackPath) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.text;
        request.response.write('Not Found');
        await request.response.close();
        return;
      }

      final params = request.uri.queryParameters;
      final oauthError = params['error'];
      if (oauthError != null && oauthError.isNotEmpty) {
        await _respondHtml(
          request.response,
          statusCode: HttpStatus.badRequest,
          title: 'Sign-in cancelled',
          body: 'Discord authentication did not complete ($oauthError). '
              'You can close this tab and return to Discord Orb.',
        );
        _completeErrorIfPending(
          OrbException(
            code: 'oauth_denied',
            message: 'OAuth provider returned error: $oauthError',
            state: OrbPreviewState.idle,
          ),
        );
        await close();
        return;
      }

      final ticket = params['ticket']?.trim();
      final state = params['state']?.trim();
      if (ticket == null || ticket.isEmpty || state == null || state.isEmpty) {
        await _respondHtml(
          request.response,
          statusCode: HttpStatus.badRequest,
          title: 'Invalid callback',
          body: 'Missing required authentication parameters. '
              'Please return to Discord Orb and try again.',
        );
        _completeErrorIfPending(
          const OrbException(
            code: 'invalid_oauth_callback',
            message: 'OAuth callback was missing ticket or state.',
            state: OrbPreviewState.networkError,
          ),
        );
        await close();
        return;
      }

      if (_expectedState != null && state != _expectedState) {
        await _respondHtml(
          request.response,
          statusCode: HttpStatus.badRequest,
          title: 'State mismatch',
          body: 'Authentication state verification failed. '
              'Please close this tab and restart sign-in.',
        );
        _completeErrorIfPending(
          const OrbException(
            code: 'oauth_state_mismatch',
            message: 'OAuth callback state did not match expected state.',
            state: OrbPreviewState.networkError,
          ),
        );
        await close();
        return;
      }

      await _respondHtml(
        request.response,
        statusCode: HttpStatus.ok,
        title: 'Discord Orb connected',
        body: 'Authentication succeeded. You may now close this window and '
            'return to Discord Orb.',
      );

      final completer = _completer;
      if (completer != null && !completer.isCompleted) {
        completer.complete(OAuthCallbackResult(ticket: ticket, state: state));
      }
      await close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _respondHtml(
    HttpResponse response, {
    required int statusCode,
    required String title,
    required String body,
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.html;
    response.headers.set('Cache-Control', 'no-store');
    response.write(
      '<!doctype html><html><head><meta charset="utf-8">'
      '<title>$title</title></head>'
      '<body style="font-family:sans-serif;padding:24px;">'
      '<h2>$title</h2><p>$body</p>'
      '</body></html>',
    );
    await response.close();
  }

  void _completeErrorIfPending(OrbException error) {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }
}
