import 'dart:async';

import 'package:discord_orb/app.dart';
import 'package:discord_orb/platform/android_orb_window_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = OrbPlatformChannels.window;
  const channel = MethodChannel(channelName);
  const codec = StandardMethodCodec();

  late List<MethodCall> recordedCalls;
  late bool mockOverlayPermission;
  late bool returnNullPermission;

  setUp(() {
    recordedCalls = <MethodCall>[];
    mockOverlayPermission = true;
    returnNullPermission = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      recordedCalls.add(call);
      switch (call.method) {
        case 'hasOverlayPermission':
          return returnNullPermission ? null : mockOverlayPermission;
        case 'openOverlayPermissionSettings':
        case 'showCollapsedOrb':
        case 'expandPanel':
        case 'collapsePanel':
        case 'hideOrb':
          return null;
        default:
          throw MissingPluginException('Unexpected method: ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<ByteData?> simulateNativeCall(String method, [dynamic arguments]) {
    final completer = Completer<ByteData?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channelName,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      completer.complete,
    );
    return completer.future;
  }

  group('AndroidOrbWindowController', () {
    test('forwards all outgoing window MethodChannel calls and arguments',
        () async {
      final controller = AndroidOrbWindowController();
      addTearDown(controller.dispose);

      mockOverlayPermission = true;
      expect(await controller.hasOverlayPermission(), isTrue);

      mockOverlayPermission = false;
      expect(await controller.hasOverlayPermission(), isFalse);

      returnNullPermission = true;
      expect(await controller.hasOverlayPermission(), isFalse);

      await controller.openOverlayPermissionSettings();
      await controller.showCollapsedOrb();
      await controller.expandPanel(const Size(340, 460));
      await controller.collapsePanel();
      await controller.hideOrb();
      await controller.moveOrbBy(const Offset(10, 20));
      await controller.showMainWindow();

      expect(
        recordedCalls.map((MethodCall c) => c.method).toList(),
        <String>[
          'hasOverlayPermission',
          'hasOverlayPermission',
          'hasOverlayPermission',
          'openOverlayPermissionSettings',
          'showCollapsedOrb',
          'expandPanel',
          'collapsePanel',
          'hideOrb',
        ],
      );
      expect(
        recordedCalls[5].arguments,
        <String, double>{'width': 340.0, 'height': 460.0},
      );
    });

    test('rejects non-positive or non-finite expandPanel sizes', () async {
      final controller = AndroidOrbWindowController();
      addTearDown(controller.dispose);

      expect(
        () => controller.expandPanel(const Size(0, 300)),
        throwsArgumentError,
      );
      expect(
        () => controller.expandPanel(const Size(300, -10)),
        throwsArgumentError,
      );
      expect(
        () => controller.expandPanel(const Size(double.infinity, 300)),
        throwsArgumentError,
      );
      expect(recordedCalls, isEmpty);
    });

    test('emits onLockOrSleep and onPanelDismissRequested on broadcast streams',
        () async {
      final controller = AndroidOrbWindowController();
      addTearDown(controller.dispose);

      var lockCountA = 0;
      var lockCountB = 0;
      var dismissCount = 0;

      final subA = controller.onLockOrSleep.listen((_) => lockCountA++);
      final subB = controller.onLockOrSleep.listen((_) => lockCountB++);
      final subDismiss =
          controller.onPanelDismissRequested.listen((_) => dismissCount++);
      addTearDown(() async {
        await subA.cancel();
        await subB.cancel();
        await subDismiss.cancel();
      });

      final lockResponse = await simulateNativeCall('onLockOrSleep');
      final dismissResponse =
          await simulateNativeCall('onPanelDismissRequested');

      expect(codec.decodeEnvelope(lockResponse!), isNull);
      expect(codec.decodeEnvelope(dismissResponse!), isNull);
      expect(lockCountA, 1);
      expect(lockCountB, 1);
      expect(dismissCount, 1);
    });

    test('dispose clears MethodChannel handler and closes event streams',
        () async {
      final controller = AndroidOrbWindowController();

      var lockDone = false;
      var dismissDone = false;
      final subLock =
          controller.onLockOrSleep.listen((_) {}, onDone: () => lockDone = true);
      final subDismiss = controller.onPanelDismissRequested
          .listen((_) {}, onDone: () => dismissDone = true);

      await controller.dispose();
      // Calling dispose twice is a safe no-op.
      await controller.dispose();

      expect(lockDone, isTrue);
      expect(dismissDone, isTrue);

      final responseAfterDispose = await simulateNativeCall('onLockOrSleep');
      expect(responseAfterDispose, isNull);

      await subLock.cancel();
      await subDismiss.cancel();
    });
  });
}
