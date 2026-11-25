import 'dart:async';

import 'package:discord_orb/contracts/auth_repository.dart';
import 'package:discord_orb/contracts/preview_repository.dart';
import 'package:discord_orb/models/channel_models.dart';
import 'package:discord_orb/models/message_models.dart';
import 'package:discord_orb/models/orb_error.dart';
import 'package:discord_orb/models/session_models.dart';
import 'package:discord_orb/ui/channels/channel_select_screen.dart';
import 'package:discord_orb/ui/common/orb_avatar.dart';
import 'package:discord_orb/ui/settings/session_settings_sheet.dart';
import 'package:discord_orb/ui/setup/backend_setup_screen.dart';
import 'package:discord_orb/ui/setup/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({
    this.initialBackendUrl,
    this.initialDeviceIdentity,
  })  : _backendBaseUrl = initialBackendUrl,
        _deviceIdentity = initialDeviceIdentity;

  final String? initialBackendUrl;
  final DeviceIdentity? initialDeviceIdentity;

  String? _backendBaseUrl;
  DeviceIdentity? _deviceIdentity;

  int probeCalls = 0;
  String? lastProbedUrl;
  String? lastConfiguredUrl;
  String? lastConfiguredDeviceName;
  int cancelPendingCalls = 0;
  int signOutCalls = 0;
  int clearBackendStateCalls = 0;
  int signInCalls = 0;
  bool? lastLaunchBrowser;

  Future<BackendHealthStatus> Function(String url)? onProbe;
  Future<OrbSessionTokens> Function({
    bool launchBrowser,
    void Function(Uri authorizationUri)? onAuthorizationUriReady,
  })? onSignIn;

  @override
  String? get backendBaseUrl => _backendBaseUrl;

  @override
  DeviceIdentity? get currentDeviceIdentity => _deviceIdentity;

  @override
  Future<BackendHealthStatus> validateAndProbeBackend(String url) async {
    probeCalls++;
    lastProbedUrl = url;
    if (onProbe != null) {
      return onProbe!(url);
    }
    return const BackendHealthStatus(setupRequired: false);
  }

  @override
  Future<void> configureBackend(String url, {String? deviceName}) async {
    lastConfiguredUrl = url;
    lastConfiguredDeviceName = deviceName;
    _backendBaseUrl = url;
    _deviceIdentity = DeviceIdentity(
      deviceName: deviceName ?? 'macOS Desktop',
      deviceId: 'synthetic-device-id',
      platform: OrbPlatform.macos,
    );
  }

  @override
  Future<OrbSessionTokens> signInWithDiscord({
    bool launchBrowser = true,
    void Function(Uri authorizationUri)? onAuthorizationUriReady,
  }) async {
    signInCalls++;
    lastLaunchBrowser = launchBrowser;
    if (onSignIn != null) {
      return onSignIn!(
        launchBrowser: launchBrowser,
        onAuthorizationUriReady: onAuthorizationUriReady,
      );
    }
    return OrbSessionTokens(
      accessToken: 'synthetic-access-token',
      refreshToken: 'synthetic-refresh-token',
      accessExpiresAt: DateTime.utc(2026, 11, 20, 12, 0),
      sessionExpiresAt: DateTime.utc(2026, 12, 20, 12, 0),
    );
  }

  @override
  Future<void> cancelPendingSignIn() async {
    cancelPendingCalls++;
  }

  @override
  Future<OrbSessionTokens?> loadStoredSession() async => null;

  @override
  Future<OrbSessionTokens> refreshAccessToken() {
    throw UnimplementedError();
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }

  @override
  Future<void> clearLocalStateForBackendChange() async {
    clearBackendStateCalls++;
    _backendBaseUrl = null;
    _deviceIdentity = null;
  }
}

class _FakePreviewRepository implements PreviewRepository {
  int fetchGuildsCalls = 0;
  Future<List<EligibleGuild>> Function()? onFetchGuilds;

  @override
  Future<List<EligibleGuild>> fetchEligibleGuilds() async {
    fetchGuildsCalls++;
    if (onFetchGuilds != null) {
      return onFetchGuilds!();
    }
    return const <EligibleGuild>[];
  }

  @override
  Future<List<ChannelMessagePreview>> fetchLatestMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) async {
    return const <ChannelMessagePreview>[];
  }

  @override
  Stream<ChannelMessageEvent> subscribeToChannelMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) =>
      const Stream<ChannelMessageEvent>.empty();

  @override
  void cancelActivePreview() {}

  @override
  void clearMemory() {}
}

