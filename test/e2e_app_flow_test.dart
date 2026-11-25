import 'dart:async';
import 'dart:convert';

import 'package:discord_orb/app.dart';
import 'package:discord_orb/auth/oauth_loopback_listener.dart';
import 'package:discord_orb/auth/oauth_scheme_listener.dart';
import 'package:discord_orb/contracts/auth_repository.dart';
import 'package:discord_orb/contracts/orb_window_controller.dart';
import 'package:discord_orb/core/device_identity_store.dart';
import 'package:discord_orb/core/http_client.dart';
import 'package:discord_orb/models/session_models.dart';
import 'package:discord_orb/ui/orb/orb_button.dart';
import 'package:discord_orb/ui/panel/panel_status_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _TestLoopbackListener extends OAuthLoopbackListener {
  Completer<OAuthCallbackResult>? _completer;
  final Uri _redirectUri = Uri.parse('http://127.0.0.1:49152/callback');
  String? _expectedState;

  @override
  Uri get redirectUri => _redirectUri;

  @override
  Future<Uri> start({String callbackPath = '/callback'}) async {
    _completer = Completer<OAuthCallbackResult>();
    return _redirectUri;
  }

  @override
  Future<OAuthCallbackResult> waitForCallback({
    Duration timeout = const Duration(minutes: 5),
    String? expectedState,
  }) {
    _expectedState = expectedState;
    return _completer!.future.timeout(timeout);
  }

  void completeCallback({required String ticket, required String state}) {
    if (_expectedState != null && state != _expectedState) {
      _completer?.completeError(StateError('Mismatched state'));
      return;
    }
    _completer?.complete(OAuthCallbackResult(ticket: ticket, state: state));
  }

  @override
  Future<void> cancel() async {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('Cancelled'));
    }
  }

  @override
  Future<void> close() async {}
}

class _FakeBrowserLauncher implements SystemBrowserLauncher {
  _FakeBrowserLauncher(this.onLaunch);

  final Future<void> Function(Uri uri) onLaunch;
  final List<Uri> launchedUris = <Uri>[];

  @override
  Future<void> launch(Uri uri) async {
    launchedUris.add(uri);
    await onLaunch(uri);
  }
}

class _TrackingWindowController extends NoopOrbWindowController {
  int showCollapsedOrbCalls = 0;
  int expandPanelCalls = 0;
  int collapsePanelCalls = 0;
  int hideOrbCalls = 0;
  int showMainWindowCalls = 0;
  final List<Offset> moveOrbDeltas = <Offset>[];

  @override
  Future<void> showCollapsedOrb() async {
    showCollapsedOrbCalls++;
  }

  @override
  Future<void> expandPanel(Size size) async {
    expandPanelCalls++;
  }

  @override
  Future<void> collapsePanel() async {
    collapsePanelCalls++;
  }

  @override
  Future<void> hideOrb() async {
    hideOrbCalls++;
  }

  @override
  Future<void> moveOrbBy(Offset delta) async {
    moveOrbDeltas.add(delta);
  }

  @override
  Future<void> showMainWindow() async {
    showMainWindowCalls++;
  }
}

