import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:discord_orb/api/preview_repository_impl.dart';
import 'package:discord_orb/app.dart';
import 'package:discord_orb/auth/auth_repository_impl.dart';
import 'package:discord_orb/auth/oauth_loopback_listener.dart';
import 'package:discord_orb/auth/oauth_scheme_listener.dart';
import 'package:discord_orb/auth/pkce.dart';
import 'package:discord_orb/auth/token_manager.dart';
import 'package:discord_orb/contracts/auth_repository.dart';
import 'package:discord_orb/core/device_identity_store.dart';
import 'package:discord_orb/core/http_client.dart';
import 'package:discord_orb/core/https_validator.dart';
import 'package:discord_orb/models/orb_error.dart';
import 'package:discord_orb/models/session_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RecordingBrowserLauncher implements SystemBrowserLauncher {
  final List<Uri> launchedUris = <Uri>[];
  Future<void> Function(Uri uri)? onLaunch;

  @override
  Future<void> launch(Uri uri) async {
    launchedUris.add(uri);
    final callback = onLaunch;
    if (callback != null) {
      await callback(uri);
    }
  }
}

class _RealHttpOverrides extends HttpOverrides {}

Future<void> _withRealLoopbackHttpClient(
  Future<void> Function(HttpClient client) action,
) {
  return HttpOverrides.runWithHttpOverrides(
    () async {
      final client = HttpClient();
      try {
        await action(client);
      } finally {
        client.close(force: true);
      }
    },
    _RealHttpOverrides(),
  );
}

