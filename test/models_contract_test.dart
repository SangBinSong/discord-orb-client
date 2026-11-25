import 'dart:async';
import 'dart:ui';

import 'package:discord_orb/app.dart';
import 'package:discord_orb/contracts/auth_repository.dart';
import 'package:discord_orb/contracts/orb_window_controller.dart';
import 'package:discord_orb/models/channel_models.dart';
import 'package:discord_orb/models/message_models.dart';
import 'package:discord_orb/models/orb_error.dart';
import 'package:discord_orb/models/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('session_models', () {
    test('OrbPlatform.fromWire parses supported platforms case-insensitively',
        () {
      expect(OrbPlatform.fromWire('android'), OrbPlatform.android);
      expect(OrbPlatform.fromWire('MACOS'), OrbPlatform.macos);
      expect(OrbPlatform.fromWire('Windows'), OrbPlatform.windows);
      expect(OrbPlatform.macos.displayName, 'macOS');
      expect(() => OrbPlatform.fromWire('linux'), throwsArgumentError);
    });

    test('DeviceIdentity JSON round-trip, copyWith, and value equality', () {
      const identity = DeviceIdentity(
        deviceName: 'My Mac',
        deviceId: 'device-123',
        platform: OrbPlatform.macos,
      );

      final json = identity.toJson();
      expect(json, <String, dynamic>{
        'device_name': 'My Mac',
        'device_id': 'device-123',
        'platform': 'macos',
      });

      final decoded = DeviceIdentity.fromJson(json);
      expect(decoded, identity);
      expect(decoded.hashCode, identity.hashCode);

      final updated = identity.copyWith(platform: OrbPlatform.windows);
      expect(updated.deviceName, 'My Mac');
      expect(updated.deviceId, 'device-123');
      expect(updated.platform, OrbPlatform.windows);
      expect(updated, isNot(identity));
    });

    test('OrbSessionTokens JSON round-trip and expiration helpers', () {
      final accessExpiresAt = DateTime.utc(2026, 11, 19, 12, 15);
      final sessionExpiresAt = DateTime.utc(2026, 12, 19, 12, 0);
      final tokens = OrbSessionTokens(
        accessToken: 'synthetic-access-token',
        refreshToken: 'synthetic-refresh-token',
        accessExpiresAt: accessExpiresAt,
        sessionExpiresAt: sessionExpiresAt,
      );

      final decoded = OrbSessionTokens.fromJson(tokens.toJson());
      expect(decoded, tokens);

      expect(
        tokens.isAccessExpired(now: DateTime.utc(2026, 11, 19, 12, 14)),
        isFalse,
      );
      expect(
        tokens.isAccessExpired(now: DateTime.utc(2026, 11, 19, 12, 15)),
        isTrue,
      );
      expect(
        tokens.isSessionExpired(now: DateTime.utc(2026, 12, 19, 11, 59)),
        isFalse,
      );
      expect(
        tokens.isSessionExpired(now: DateTime.utc(2026, 12, 19, 12, 0)),
        isTrue,
      );
    });

    test('BackendHealthStatus.fromJson parses snake_case and camelCase', () {
      final snake = BackendHealthStatus.fromJson(<String, dynamic>{
        'setup_required': true,
        'missing_env_names': <String>['DISCORD_BOT_TOKEN', 'JWT_SECRET'],
      });
      expect(snake.setupRequired, isTrue);
      expect(
        snake.missingEnvNames,
        <String>['DISCORD_BOT_TOKEN', 'JWT_SECRET'],
      );

      final camel = BackendHealthStatus.fromJson(<String, dynamic>{
        'setupRequired': false,
        'missingEnvNames': <String>[],
      });
      expect(camel.setupRequired, isFalse);
      expect(camel.missingEnvNames, isEmpty);
    });
  });

  group('channel_models & message_models', () {
    test('EligibleChannel and EligibleGuild JSON round-trip and equality', () {
      const channel = EligibleChannel(
        guildId: 'g-1',
        guildName: 'Orb Guild',
        channelId: 'c-1',
        channelName: 'general',
      );
      expect(EligibleChannel.fromJson(channel.toJson()), channel);

      const guild = EligibleGuild(
        guildId: 'g-1',
        guildName: 'Orb Guild',
        channels: <EligibleChannel>[channel],
      );
      final decodedGuild = EligibleGuild.fromJson(guild.toJson());
      expect(decodedGuild, guild);
      expect(decodedGuild.hashCode, guild.hashCode);
    });

    test('ChannelMessagePreview JSON round-trip', () {
      final message = ChannelMessagePreview(
        id: 'm-1',
        authorName: 'alice',
        timestamp: DateTime.utc(2026, 11, 19, 10, 30),
        content: 'Hello Orb!',
      );
      final decoded = ChannelMessagePreview.fromJson(message.toJson());
      expect(decoded, message);
      expect(decoded.hashCode, message.hashCode);
    });
  });

  group('orb_error', () {
    test('OrbPreviewState has all expected states and OrbException stores fields',
        () {
      expect(
        OrbPreviewState.values,
        containsAll(<OrbPreviewState>[
          OrbPreviewState.idle,
          OrbPreviewState.loading,
          OrbPreviewState.loaded,
          OrbPreviewState.emptyChannel,
          OrbPreviewState.sessionExpired,
          OrbPreviewState.accessDenied,
          OrbPreviewState.botUnavailable,
          OrbPreviewState.rateLimited,
          OrbPreviewState.networkError,
        ]),
      );

      const error = OrbException(
        code: 'rate_limited',
        message: 'Slow down',
        state: OrbPreviewState.rateLimited,
        retryAfter: Duration(seconds: 5),
        statusCode: 429,
      );
      expect(error.code, 'rate_limited');
      expect(error.state, OrbPreviewState.rateLimited);
      expect(error.retryAfter, const Duration(seconds: 5));
      expect(error.statusCode, 429);
      expect(error.toString(), contains('rate_limited'));
    });
  });

  group('contracts', () {
    test('InMemorySecureKeyValueStore supports read, write, delete, clearAll',
        () async {
      final store = InMemorySecureKeyValueStore();
      expect(await store.read('k1'), isNull);

      await store.write('k1', 'v1');
      await store.write('k2', 'v2');
      expect(await store.read('k1'), 'v1');
      expect(await store.read('k2'), 'v2');

      await store.delete('k1');
      expect(await store.read('k1'), isNull);
      expect(await store.read('k2'), 'v2');

      await store.clearAll();
      expect(await store.read('k2'), isNull);
    });

    test('NoopOrbWindowController methods and test stream helpers work',
        () async {
      final controller = NoopOrbWindowController();
      expect(controller.usesNativeWindowDrag, isFalse);
      expect(await controller.hasOverlayPermission(), isTrue);
      await controller.openOverlayPermissionSettings();
      await controller.showCollapsedOrb();
      await controller.expandPanel(const Size(360, 420));
      await controller.collapsePanel();
      await controller.hideOrb();
      await controller.startOrbDrag();
      await controller.moveOrbBy(const Offset(4, 8));
      await controller.showMainWindow();

      final lockCompleter = Completer<void>();
      final dismissCompleter = Completer<void>();
      final lockSub = controller.onLockOrSleep.listen((_) {
        if (!lockCompleter.isCompleted) lockCompleter.complete();
      });
      final dismissSub = controller.onPanelDismissRequested.listen((_) {
        if (!dismissCompleter.isCompleted) dismissCompleter.complete();
      });

      controller.emitLockOrSleep();
      controller.emitPanelDismissRequested();

      await lockCompleter.future.timeout(const Duration(seconds: 1));
      await dismissCompleter.future.timeout(const Duration(seconds: 1));

      await lockSub.cancel();
      await dismissSub.cancel();
      await controller.dispose();
    });
  });

  group('app scaffold', () {
    testWidgets('DiscordOrbApp renders and exposes platform channel names',
        (WidgetTester tester) async {
      expect(DiscordOrbApp.windowChannelName, 'discord_orb/window');
      expect(DiscordOrbApp.authLinksChannelName, 'discord_orb/auth_links');

      final controller = NoopOrbWindowController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(DiscordOrbApp(windowController: controller));
      await tester.pumpAndSettle();
      expect(find.text('Discord Orb Setup'), findsOneWidget);
    });
  });
}