void main() {
  testWidgets(
    'full desktop E2E flow: setup -> login -> channel -> orb open/close -> lock clear -> access loss -> backend change',
    (WidgetTester tester) async {
      final secureStore = InMemorySecureKeyValueStore();
      final windowController = _TrackingWindowController();
      addTearDown(windowController.dispose);

      var revokeCh1Access = false;
      var activeBackendHost = 'orb.example.com';
      final List<String> seenAuthHosts = <String>[];

      final mockHttp = MockClient((http.Request request) async {
        seenAuthHosts.add('${request.method} ${request.url.host}${request.url.path}');
        final path = request.url.path;

        if (path == '/healthz') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'status': 'ok',
              'setup_required': false,
              'missing_env_names': <String>[],
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        if (path == '/api/v1/auth/exchange') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['ticket'], isNotEmpty);
          expect(body['code_verifier'], isNotEmpty);
          expect(body['platform'], 'macos');
          final now = DateTime.now().toUtc();
          return http.Response(
            jsonEncode(<String, dynamic>{
              'access_token': 'e2e-access-${request.url.host}',
              'refresh_token': 'e2e-refresh-${request.url.host}',
              'access_expires_at':
                  now.add(const Duration(minutes: 15)).toIso8601String(),
              'session_expires_at':
                  now.add(const Duration(days: 30)).toIso8601String(),
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        if (path == '/api/v1/channels') {
          expect(
            request.headers['authorization'],
            'Bearer e2e-access-$activeBackendHost',
          );
          final channels = <Map<String, dynamic>>[
            if (!revokeCh1Access)
              <String, dynamic>{
                'guild_id': 'g-1',
                'guild_name': 'Orb Guild',
                'channel_id': 'ch-1',
                'channel_name': 'general',
              },
            <String, dynamic>{
              'guild_id': 'g-1',
              'guild_name': 'Orb Guild',
              'channel_id': 'ch-2',
              'channel_name': 'updates',
            },
          ];
          return http.Response(
            jsonEncode(<String, dynamic>{
              'guilds': <Map<String, dynamic>>[
                <String, dynamic>{
                  'guild_id': 'g-1',
                  'guild_name': 'Orb Guild',
                  'channels': channels,
                },
              ],
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        if (path == '/api/v1/guilds/g-1/channels/ch-1/messages') {
          if (revokeCh1Access) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'code': 'access_denied',
                'detail': 'User lacks channel permission',
              }),
              403,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'guild_id': 'g-1',
              'channel_id': 'ch-1',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'm-1',
                  'author_name': 'Alice',
                  'timestamp': '2026-11-19T12:00:00Z',
                  'content': 'Hello from #general',
                },
                <String, dynamic>{
                  'id': 'm-2',
                  'author_name': 'Bob',
                  'timestamp': '2026-11-19T12:01:00Z',
                  'content': 'Newest message in #general',
                },
              ],
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        if (path == '/api/v1/guilds/g-1/channels/ch-2/messages') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'guild_id': 'g-1',
              'channel_id': 'ch-2',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'm-10',
                  'author_name': 'Carol',
                  'timestamp': '2026-11-19T12:05:00Z',
                  'content': 'Update channel message',
                },
              ],
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }

        return http.Response('Not Found', 404);
      });

      final orbHttpClient = OrbHttpClient(inner: mockHttp);
      addTearDown(orbHttpClient.close);

      _TestLoopbackListener? currentListener;
      final browserLauncher = _FakeBrowserLauncher((Uri loginUri) async {
        final state = loginUri.queryParameters['state']!;
        currentListener?.completeCallback(
          ticket: 'one-time-ticket-1',
          state: state,
        );
      });

      await tester.pumpWidget(
        DiscordOrbApp(
          platform: OrbPlatform.macos,
          secureStore: secureStore,
          httpClient: orbHttpClient,
          browserLauncher: browserLauncher,
          loopbackListenerFactory: () {
            currentListener = _TestLoopbackListener();
            return currentListener!;
          },
          windowController: windowController,
        ),
      );
      await tester.pumpAndSettle();

      // 1. Setup screen: enter HTTPS backend URL and continue.
      expect(find.text('Discord Orb Setup'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('backend_url_field')),
        'https://orb.example.com',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('backend_connect_button')));
      await tester.pumpAndSettle();

      // 2. Sign-in screen: perform Discord OAuth PKCE login.
      expect(find.text('Sign in with Discord'), findsWidgets);
      await tester.tap(find.byKey(const Key('sign_in_start_button')));
      await tester.pumpAndSettle();
      expect(browserLauncher.launchedUris, hasLength(1));
      expect(
        browserLauncher.launchedUris.first.path,
        '/auth/discord/login',
      );

      // 3. Channel select screen: choose #general.
      expect(find.text('Select Channel'), findsOneWidget);
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#updates'), findsOneWidget);
      await tester.tap(find.byKey(const Key('channel_tile_ch-1')));
      await tester.pumpAndSettle();

      expect(windowController.showCollapsedOrbCalls, 1);
      expect(find.byKey(OrbButton.orbButtonKey), findsOneWidget);

      // 4. Open orb -> load messages -> close orb.
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pumpAndSettle();
      expect(windowController.expandPanelCalls, 1);
      expect(find.text('Newest message in #general'), findsOneWidget);
      expect(find.text('Hello from #general'), findsOneWidget);

      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pumpAndSettle();
      expect(windowController.collapsePanelCalls, 1);
      expect(find.text('Newest message in #general'), findsNothing);

      // 5. Re-open orb, then trigger lock/sleep -> panel auto-closes and clears messages.
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Newest message in #general'), findsOneWidget);

      windowController.emitLockOrSleep();
      await tester.pumpAndSettle();
      expect(windowController.collapsePanelCalls, 2);
      expect(find.text('Newest message in #general'), findsNothing);

      // 6. Permission revoked -> opening orb prompts reselection -> pick #updates.
      revokeCh1Access = true;
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Channel access denied'), findsOneWidget);
      expect(find.text('Newest message in #general'), findsNothing);

      await tester.tap(find.byKey(PanelStatusView.reselectChannelButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Select Channel'), findsOneWidget);
      expect(windowController.showMainWindowCalls, greaterThanOrEqualTo(2));
      expect(windowController.hideOrbCalls, 0);
      expect(find.text('#general'), findsNothing);
      expect(find.text('#updates'), findsOneWidget);

      await tester.tap(find.byKey(const Key('channel_tile_ch-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Update channel message'), findsOneWidget);

      // 7. Change backend URL via SessionSettingsSheet -> clears local tokens & channel.
      await tester.tap(find.byKey(DiscordOrbApp.openSettingsButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Session Settings'), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings_change_backend_button')));
      await tester.pumpAndSettle();

      expect(find.text('Discord Orb Setup'), findsOneWidget);
      expect(find.text('Update channel message'), findsNothing);
      expect(
        await secureStore.read(DeviceIdentityStore.activeBackendUrlKey),
        isNull,
      );
      expect(
        await secureStore.read(DeviceIdentityStore.selectedChannelKey),
        isNull,
      );

      // Enter new backend URL -> proceeds to fresh sign-in screen.
      activeBackendHost = 'orb2.example.com';
      await tester.enterText(
        find.byKey(const Key('backend_url_field')),
        'https://orb2.example.com',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('backend_connect_button')));
      await tester.pumpAndSettle();

      expect(find.text('Sign in with Discord'), findsWidgets);
      expect(find.text('Backend: https://orb2.example.com'), findsOneWidget);
      expect(seenAuthHosts, contains('GET orb2.example.com/healthz'));
    },
  );

  testWidgets(
    'Android wiring uses OAuthSchemeListener custom scheme redirect',
    (WidgetTester tester) async {
      final linkController = StreamController<String>.broadcast();
      addTearDown(linkController.close);

      final schemeListener = OAuthSchemeListener(
        linkStream: linkController.stream,
        getInitialLinkOverride: () async => null,
      );
      addTearDown(schemeListener.dispose);

      final windowController = _TrackingWindowController();
      addTearDown(windowController.dispose);

      final mockHttp = MockClient((http.Request request) async {
        if (request.url.path == '/healthz') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'status': 'ok',
              'setup_required': false,
              'missing_env_names': <String>[],
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/auth/exchange') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['platform'], 'android');
          final now = DateTime.now().toUtc();
          return http.Response(
            jsonEncode(<String, dynamic>{
              'access_token': 'android-access',
              'refresh_token': 'android-refresh',
              'access_expires_at':
                  now.add(const Duration(minutes: 15)).toIso8601String(),
              'session_expires_at':
                  now.add(const Duration(days: 30)).toIso8601String(),
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/channels') {
          return http.Response(
            jsonEncode(<String, dynamic>{'guilds': <dynamic>[]}),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final orbHttpClient = OrbHttpClient(inner: mockHttp);
      addTearDown(orbHttpClient.close);

      final browserLauncher = _FakeBrowserLauncher((Uri loginUri) async {
        expect(
          loginUri.queryParameters['redirect_uri'],
          'discordorb://auth/callback',
        );
        final state = loginUri.queryParameters['state']!;
        Timer(const Duration(milliseconds: 10), () {
          linkController.add(
            'discordorb://auth/callback?ticket=android-ticket&state=$state',
          );
        });
      });

      await tester.pumpWidget(
        DiscordOrbApp(
          platform: OrbPlatform.android,
          secureStore: InMemorySecureKeyValueStore(),
          httpClient: orbHttpClient,
          browserLauncher: browserLauncher,
          schemeListener: schemeListener,
          windowController: windowController,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('backend_url_field')),
        'https://orb.example.com',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('backend_connect_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sign_in_start_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Eligible Channels'), findsOneWidget);
    },
  );

  testWidgets(
    'orb stage hides bottom channel/settings card in collapsed 80x80 window and shows it when expanded',
    (WidgetTester tester) async {
      final secureStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: secureStore,
        defaultPlatform: OrbPlatform.macos,
      );
      await identityStore.configureBackend('https://orb.example.com');
      await identityStore.saveSelectedChannel(
        jsonEncode(<String, dynamic>{
          'guild_id': 'g-1',
          'guild_name': 'Orb Guild',
          'channel_id': 'ch-1',
          'channel_name': 'general',
        }),
      );
      final now = DateTime.now().toUtc();
      await identityStore.saveSessionTokens(
        'https://orb.example.com',
        OrbSessionTokens(
          accessToken: 'stored-access',
          refreshToken: 'stored-refresh',
          accessExpiresAt: now.add(const Duration(minutes: 15)),
          sessionExpiresAt: now.add(const Duration(days: 30)),
        ),
      );

      final windowController = _TrackingWindowController();
      addTearDown(windowController.dispose);

      final orbHttpClient = OrbHttpClient(
        inner: MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'guild_id': 'g-1',
              'channel_id': 'ch-1',
              'messages': <dynamic>[],
            }),
            200,
          );
        }),
      );
      addTearDown(orbHttpClient.close);

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(80, 80);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        DiscordOrbApp(
          platform: OrbPlatform.macos,
          secureStore: secureStore,
          httpClient: orbHttpClient,
          windowController: windowController,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(OrbButton.orbButtonKey), findsOneWidget);
      expect(find.byKey(DiscordOrbApp.changeChannelButtonKey), findsNothing);
      expect(find.byKey(DiscordOrbApp.openSettingsButtonKey), findsNothing);

      // Expand viewport to desktop panel window size -> bottom controls appear.
      tester.view.physicalSize = const Size(352, 576);
      await tester.pumpAndSettle();

      expect(find.byKey(DiscordOrbApp.changeChannelButtonKey), findsOneWidget);
      expect(find.byKey(DiscordOrbApp.openSettingsButtonKey), findsOneWidget);
    },
  );
}