OrbSessionTokens _makeTokens({
  String accessToken = 'synthetic-access-1',
  String refreshToken = 'synthetic-refresh-1',
  Duration accessTtl = const Duration(minutes: 15),
  Duration sessionTtl = const Duration(days: 30),
  DateTime? now,
}) {
  final base = (now ?? DateTime.utc(2026, 11, 19, 12, 0)).toUtc();
  return OrbSessionTokens(
    accessToken: accessToken,
    refreshToken: refreshToken,
    accessExpiresAt: base.add(accessTtl),
    sessionExpiresAt: base.add(sessionTtl),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HttpsValidator', () {
    test('accepts and normalizes valid https backend URLs', () {
      final normalized = HttpsValidator.validateBackendBaseUrl(
        '  https://Orb.Example.COM:8443/api/  ',
      );
      expect(normalized.toString(), 'https://orb.example.com:8443/api');

      final endpoint = HttpsValidator.resolveEndpoint(
        normalized.toString(),
        '/healthz',
      );
      expect(endpoint.toString(), 'https://orb.example.com:8443/api/healthz');
    });

    test('rejects http, other schemes, userinfo, missing host, and 127.0.0.1',
        () {
      final rejected = <String>[
        '',
        'http://orb.example.com',
        'ftp://orb.example.com',
        'discordorb://auth/callback',
        'https://',
        'https://user:pass@orb.example.com',
        'https://user@orb.example.com',
        'https://127.0.0.1:8443',
        'http://127.0.0.1:8080',
        'https://[::1]:8443',
        'https://orb.example.com?foo=bar',
        'https://orb.example.com#frag',
      ];

      for (final raw in rejected) {
        expect(
          () => HttpsValidator.validateBackendBaseUrl(raw),
          throwsA(
            isA<OrbException>().having(
              (e) => e.state,
              'state',
              OrbPreviewState.networkError,
            ),
          ),
          reason: 'Expected "$raw" to be rejected',
        );
      }
    });

    test('validateRedirectUri blocks http downgrade and invalid targets', () {
      final current = Uri.parse('https://orb.example.com/api/v1/channels');

      expect(
        () => HttpsValidator.validateRedirectUri(
          current,
          'http://orb.example.com/api/v1/channels',
        ),
        throwsA(
          isA<OrbException>().having(
            (e) => e.code,
            'code',
            'https_downgrade_redirect',
          ),
        ),
      );

      expect(
        () => HttpsValidator.validateRedirectUri(
          current,
          'https://user:secret@orb.example.com/next',
        ),
        throwsA(
          isA<OrbException>().having(
            (e) => e.code,
            'code',
            'userinfo_not_allowed',
          ),
        ),
      );

      expect(
        HttpsValidator.validateRedirectUri(current, '/v2/channels').toString(),
        'https://orb.example.com/v2/channels',
      );
    });
  });

  group('OrbHttpClient', () {
    test('blocks plaintext http:// before touching inner client', () async {
      var calls = 0;
      final mockInner = MockClient((request) async {
        calls++;
        return http.Response('ok', 200);
      });
      final client = OrbHttpClient(inner: mockInner);
      addTearDown(client.close);

      await expectLater(
        client.get(Uri.parse('http://orb.example.com/healthz')),
        throwsA(
          isA<OrbException>().having(
            (e) => e.code,
            'code',
            'insecure_http_scheme',
          ),
        ),
      );
      expect(calls, 0);
    });

    test('disables followRedirects and blocks http downgrade without sending credentials',
        () async {
      final requestedUris = <Uri>[];
      final followRedirectFlags = <bool>[];
      final mockInner = MockClient((request) async {
        requestedUris.add(request.url);
        followRedirectFlags.add(request.followRedirects);
        return http.Response(
          '',
          302,
          headers: <String, String>{
            'location': 'http://downgraded.example.com/steal',
          },
        );
      });

      final client = OrbHttpClient(inner: mockInner);
      addTearDown(client.close);

      await expectLater(
        client.get(
          Uri.parse('https://orb.example.com/api/v1/channels'),
          headers: const <String, String>{
            'authorization': 'Bearer synthetic-secret-token',
          },
        ),
        throwsA(
          isA<OrbException>().having(
            (e) => e.code,
            'code',
            'https_downgrade_redirect',
          ),
        ),
      );

      expect(followRedirectFlags, <bool>[false]);
      expect(requestedUris, <Uri>[
        Uri.parse('https://orb.example.com/api/v1/channels'),
      ]);
    });

    test('strips sensitive headers on cross-origin https redirects and keeps same-origin',
        () async {
      final capturedHeaders = <Map<String, String>>[];
      final mockInner = MockClient((request) async {
        capturedHeaders.add(Map<String, String>.from(request.headers));
        if (request.url.host == 'orb.example.com' &&
            request.url.path == '/step1') {
          return http.Response(
            '',
            302,
            headers: const <String, String>{'location': '/step2'},
          );
        }
        if (request.url.host == 'orb.example.com' &&
            request.url.path == '/step2') {
          return http.Response(
            '',
            302,
            headers: const <String, String>{
              'location': 'https://cdn.other.example/final',
            },
          );
        }
        return http.Response('{"ok":true}', 200);
      });

      final client = OrbHttpClient(inner: mockInner);
      addTearDown(client.close);

      final response = await client.get(
        Uri.parse('https://orb.example.com/step1'),
        headers: const <String, String>{
          'authorization': 'Bearer synthetic-token',
          'cookie': 'session=abc',
        },
      );

      expect(response.statusCode, 200);
      expect(capturedHeaders, hasLength(3));
      expect(capturedHeaders[0]['authorization'], 'Bearer synthetic-token');
      expect(capturedHeaders[1]['authorization'], 'Bearer synthetic-token');
      expect(capturedHeaders[2].containsKey('authorization'), isFalse);
      expect(capturedHeaders[2].containsKey('cookie'), isFalse);
    });

    test('strict IoHttpClient configures badCertificateCallback and surfaces TLS failures',
        () async {
      final ioClient = OrbHttpClient.createStrictIoHttpClient();
      addTearDown(ioClient.close);
      expect(ioClient, isA<HttpClient>());

      final tlsFailingClient = OrbHttpClient(
        inner: MockClient((_) async {
          throw const HandshakeException('Certificate verify failed');
        }),
      );
      addTearDown(tlsFailingClient.close);

      await expectLater(
        tlsFailingClient.get(Uri.parse('https://orb.example.com/healthz')),
        throwsA(
          isA<OrbException>()
              .having((e) => e.code, 'code', 'tls_handshake_failed')
              .having((e) => e.state, 'state', OrbPreviewState.networkError),
        ),
      );
    });
  });

  group('DeviceIdentityStore', () {
    test('binds random device_id per backend and wipes old state on backend change',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
        defaultDeviceName: 'Test Mac',
      );

      final idA1 = await identityStore.configureBackend('https://a.example.com/');
      final idA2 = await identityStore.configureBackend('https://a.example.com');
      expect(idA1.deviceId, isNotEmpty);
      expect(idA2.deviceId, idA1.deviceId);
      expect(idA1.deviceName, 'Test Mac');
      expect(idA1.platform, OrbPlatform.macos);

      final tokensA = _makeTokens(accessToken: 'synthetic-a-access');
      await identityStore.saveSessionTokens('https://a.example.com', tokensA);
      await identityStore.saveSelectedChannel('g1:c1');
      expect(
        await identityStore.readSessionTokens('https://a.example.com'),
        tokensA,
      );
      expect(await identityStore.readSelectedChannel(), 'g1:c1');

      // Switch to backend B: old tokens, selected channel, and memory wiped.
      final idB = await identityStore.configureBackend('https://b.example.com');
      expect(idB.deviceId, isNotEmpty);
      expect(idB.deviceId, isNot(idA1.deviceId));
      expect(
        await identityStore.readSessionTokens('https://a.example.com'),
        isNull,
      );
      expect(await identityStore.readSelectedChannel(), isNull);
      expect(await kvStore.read(DeviceIdentityStore.selectedChannelKey), isNull);
      expect(identityStore.cachedTokens, isNull);
      expect(identityStore.cachedSelectedChannel, isNull);
      expect(
        await identityStore.readActiveBackendUrl(),
        'https://b.example.com',
      );
    });

    test('generateDeviceId uses Random.secure UUID v4 format', () {
      final kvStore = InMemorySecureKeyValueStore();
      final store = DeviceIdentityStore(
        store: kvStore,
        random: Random.secure(),
      );

      final first = store.generateDeviceId();
      final second = store.generateDeviceId();
      final uuidV4Pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidV4Pattern.hasMatch(first), isTrue);
      expect(uuidV4Pattern.hasMatch(second), isTrue);
      expect(first, isNot(second));
    });
  });

  group('PkcePair', () {
    test('computes RFC 7636 S256 challenge without padding', () {
      const rfcVerifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const rfcExpectedChallenge =
          'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

      expect(PkcePair.computeS256Challenge(rfcVerifier), rfcExpectedChallenge);

      final generated = PkcePair.generate();
      expect(generated.codeChallengeMethod, 'S256');
      expect(generated.codeVerifier.length, inInclusiveRange(43, 128));
      expect(generated.codeVerifier.contains('='), isFalse);
      expect(generated.codeChallenge.contains('='), isFalse);
      expect(generated.state.contains('='), isFalse);
      expect(
        PkcePair.computeS256Challenge(generated.codeVerifier),
        generated.codeChallenge,
      );
    });
  });

  group('OAuthLoopbackListener', () {
    test('receives ticket and state on 127.0.0.1 ephemeral port and closes',
        () async {
      final listener = OAuthLoopbackListener();
      final redirectUri = await listener.start();
      expect(redirectUri.scheme, 'http');
      expect(redirectUri.host, '127.0.0.1');
      expect(redirectUri.port, greaterThan(0));
      expect(redirectUri.path, '/callback');

      final resultFuture = listener.waitForCallback(
        expectedState: 'state-123',
        timeout: const Duration(seconds: 5),
      );

      await _withRealLoopbackHttpClient((rawHttp) async {
        // Unrelated paths like /favicon.ico should not abort the listener.
        final faviconReq = await rawHttp.getUrl(
          redirectUri.replace(path: '/favicon.ico'),
        );
        final faviconResp = await faviconReq.close();
        await faviconResp.drain<void>();
        expect(faviconResp.statusCode, HttpStatus.notFound);

        final cbReq = await rawHttp.getUrl(
          redirectUri.replace(
            queryParameters: const <String, String>{
              'ticket': 'synthetic-ticket-abc',
              'state': 'state-123',
            },
          ),
        );
        final cbResp = await cbReq.close();
        final body = await utf8.decoder.bind(cbResp).join();
        expect(cbResp.statusCode, HttpStatus.ok);
        expect(body, isNot(contains('synthetic-ticket-abc')));
      });

      final result = await resultFuture;
      expect(result.ticket, 'synthetic-ticket-abc');
      expect(result.state, 'state-123');
      expect(listener.redirectUri, isNull);
    });

    test('supports cancel and state mismatch rejection', () async {
      final cancelListener = OAuthLoopbackListener();
      await cancelListener.start();
      final waitCancel = cancelListener.waitForCallback();
      final cancelExpectation = expectLater(
        waitCancel,
        throwsA(
          isA<OrbException>().having((e) => e.code, 'code', 'oauth_cancelled'),
        ),
      );
      await cancelListener.cancel();
      await cancelExpectation;

      final mismatchListener = OAuthLoopbackListener();
      final uri = await mismatchListener.start();
      final waitMismatch = mismatchListener.waitForCallback(
        expectedState: 'expected-state',
      );
      final mismatchExpectation = expectLater(
        waitMismatch,
        throwsA(
          isA<OrbException>().having(
            (e) => e.code,
            'code',
            'oauth_state_mismatch',
          ),
        ),
      );

      await _withRealLoopbackHttpClient((rawHttp) async {
        final req = await rawHttp.getUrl(
          uri.replace(
            queryParameters: const <String, String>{
              'ticket': 'synthetic-ticket',
              'state': 'wrong-state',
            },
          ),
        );
        final resp = await req.close();
        await resp.drain<void>();
        expect(resp.statusCode, HttpStatus.badRequest);
      });

      await mismatchExpectation;
    });
  });

  group('OAuthSchemeListener', () {
    test('parses discordorb://auth/callback via MethodChannel getInitialLink & onLink',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel(OrbPlatformChannels.authLinks);

      // 1. Test getInitialLink delivery
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'getInitialLink') {
          return 'discordorb://auth/callback?ticket=synthetic-init&state=st-1';
        }
        return null;
      });

      final initialListener = OAuthSchemeListener(channel: channel);
      addTearDown(initialListener.dispose);

      final initialResult = await initialListener.waitForCallback(
        expectedState: 'st-1',
        timeout: const Duration(seconds: 2),
      );
      expect(initialResult.ticket, 'synthetic-init');
      expect(initialResult.state, 'st-1');

      // 2. Test onLink delivery from native platform
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'getInitialLink') return null;
        return null;
      });

      final streamListener = OAuthSchemeListener(channel: channel);
      addTearDown(streamListener.dispose);

      final pending = streamListener.waitForCallback(
        expectedState: 'st-2',
        timeout: const Duration(seconds: 2),
      );

      await Future<void>.delayed(Duration.zero);
      await messenger.handlePlatformMessage(
        OrbPlatformChannels.authLinks,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall(
            'onLink',
            'discordorb://auth/callback?ticket=synthetic-live&state=st-2',
          ),
        ),
        (_) {},
      );

      final liveResult = await pending;
      expect(liveResult.ticket, 'synthetic-live');
      expect(liveResult.state, 'st-2');

      messenger.setMockMethodCallHandler(channel, null);
    });

    test('supports injected custom linkStream and rejects mismatched state',
        () async {
      final controller = StreamController<String>.broadcast();
      addTearDown(controller.close);

      final listener = OAuthSchemeListener(
        linkStream: controller.stream,
        getInitialLinkOverride: () async => null,
      );
      addTearDown(listener.dispose);

      final future = listener.waitForCallback(expectedState: 'expected');
      await Future<void>.delayed(Duration.zero);
      controller.add(
        'discordorb://auth/callback?ticket=t1&state=forged-state',
      );

      await expectLater(
        future,
        throwsA(
          isA<OrbException>().having(
            (e) => e.code,
            'code',
            'oauth_state_mismatch',
          ),
        ),
      );
    });
  });

  group('TokenManager & AuthRepositoryImpl', () {
    test('validateAndProbeBackend, desktop signInWithDiscord, and signOut',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
        defaultDeviceName: 'MacBook Pro',
      );

      String? capturedAuthHeaderOnLogout;
      Map<String, dynamic>? capturedExchangeBody;

      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/healthz') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'status': 'ok',
                'setup_required': false,
                'missing_env_names': <String>[],
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/v1/auth/exchange') {
            capturedExchangeBody =
                jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode(
                _makeTokens(
                  accessToken: 'synthetic-access-login',
                  refreshToken: 'synthetic-refresh-login',
                ).toJson(),
              ),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/api/v1/auth/logout') {
            capturedAuthHeaderOnLogout = request.headers['authorization'];
            return http.Response(
              jsonEncode(<String, dynamic>{'revoked': true}),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => DateTime.utc(2026, 11, 19, 12, 0),
      );

      final browserLauncher = _RecordingBrowserLauncher();
      browserLauncher.onLaunch = (Uri loginUri) async {
        expect(loginUri.scheme, 'https');
        expect(loginUri.path, '/auth/discord/login');
        expect(loginUri.queryParameters['code_challenge_method'], 'S256');
        final redirect =
            Uri.parse(loginUri.queryParameters['redirect_uri']!);
        final state = loginUri.queryParameters['state']!;
        expect(redirect.scheme, 'http');
        expect(redirect.host, '127.0.0.1');

        await _withRealLoopbackHttpClient((rawHttp) async {
          final req = await rawHttp.getUrl(
            redirect.replace(
              queryParameters: <String, String>{
                'ticket': 'synthetic-exchange-ticket',
                'state': state,
              },
            ),
          );
          final resp = await req.close();
          await resp.drain<void>();
        });
      };

      final authRepo = AuthRepositoryImpl(
        identityStore: identityStore,
        httpClient: httpClient,
        tokenManager: tokenManager,
        browserLauncher: browserLauncher,
        platform: OrbPlatform.macos,
      );

      final health =
          await authRepo.validateAndProbeBackend('https://orb.example.com');
      expect(health.setupRequired, isFalse);

      await authRepo.configureBackend('https://orb.example.com');
      final tokens = await authRepo.signInWithDiscord();
      expect(tokens.accessToken, 'synthetic-access-login');
      expect(capturedExchangeBody, isNotNull);
      expect(capturedExchangeBody!['ticket'], 'synthetic-exchange-ticket');
      expect(capturedExchangeBody!['platform'], 'macos');
      expect(
        PkcePair.computeS256Challenge(
          capturedExchangeBody!['code_verifier'] as String,
        ),
        browserLauncher.launchedUris.single.queryParameters['code_challenge'],
      );
      expect(await authRepo.loadStoredSession(), tokens);

      await identityStore.saveSelectedChannel('g1:c1');
      await authRepo.signOut();
      expect(
        capturedAuthHeaderOnLogout,
        'Bearer synthetic-access-login',
      );
      expect(await authRepo.loadStoredSession(), isNull);
      expect(await identityStore.readSelectedChannel(), isNull);
    });

    test('Android signInWithDiscord uses custom scheme listener', () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.android,
        defaultDeviceName: 'Pixel Test',
      );

      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          if (request.url.path == '/api/v1/auth/exchange') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['platform'], 'android');
            return http.Response(
              jsonEncode(
                _makeTokens(accessToken: 'synthetic-android-access').toJson(),
              ),
              200,
            );
          }
          return http.Response('unexpected', 500);
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => DateTime.utc(2026, 11, 19, 12, 0),
      );

      final linkController = StreamController<String>.broadcast();
      addTearDown(linkController.close);
      final schemeListener = OAuthSchemeListener(
        linkStream: controllerStream(linkController),
        getInitialLinkOverride: () async => null,
      );
      addTearDown(schemeListener.dispose);

      final browserLauncher = _RecordingBrowserLauncher()
        ..onLaunch = (Uri loginUri) async {
          expect(
            loginUri.queryParameters['redirect_uri'],
            'discordorb://auth/callback',
          );
          final state = loginUri.queryParameters['state']!;
          scheduleMicrotask(() {
            linkController.add(
              'discordorb://auth/callback?ticket=synthetic-android-ticket&state=$state',
            );
          });
        };

      final authRepo = AuthRepositoryImpl(
        identityStore: identityStore,
        httpClient: httpClient,
        tokenManager: tokenManager,
        browserLauncher: browserLauncher,
        schemeListener: schemeListener,
        platform: OrbPlatform.android,
      );

      await authRepo.configureBackend('https://orb.example.com');
      final tokens = await authRepo.signInWithDiscord();
      expect(tokens.accessToken, 'synthetic-android-access');
    });

    test('concurrent refreshAccessToken calls execute POST /api/v1/auth/refresh once',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
      );
      final fixedNow = DateTime.utc(2026, 11, 19, 12, 0);
      await identityStore.configureBackend('https://orb.example.com');
      await identityStore.saveSessionTokens(
        'https://orb.example.com',
        _makeTokens(
          accessToken: 'synthetic-old-access',
          refreshToken: 'synthetic-old-refresh',
          now: fixedNow,
        ),
      );

      var refreshCallCount = 0;
      final gate = Completer<void>();
      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          expect(request.url.path, '/api/v1/auth/refresh');
          refreshCallCount++;
          await gate.future;
          return http.Response(
            jsonEncode(
              _makeTokens(
                accessToken: 'synthetic-rotated-access',
                refreshToken: 'synthetic-rotated-refresh',
                now: fixedNow,
              ).toJson(),
            ),
            200,
          );
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => fixedNow,
      );

      final futures = List<Future<OrbSessionTokens>>.generate(
        5,
        (_) => tokenManager.refreshAccessToken('https://orb.example.com'),
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete();

      final results = await Future.wait(futures);
      expect(refreshCallCount, 1);
      for (final result in results) {
        expect(result.accessToken, 'synthetic-rotated-access');
        expect(result.refreshToken, 'synthetic-rotated-refresh');
      }
    });

    test('401 on refresh deletes stored tokens and throws sessionExpired',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
      );
      final fixedNow = DateTime.utc(2026, 11, 19, 12, 0);
      await identityStore.configureBackend('https://orb.example.com');
      await identityStore.saveSessionTokens(
        'https://orb.example.com',
        _makeTokens(now: fixedNow),
      );

      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          return http.Response(
            jsonEncode(<String, String>{
              'code': 'token_reused',
              'detail': 'Refresh token was already rotated.',
            }),
            401,
          );
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => fixedNow,
      );

      await expectLater(
        tokenManager.refreshAccessToken('https://orb.example.com'),
        throwsA(
          isA<OrbException>()
              .having((e) => e.state, 'state', OrbPreviewState.sessionExpired)
              .having((e) => e.code, 'code', 'token_reused'),
        ),
      );
      expect(
        await identityStore.readSessionTokens('https://orb.example.com'),
        isNull,
      );
    });
  });

  group('PreviewRepositoryImpl', () {
    test('fetchEligibleGuilds retries once after serialized 401 refresh',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
      );
      final fixedNow = DateTime.utc(2026, 11, 19, 12, 0);
      const backend = 'https://orb.example.com';
      await identityStore.configureBackend(backend);
      await identityStore.saveSessionTokens(
        backend,
        _makeTokens(
          accessToken: 'synthetic-expired-access',
          refreshToken: 'synthetic-refresh-1',
          now: fixedNow,
        ),
      );

      var refreshCount = 0;
      var channelAttempts = 0;
      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          if (request.url.path == '/api/v1/channels') {
            channelAttempts++;
            final auth = request.headers['authorization'];
            if (auth == 'Bearer synthetic-expired-access') {
              return http.Response(
                jsonEncode(<String, String>{
                  'code': 'session_expired',
                  'detail': 'Access token expired',
                }),
                401,
              );
            }
            if (auth == 'Bearer synthetic-fresh-access') {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'guilds': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'guild_id': 'g-1',
                      'guild_name': 'Orb Guild',
                      'channels': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'guild_id': 'g-1',
                          'guild_name': 'Orb Guild',
                          'channel_id': 'c-1',
                          'channel_name': 'general',
                        },
                      ],
                    },
                  ],
                }),
                200,
              );
            }
          }
          if (request.url.path == '/api/v1/auth/refresh') {
            refreshCount++;
            return http.Response(
              jsonEncode(
                _makeTokens(
                  accessToken: 'synthetic-fresh-access',
                  refreshToken: 'synthetic-refresh-2',
                  now: fixedNow,
                ).toJson(),
              ),
              200,
            );
          }
          return http.Response('unexpected', 500);
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => fixedNow,
      );
      final previewRepo = PreviewRepositoryImpl(
        httpClient: httpClient,
        tokenManager: tokenManager,
        backendBaseUrlProvider: () => backend,
      );

      final guilds = await previewRepo.fetchEligibleGuilds();
      expect(refreshCount, 1);
      expect(channelAttempts, 2);
      expect(guilds, hasLength(1));
      expect(guilds.single.channels.single.channelName, 'general');
    });

    test('fetchLatestMessages keeps single in-flight request and discards late responses',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
      );
      final fixedNow = DateTime.utc(2026, 11, 19, 12, 0);
      const backend = 'https://orb.example.com';
      await identityStore.configureBackend(backend);
      await identityStore.saveSessionTokens(
        backend,
        _makeTokens(accessToken: 'synthetic-valid-access', now: fixedNow),
      );

      final firstGate = Completer<void>();
      final secondGate = Completer<void>();

      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          if (request.url.path.contains('/c-1/messages')) {
            await firstGate.future;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'guild_id': 'g-1',
                'channel_id': 'c-1',
                'messages': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'stale-msg',
                    'author_name': 'old',
                    'timestamp': '2026-11-19T11:00:00Z',
                    'content': 'stale response',
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path.contains('/c-2/messages')) {
            await secondGate.future;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'guild_id': 'g-1',
                'channel_id': 'c-2',
                'messages': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'fresh-msg',
                    'author_name': 'alice',
                    'timestamp': '2026-11-19T11:59:00Z',
                    'content': 'latest message',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('unexpected', 404);
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => fixedNow,
      );
      final previewRepo = PreviewRepositoryImpl(
        httpClient: httpClient,
        tokenManager: tokenManager,
        backendBaseUrlProvider: () => backend,
      );

      final token1 = Object();
      final token2 = Object();

      final f1 = previewRepo.fetchLatestMessages(
        guildId: 'g-1',
        channelId: 'c-1',
        requestToken: token1,
      );
      expect(previewRepo.activeRequestToken, token1);

      final f2 = previewRepo.fetchLatestMessages(
        guildId: 'g-1',
        channelId: 'c-2',
        requestToken: token2,
      );
      expect(previewRepo.activeRequestToken, token2);

      await expectLater(
        f1,
        throwsA(
          isA<OrbException>().having((e) => e.code, 'code', 'preview_cancelled'),
        ),
      );

      // Complete second request first, then release delayed first response.
      secondGate.complete();
      final messages2 = await f2;
      expect(messages2, hasLength(1));
      expect(messages2.single.id, 'fresh-msg');

      firstGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(previewRepo.cachedMessages?.single.id, 'fresh-msg');

      // cancelActivePreview & clearMemory discard in-flight and cached state.
      final token3 = Object();
      final f3 = previewRepo.fetchLatestMessages(
        guildId: 'g-1',
        channelId: 'c-1',
        requestToken: token3,
      );
      previewRepo.clearMemory();
      await expectLater(
        f3,
        throwsA(
          isA<OrbException>().having((e) => e.code, 'code', 'preview_cancelled'),
        ),
      );
      expect(previewRepo.cachedMessages, isNull);
      expect(previewRepo.cachedGuilds, isNull);
      expect(previewRepo.activeRequestToken, isNull);
    });

    test('discards in-flight preview response when session epoch changes',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
      );
      final fixedNow = DateTime.utc(2026, 11, 19, 12, 0);
      const backend = 'https://orb.example.com';
      await identityStore.configureBackend(backend);
      await identityStore.saveSessionTokens(
        backend,
        _makeTokens(accessToken: 'synthetic-access', now: fixedNow),
      );

      final gate = Completer<void>();
      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          await gate.future;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'guild_id': 'g-1',
              'channel_id': 'c-1',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'm-old-session',
                  'author_name': 'bob',
                  'timestamp': '2026-11-19T11:00:00Z',
                  'content': 'should be discarded',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => fixedNow,
      );
      final previewRepo = PreviewRepositoryImpl(
        httpClient: httpClient,
        tokenManager: tokenManager,
        backendBaseUrlProvider: () => backend,
      );

      final future = previewRepo.fetchLatestMessages(
        guildId: 'g-1',
        channelId: 'c-1',
        requestToken: Object(),
      );
      final expectation = expectLater(
        future,
        throwsA(
          isA<OrbException>().having((e) => e.code, 'code', 'preview_cancelled'),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Session invalidated before HTTP response resolves.
      await tokenManager.invalidateSession(backend);
      gate.complete();

      await expectation;
      expect(previewRepo.cachedMessages, isNull);
    });

    test('maps 401, 403, 503, 429, and network errors to typed OrbException',
        () async {
      final kvStore = InMemorySecureKeyValueStore();
      final identityStore = DeviceIdentityStore(
        store: kvStore,
        defaultPlatform: OrbPlatform.macos,
      );
      final fixedNow = DateTime.utc(2026, 11, 19, 12, 0);
      const backend = 'https://orb.example.com';

      var nextChannelId = '';
      final httpClient = OrbHttpClient(
        inner: MockClient((request) async {
          if (request.url.path == '/api/v1/auth/refresh') {
            return http.Response(
              jsonEncode(<String, String>{
                'code': 'session_revoked',
                'detail': 'Revoked',
              }),
              401,
            );
          }
          switch (nextChannelId) {
            case '401':
              return http.Response(
                jsonEncode(<String, String>{
                  'code': 'session_expired',
                  'detail': 'Expired',
                }),
                401,
              );
            case '403':
              return http.Response(
                jsonEncode(<String, String>{
                  'code': 'access_denied',
                  'detail': 'No permission',
                }),
                403,
              );
            case '503':
              return http.Response(
                jsonEncode(<String, String>{
                  'code': 'bot_unavailable',
                  'detail': 'Bot offline',
                }),
                503,
              );
            case '429':
              return http.Response(
                jsonEncode(<String, String>{
                  'code': 'rate_limited',
                  'detail': 'Slow down',
                }),
                429,
                headers: const <String, String>{'retry-after': '12'},
              );
            case 'net':
              throw const SocketException('Connection refused');
            default:
              return http.Response('ok', 200);
          }
        }),
      );
      addTearDown(httpClient.close);

      final tokenManager = TokenManager(
        httpClient: httpClient,
        identityStore: identityStore,
        now: () => fixedNow,
      );
      final previewRepo = PreviewRepositoryImpl(
        httpClient: httpClient,
        tokenManager: tokenManager,
        backendBaseUrlProvider: () => backend,
      );

      Future<void> seedTokens() async {
        await identityStore.configureBackend(backend);
        await identityStore.saveSessionTokens(
          backend,
          _makeTokens(accessToken: 'synthetic-access', now: fixedNow),
        );
      }

      await seedTokens();
      nextChannelId = '403';
      await expectLater(
        previewRepo.fetchLatestMessages(
          guildId: 'g',
          channelId: '403',
          requestToken: Object(),
        ),
        throwsA(
          isA<OrbException>()
              .having((e) => e.state, 'state', OrbPreviewState.accessDenied)
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );

      nextChannelId = '503';
      await expectLater(
        previewRepo.fetchLatestMessages(
          guildId: 'g',
          channelId: '503',
          requestToken: Object(),
        ),
        throwsA(
          isA<OrbException>()
              .having((e) => e.state, 'state', OrbPreviewState.botUnavailable)
              .having((e) => e.statusCode, 'statusCode', 503),
        ),
      );

      nextChannelId = '429';
      await expectLater(
        previewRepo.fetchLatestMessages(
          guildId: 'g',
          channelId: '429',
          requestToken: Object(),
        ),
        throwsA(
          isA<OrbException>()
              .having((e) => e.state, 'state', OrbPreviewState.rateLimited)
              .having((e) => e.statusCode, 'statusCode', 429)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 12),
              ),
        ),
      );

      nextChannelId = 'net';
      await expectLater(
        previewRepo.fetchLatestMessages(
          guildId: 'g',
          channelId: 'net',
          requestToken: Object(),
        ),
        throwsA(
          isA<OrbException>().having(
            (e) => e.state,
            'state',
            OrbPreviewState.networkError,
          ),
        ),
      );

      nextChannelId = '401';
      await expectLater(
        previewRepo.fetchLatestMessages(
          guildId: 'g',
          channelId: '401',
          requestToken: Object(),
        ),
        throwsA(
          isA<OrbException>().having(
            (e) => e.state,
            'state',
            OrbPreviewState.sessionExpired,
          ),
        ),
      );
    });
  });
}

Stream<String> controllerStream(StreamController<String> controller) =>
    controller.stream;
