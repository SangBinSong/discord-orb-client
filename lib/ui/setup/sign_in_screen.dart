import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../contracts/auth_repository.dart';
import '../../models/orb_error.dart';
import '../../models/session_models.dart';

/// Screen for launching Discord OAuth in the system browser and tracking progress.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.authRepository,
    required this.onSignedIn,
    required this.onChangeBackend,
    this.platform,
    this.clipboardWriter,
  });

  static const Key copyLinkButtonKey = Key('sign_in_copy_link_button');

  final AuthRepository authRepository;
  final ValueChanged<OrbSessionTokens> onSignedIn;
  final VoidCallback onChangeBackend;
  final OrbPlatform? platform;
  final Future<void> Function(String text)? clipboardWriter;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _isSigningIn = false;
  bool _isCancelling = false;
  int _attemptGeneration = 0;
  String? _errorMessage;
  Uri? _activeAuthorizationUri;

  bool get _isDesktopPlatform {
    final resolved = widget.platform ??
        switch (defaultTargetPlatform) {
          TargetPlatform.android => OrbPlatform.android,
          TargetPlatform.windows => OrbPlatform.windows,
          _ => OrbPlatform.macos,
        };
    return resolved != OrbPlatform.android;
  }

  Future<void> _copyUriToClipboard(Uri uri, int generation) async {
    try {
      final writer = widget.clipboardWriter ??
          (String text) => Clipboard.setData(ClipboardData(text: text));
      await writer(uri.toString());
      if (!mounted || generation != _attemptGeneration) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('인증 링크를 복사했습니다. 원하는 브라우저에 붙여넣어 진행하세요.'),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (error) {
      if (!mounted || generation != _attemptGeneration) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('링크 복사에 실패했습니다: $error'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _startSignIn({
    bool launchBrowser = true,
    bool copyWhenReady = false,
  }) async {
    final generation = ++_attemptGeneration;
    setState(() {
      _isSigningIn = true;
      _isCancelling = false;
      _errorMessage = null;
      _activeAuthorizationUri = null;
    });

    try {
      final tokens = await widget.authRepository.signInWithDiscord(
        launchBrowser: launchBrowser,
        onAuthorizationUriReady: (Uri authorizationUri) {
          if (!mounted || generation != _attemptGeneration) return;
          setState(() {
            _activeAuthorizationUri = authorizationUri;
          });
          if (copyWhenReady) {
            unawaited(_copyUriToClipboard(authorizationUri, generation));
          }
        },
      );
      if (!mounted || generation != _attemptGeneration) return;
      setState(() {
        _isSigningIn = false;
        _activeAuthorizationUri = null;
      });
      widget.onSignedIn(tokens);
    } on OrbException catch (error) {
      if (!mounted || generation != _attemptGeneration) return;
      setState(() {
        _isSigningIn = false;
        _activeAuthorizationUri = null;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted || generation != _attemptGeneration) return;
      setState(() {
        _isSigningIn = false;
        _activeAuthorizationUri = null;
        _errorMessage = 'Sign-in failed: $error';
      });
    }
  }

  Future<void> _handleCopyLinkPressed() async {
    if (_isCancelling) return;
    final activeUri = _activeAuthorizationUri;
    if (_isSigningIn && activeUri != null) {
      await _copyUriToClipboard(activeUri, _attemptGeneration);
      return;
    }
    if (!_isSigningIn) {
      await _startSignIn(launchBrowser: false, copyWhenReady: true);
    }
  }

  Future<void> _cancelSignIn() async {
    _attemptGeneration++;
    setState(() {
      _isCancelling = true;
      _activeAuthorizationUri = null;
    });
    try {
      await widget.authRepository.cancelPendingSignIn();
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
          _isCancelling = false;
          _activeAuthorizationUri = null;
          _errorMessage = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final backendUrl = widget.authRepository.backendBaseUrl;
    final deviceName = widget.authRepository.currentDeviceIdentity?.deviceName;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('sign_in_back_button'),
          tooltip: 'Change backend URL',
          icon: const Icon(Icons.arrow_back),
          onPressed: _isSigningIn ? null : widget.onChangeBackend,
        ),
        title: const Text('Discord Sign-In'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.login_rounded,
                  size: 48,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Sign in with Discord',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Your system browser will open to authorize Discord Orb. '
                  'Return to this app once sign-in finishes.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (backendUrl != null || deviceName != null) ...<Widget>[
                  const SizedBox(height: 20),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          if (backendUrl != null)
                            Text(
                              'Backend: $backendUrl',
                              style: theme.textTheme.bodySmall,
                            ),
                          if (deviceName != null) ...<Widget>[
                            const SizedBox(height: 4),
                            Text(
                              'Device: $deviceName',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                if (_isSigningIn) ...<Widget>[
                  const SizedBox(height: 24),
                  const Center(
                    child: CircularProgressIndicator(
                      key: Key('sign_in_loading_indicator'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isCancelling
                        ? 'Cancelling sign-in...'
                        : 'Waiting for Discord authorization in browser...',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const Key('sign_in_cancel_button'),
                    onPressed: _isCancelling ? null : _cancelSignIn,
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel Sign-In'),
                  ),
                  if (_isDesktopPlatform && _activeAuthorizationUri != null) ...<Widget>[
                    const SizedBox(height: 8),
                    TextButton(
                      key: SignInScreen.copyLinkButtonKey,
                      onPressed: _isCancelling ? null : _handleCopyLinkPressed,
                      child: const Text('링크 복사'),
                    ),
                  ],
                ] else ...<Widget>[
                  if (_errorMessage != null) ...<Widget>[
                    const SizedBox(height: 20),
                    Container(
                      key: const Key('sign_in_error_banner'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            Icons.error_outline,
                            color: colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('sign_in_start_button'),
                    onPressed: () => unawaited(_startSignIn()),
                    icon: Icon(
                      _errorMessage != null
                          ? Icons.refresh
                          : Icons.open_in_browser,
                    ),
                    label: Text(
                      _errorMessage != null
                          ? 'Retry Discord Sign-In'
                          : 'Sign in with Discord',
                    ),
                  ),
                  if (_isDesktopPlatform) ...<Widget>[
                    const SizedBox(height: 8),
                    TextButton(
                      key: SignInScreen.copyLinkButtonKey,
                      onPressed: () => unawaited(_handleCopyLinkPressed()),
                      child: const Text('링크 복사'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextButton(
                    key: const Key('sign_in_change_backend_button'),
                    onPressed: widget.onChangeBackend,
                    child: const Text('Change Backend URL'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