Widget _wrapWithApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: child,
  );
}

void main() {
  group('BackendSetupScreen', () {
    testWidgets('pre-fills platform defaultDeviceName and blocks non-HTTPS URLs',
        (WidgetTester tester) async {
      final authRepo = _FakeAuthRepository();
      var configuredCount = 0;

      await tester.pumpWidget(
        _wrapWithApp(
          BackendSetupScreen(
            authRepository: authRepo,
            platform: OrbPlatform.windows,
            onConfigured: () => configuredCount++,
          ),
        ),
      );

      final deviceField = tester.widget<TextField>(
        find.byKey(const Key('device_name_field')),
      );
      expect(
        deviceField.controller?.text,
        OrbPlatform.windows.defaultDeviceName,
      );

      await tester.enterText(
        find.byKey(const Key('backend_url_field')),
        'http://insecure.example.com',
      );
      await tester.pump();

      expect(
        find.textContaining('https://'),
        findsWidgets,
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('backend_connect_button')),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.byKey(const Key('backend_connect_button')));
      await tester.pump();
      expect(authRepo.probeCalls, 0);
      expect(configuredCount, 0);
    });

    testWidgets(
        'shows missingEnvNames when setupRequired is true and blocks configure',
        (WidgetTester tester) async {
      final authRepo = _FakeAuthRepository()
        ..onProbe = (_) async => const BackendHealthStatus(
              setupRequired: true,
              missingEnvNames: <String>['DISCORD_BOT_TOKEN', 'JWT_SECRET'],
            );
      var configuredCount = 0;

      await tester.pumpWidget(
        _wrapWithApp(
          BackendSetupScreen(
            authRepository: authRepo,
            platform: OrbPlatform.macos,
            onConfigured: () => configuredCount++,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('backend_url_field')),
        'https://orb.example.com',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('backend_connect_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('backend_setup_required_banner')),
        findsOneWidget,
      );
      expect(find.textContaining('DISCORD_BOT_TOKEN'), findsOneWidget);
      expect(find.textContaining('JWT_SECRET'), findsOneWidget);
      expect(authRepo.lastConfiguredUrl, isNull);
      expect(configuredCount, 0);
    });

    testWidgets(
        'shows probe error, retries, configures backend, and calls onConfigured',
        (WidgetTester tester) async {
      var shouldFail = true;
      final authRepo = _FakeAuthRepository()
        ..onProbe = (_) async {
          if (shouldFail) {
            throw const OrbException(
              code: 'network_error',
              message: 'Unable to reach server',
              state: OrbPreviewState.networkError,
            );
          }
          return const BackendHealthStatus(setupRequired: false);
        };
      var configuredCount = 0;

      await tester.pumpWidget(
        _wrapWithApp(
          BackendSetupScreen(
            authRepository: authRepo,
            platform: OrbPlatform.android,
            onConfigured: () => configuredCount++,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('backend_url_field')),
        'https://orb.example.com',
      );
      await tester.enterText(
        find.byKey(const Key('device_name_field')),
        'Pixel Test',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('backend_connect_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('backend_probe_error_banner')),
        findsOneWidget,
      );
      expect(find.text('Unable to reach server'), findsOneWidget);
      expect(configuredCount, 0);

      shouldFail = false;
      await tester.tap(find.byKey(const Key('backend_connect_button')));
      await tester.pumpAndSettle();

      expect(authRepo.probeCalls, 2);
      expect(authRepo.lastConfiguredUrl, 'https://orb.example.com');
      expect(authRepo.lastConfiguredDeviceName, 'Pixel Test');
      expect(configuredCount, 1);
    });

    testWidgets(
      'prefills debug default backend URL only in debug mode when no saved URL exists',
      (WidgetTester tester) async {
        expect(
          BackendSetupScreen.resolveInitialUrl(
            devDefaultBackendUrl: 'https://dev-preview.example.com',
            isDebugMode: true,
          ),
          'https://dev-preview.example.com',
        );
        expect(
          BackendSetupScreen.resolveInitialUrl(
            devDefaultBackendUrl: 'https://dev-preview.example.com',
            isDebugMode: false,
          ),
          '',
        );
        expect(
          BackendSetupScreen.resolveInitialUrl(
            savedBackendUrl: 'https://saved.example.com',
            devDefaultBackendUrl: 'https://dev-preview.example.com',
            isDebugMode: true,
          ),
          'https://saved.example.com',
        );

        final authRepo = _FakeAuthRepository();
        await tester.pumpWidget(
          _wrapWithApp(
            BackendSetupScreen(
              authRepository: authRepo,
              platform: OrbPlatform.macos,
              debugDefaultUrlOverride: 'https://dev-preview.example.com',
              isDebugModeOverride: true,
              onConfigured: () {},
            ),
          ),
        );

        final urlField = tester.widget<TextField>(
          find.byKey(const Key('backend_url_field')),
        );
        expect(urlField.controller?.text, 'https://dev-preview.example.com');
      },
    );
  });

  group('SignInScreen', () {
    testWidgets('shows loading during sign-in and supports cancelPendingSignIn',
        (WidgetTester tester) async {
      final completer = Completer<OrbSessionTokens>();
      final authRepo = _FakeAuthRepository(
        initialBackendUrl: 'https://orb.example.com',
        initialDeviceIdentity: const DeviceIdentity(
          deviceName: 'My Mac',
          deviceId: 'synthetic-id',
          platform: OrbPlatform.macos,
        ),
      )..onSignIn = ({
          bool launchBrowser = true,
          void Function(Uri authorizationUri)? onAuthorizationUriReady,
        }) =>
            completer.future;

      OrbSessionTokens? signedInTokens;
      var changeBackendCalls = 0;

      await tester.pumpWidget(
        _wrapWithApp(
          SignInScreen(
            authRepository: authRepo,
            onSignedIn: (tokens) => signedInTokens = tokens,
            onChangeBackend: () => changeBackendCalls++,
          ),
        ),
      );

      expect(find.textContaining('https://orb.example.com'), findsOneWidget);
      expect(find.textContaining('My Mac'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sign_in_start_button')));
      await tester.pump();

      expect(find.byKey(const Key('sign_in_loading_indicator')), findsOneWidget);
      expect(find.byKey(const Key('sign_in_cancel_button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sign_in_cancel_button')));
      await tester.pumpAndSettle();

      expect(authRepo.cancelPendingCalls, 1);
      expect(find.byKey(const Key('sign_in_loading_indicator')), findsNothing);
      expect(find.byKey(const Key('sign_in_start_button')), findsOneWidget);

      completer.complete(
        OrbSessionTokens(
          accessToken: 'synthetic-late-access',
          refreshToken: 'synthetic-late-refresh',
          accessExpiresAt: DateTime.utc(2026, 11, 20),
          sessionExpiresAt: DateTime.utc(2026, 12, 20),
        ),
      );
      await tester.pump();
      expect(signedInTokens, isNull);

      await tester.tap(find.byKey(const Key('sign_in_change_backend_button')));
      await tester.pump();
      expect(changeBackendCalls, 1);
    });

    testWidgets('shows error retry UI and emits onSignedIn on success',
        (WidgetTester tester) async {
      var failOnce = true;
      final expectedTokens = OrbSessionTokens(
        accessToken: 'synthetic-access',
        refreshToken: 'synthetic-refresh',
        accessExpiresAt: DateTime.utc(2026, 11, 20),
        sessionExpiresAt: DateTime.utc(2026, 12, 20),
      );
      final authRepo = _FakeAuthRepository()
        ..onSignIn = ({
          bool launchBrowser = true,
          void Function(Uri authorizationUri)? onAuthorizationUriReady,
        }) async {
          if (failOnce) {
            throw const OrbException(
              code: 'oauth_failed',
              message: 'Discord authorization failed',
              state: OrbPreviewState.accessDenied,
            );
          }
          return expectedTokens;
        };

      OrbSessionTokens? signedInTokens;

      await tester.pumpWidget(
        _wrapWithApp(
          SignInScreen(
            authRepository: authRepo,
            onSignedIn: (tokens) => signedInTokens = tokens,
            onChangeBackend: () {},
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('sign_in_start_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sign_in_error_banner')), findsOneWidget);
      expect(find.text('Discord authorization failed'), findsOneWidget);
      expect(find.text('Retry Discord Sign-In'), findsOneWidget);

      failOnce = false;
      await tester.tap(find.byKey(const Key('sign_in_start_button')));
      await tester.pumpAndSettle();

      expect(signedInTokens, expectedTokens);
    });

    testWidgets(
      'PC shows text-only 링크 복사 button, copies OAuth URI without launching browser or showing raw URL, and completes sign-in',
      (WidgetTester tester) async {
        final completer = Completer<OrbSessionTokens>();
        final copiedTexts = <String>[];
        final authUri = Uri.parse(
          'https://orb.example.com/auth/discord/login?state=test-state&code_challenge=abc',
        );
        final authRepo = _FakeAuthRepository(
          initialBackendUrl: 'https://orb.example.com',
        )..onSignIn = ({
            bool launchBrowser = true,
            void Function(Uri authorizationUri)? onAuthorizationUriReady,
          }) {
            onAuthorizationUriReady?.call(authUri);
            return completer.future;
          };

        OrbSessionTokens? signedInTokens;

        await tester.pumpWidget(
          _wrapWithApp(
            SignInScreen(
              authRepository: authRepo,
              platform: OrbPlatform.macos,
              clipboardWriter: (String text) async => copiedTexts.add(text),
              onSignedIn: (tokens) => signedInTokens = tokens,
              onChangeBackend: () {},
            ),
          ),
        );

        final copyButtonFinder = find.byKey(SignInScreen.copyLinkButtonKey);
        expect(copyButtonFinder, findsOneWidget);
        expect(find.text('링크 복사'), findsOneWidget);
        expect(tester.widget(copyButtonFinder), isA<TextButton>());

        await tester.tap(copyButtonFinder);
        await tester.pump();

        expect(authRepo.signInCalls, 1);
        expect(authRepo.lastLaunchBrowser, isFalse);
        expect(copiedTexts, <String>[authUri.toString()]);
        // Raw OAuth URL must NOT be rendered on screen.
        expect(find.textContaining('code_challenge=abc'), findsNothing);

        // Re-tapping copies active URI without restarting sign-in.
        await tester.tap(copyButtonFinder);
        await tester.pump();
        expect(authRepo.signInCalls, 1);
        expect(copiedTexts, <String>[authUri.toString(), authUri.toString()]);

        final expectedTokens = OrbSessionTokens(
          accessToken: 'copied-flow-access',
          refreshToken: 'copied-flow-refresh',
          accessExpiresAt: DateTime.utc(2026, 11, 20),
          sessionExpiresAt: DateTime.utc(2026, 12, 20),
        );
        completer.complete(expectedTokens);
        await tester.pumpAndSettle();
        expect(signedInTokens, expectedTokens);
      },
    );

    testWidgets('hides 링크 복사 button on Android', (WidgetTester tester) async {
      final authRepo = _FakeAuthRepository(
        initialBackendUrl: 'https://orb.example.com',
      );
      await tester.pumpWidget(
        _wrapWithApp(
          SignInScreen(
            authRepository: authRepo,
            platform: OrbPlatform.android,
            onSignedIn: (_) {},
            onChangeBackend: () {},
          ),
        ),
      );

      expect(find.byKey(SignInScreen.copyLinkButtonKey), findsNothing);
      expect(find.text('링크 복사'), findsNothing);
    });
  });

  group('ChannelSelectScreen', () {
    testWidgets('renders grouped guilds/channels and calls onChannelSelected',
        (WidgetTester tester) async {
      const targetChannel = EligibleChannel(
        guildId: 'g1',
        guildName: 'Orb Guild',
        channelId: 'c2',
        channelName: 'announcements',
      );

      final previewRepo = _FakePreviewRepository()
        ..onFetchGuilds = () async => const <EligibleGuild>[
              EligibleGuild(
                guildId: 'g1',
                guildName: 'Orb Guild',
                channels: <EligibleChannel>[
                  EligibleChannel(
                    guildId: 'g1',
                    guildName: 'Orb Guild',
                    channelId: 'c1',
                    channelName: 'general',
                  ),
                  targetChannel,
                ],
              ),
              EligibleGuild(
                guildId: 'g2',
                guildName: 'Design Team',
                channels: <EligibleChannel>[
                  EligibleChannel(
                    guildId: 'g2',
                    guildName: 'Design Team',
                    channelId: 'c3',
                    channelName: 'ui-review',
                  ),
                ],
              ),
            ];

      EligibleChannel? selected;
      await tester.pumpWidget(
        _wrapWithApp(
          ChannelSelectScreen(
            previewRepository: previewRepo,
            onChannelSelected: (channel) => selected = channel,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Orb Guild'), findsOneWidget);
      expect(find.text('Design Team'), findsOneWidget);
      expect(find.byType(OrbAvatar), findsNWidgets(2));
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#announcements'), findsOneWidget);
      expect(find.text('#ui-review'), findsOneWidget);

      await tester.tap(find.byKey(const Key('channel_tile_c2')));
      await tester.pump();
      expect(selected, targetChannel);
    });

    testWidgets(
        'renders sessionExpired error with re-auth callback and retry',
        (WidgetTester tester) async {
      final previewRepo = _FakePreviewRepository()
        ..onFetchGuilds = () async {
          throw const OrbException(
            code: 'session_expired',
            message: 'Your session has expired.',
            state: OrbPreviewState.sessionExpired,
          );
        };

      var sessionExpiredCalls = 0;
      await tester.pumpWidget(
        _wrapWithApp(
          ChannelSelectScreen(
            previewRepository: previewRepo,
            onChannelSelected: (_) {},
            onSessionExpired: () => sessionExpiredCalls++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('channel_error_view')), findsOneWidget);
      expect(find.text('Session Expired'), findsOneWidget);
      expect(find.byKey(const Key('channel_reauth_button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('channel_reauth_button')));
      await tester.pump();
      expect(sessionExpiredCalls, 1);
    });

    testWidgets('renders empty state when 0 eligible channels and refreshes',
        (WidgetTester tester) async {
      var returnEmpty = true;
      final previewRepo = _FakePreviewRepository()
        ..onFetchGuilds = () async {
          if (returnEmpty) {
            return const <EligibleGuild>[
              EligibleGuild(
                guildId: 'g1',
                guildName: 'Empty Guild',
                channels: <EligibleChannel>[],
              ),
            ];
          }
          return const <EligibleGuild>[
            EligibleGuild(
              guildId: 'g1',
              guildName: 'Orb Guild',
              channels: <EligibleChannel>[
                EligibleChannel(
                  guildId: 'g1',
                  guildName: 'Orb Guild',
                  channelId: 'c1',
                  channelName: 'general',
                ),
              ],
            ),
          ];
        };

      await tester.pumpWidget(
        _wrapWithApp(
          ChannelSelectScreen(
            previewRepository: previewRepo,
            onChannelSelected: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('channel_empty_view')), findsOneWidget);
      expect(find.text('No Eligible Channels'), findsOneWidget);

      returnEmpty = false;
      await tester.tap(find.byKey(const Key('channel_empty_refresh_button')));
      await tester.pumpAndSettle();

      expect(previewRepo.fetchGuildsCalls, 2);
      expect(find.text('#general'), findsOneWidget);
    });
  });

  group('SessionSettingsSheet', () {
    testWidgets(
        'displays session info and triggers reselect, signOut, and backend change',
        (WidgetTester tester) async {
      final authRepo = _FakeAuthRepository(
        initialBackendUrl: 'https://orb.example.com',
        initialDeviceIdentity: const DeviceIdentity(
          deviceName: 'Studio Mac',
          deviceId: 'synthetic-device',
          platform: OrbPlatform.macos,
        ),
      );
      const selectedChannel = EligibleChannel(
        guildId: 'g1',
        guildName: 'Orb Guild',
        channelId: 'c1',
        channelName: 'general',
      );

      var reselectCalls = 0;
      var signedOutCalls = 0;
      var backendChangedCalls = 0;
      ChatListLayout? changedLayout;

      await tester.pumpWidget(
        _wrapWithApp(
          Scaffold(
            body: SessionSettingsSheet(
              authRepository: authRepo,
              selectedChannel: selectedChannel,
              chatListLayout: ChatListLayout.standard,
              onChatListLayoutChanged: (layout) => changedLayout = layout,
              onReselectChannel: () => reselectCalls++,
              onSignedOut: () => signedOutCalls++,
              onBackendChanged: () => backendChangedCalls++,
            ),
          ),
        ),
      );

      expect(find.text('https://orb.example.com'), findsOneWidget);
      expect(find.text('Studio Mac (macOS)'), findsOneWidget);
      expect(find.text('Orb Guild · #general'), findsOneWidget);
      expect(find.byKey(SessionSettingsSheet.layoutSelectorKey), findsOneWidget);

      await tester.tap(find.text('Compact'));
      await tester.pump();
      expect(changedLayout, ChatListLayout.compact);

      await tester.tap(find.byKey(const Key('settings_reselect_channel_button')));
      await tester.pump();
      expect(reselectCalls, 1);

      await tester.tap(find.byKey(const Key('settings_sign_out_button')));
      await tester.pumpAndSettle();
      expect(authRepo.signOutCalls, 1);
      expect(signedOutCalls, 1);

      await tester.tap(find.byKey(const Key('settings_change_backend_button')));
      await tester.pumpAndSettle();
      expect(authRepo.clearBackendStateCalls, 1);
      expect(backendChangedCalls, 1);
    });
  });
}
