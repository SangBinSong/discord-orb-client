import 'dart:async';

import 'package:discord_orb/contracts/orb_window_controller.dart';
import 'package:discord_orb/platform/desktop_orb_window_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(DesktopOrbWindowController.channelName);
  const codec = StandardMethodCodec();

  late List<MethodCall> recordedCalls;
  late bool mockOverlayPermission;
  late Object? mockExpandResult;
  late DesktopOrbWindowController controller;

  setUp(() {
    recordedCalls = <MethodCall>[];
    mockOverlayPermission = true;
    mockExpandResult = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      recordedCalls.add(call);
      switch (call.method) {
        case 'hasOverlayPermission':
          return mockOverlayPermission;
        case 'expandPanel':
          return mockExpandResult;
        case 'openOverlayPermissionSettings':
        case 'showCollapsedOrb':
        case 'collapsePanel':
        case 'hideOrb':
        case 'startOrbDrag':
        case 'startPanelResize':
        case 'moveOrb':
        case 'showMainWindow':
          return null;
        default:
          throw MissingPluginException('Unexpected method: ${call.method}');
      }
    });

    controller = DesktopOrbWindowController();
  });

  tearDown(() async {
    await controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('DesktopOrbWindowController', () {
    test('invokes all window control methods with expected arguments',
        () async {
      expect(controller.usesNativeWindowDrag, isTrue);
      expect(await controller.hasOverlayPermission(), isTrue);

      mockOverlayPermission = false;
      expect(await controller.hasOverlayPermission(), isFalse);

      await controller.openOverlayPermissionSettings();
      await controller.showCollapsedOrb();
      await controller.expandPanel(const Size(360, 440));
      await controller.collapsePanel();
      await controller.hideOrb();
      await controller.startOrbDrag();
      await controller.startPanelResize(PanelResizeEdge.bottomLeft);
      await controller.moveOrbBy(const Offset(12.5, -8.0));
      await controller.showMainWindow();

      expect(recordedCalls.length, 11);
      expect(recordedCalls[0].method, 'hasOverlayPermission');
      expect(recordedCalls[0].arguments, isNull);

      expect(recordedCalls[1].method, 'hasOverlayPermission');
      expect(recordedCalls[1].arguments, isNull);

      expect(recordedCalls[2].method, 'openOverlayPermissionSettings');
      expect(recordedCalls[2].arguments, isNull);

      expect(recordedCalls[3].method, 'showCollapsedOrb');
      expect(recordedCalls[3].arguments, isNull);

      expect(recordedCalls[4].method, 'expandPanel');
      expect(recordedCalls[4].arguments, <String, dynamic>{
        'width': 360.0,
        'height': 440.0,
      });

      expect(recordedCalls[5].method, 'collapsePanel');
      expect(recordedCalls[5].arguments, isNull);

      expect(recordedCalls[6].method, 'hideOrb');
      expect(recordedCalls[6].arguments, isNull);

      expect(recordedCalls[7].method, 'startOrbDrag');
      expect(recordedCalls[7].arguments, isNull);

      expect(recordedCalls[8].method, 'startPanelResize');
      expect(recordedCalls[8].arguments, <String, dynamic>{
        'edge': 'bottomLeft',
      });

      expect(recordedCalls[9].method, 'moveOrb');
      expect(recordedCalls[9].arguments, <String, dynamic>{
        'dx': 12.5,
        'dy': -8.0,
      });

      expect(recordedCalls[10].method, 'showMainWindow');
      expect(recordedCalls[10].arguments, isNull);
    });

    test('expandPanel decodes native above/below direction cleanly', () async {
      mockExpandResult = 'above';
      expect(
        await controller.expandPanel(const Size(352, 576)),
        OrbPanelExpandDirection.above,
      );

      mockExpandResult = 'below';
      expect(
        await controller.expandPanel(const Size(352, 576)),
        OrbPanelExpandDirection.below,
      );

      mockExpandResult = null;
      expect(
        await controller.expandPanel(const Size(352, 576)),
        OrbPanelExpandDirection.below,
      );
    });

    test('emits onLockOrSleep and onPanelDismissRequested from platform calls',
        () async {
      var lockEvents = 0;
      var dismissEvents = 0;

      final lockDone = Completer<void>();
      final dismissDone = Completer<void>();

      final lockSub = controller.onLockOrSleep.listen((_) {
        lockEvents++;
        if (!lockDone.isCompleted) {
          lockDone.complete();
        }
      });
      final dismissSub = controller.onPanelDismissRequested.listen((_) {
        dismissEvents++;
        if (!dismissDone.isCompleted) {
          dismissDone.complete();
        }
      });

      addTearDown(lockSub.cancel);
      addTearDown(dismissSub.cancel);

      ByteData? lockReply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(const MethodCall('onLockOrSleep')),
        (ByteData? data) {
          lockReply = data;
        },
      );

      ByteData? dismissReply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(const MethodCall('onPanelDismissRequested')),
        (ByteData? data) {
          dismissReply = data;
        },
      );

      await lockDone.future.timeout(const Duration(seconds: 1));
      await dismissDone.future.timeout(const Duration(seconds: 1));

      expect(lockEvents, 1);
      expect(dismissEvents, 1);
      expect(codec.decodeEnvelope(lockReply!), isNull);
      expect(codec.decodeEnvelope(dismissReply!), isNull);
    });

    test('rejects unknown platform methods and ignores events after dispose',
        () async {
      ByteData? unknownReply;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(const MethodCall('unknownMethod')),
        (ByteData? data) {
          unknownReply = data;
        },
      );

      expect(unknownReply, isNull);

      await controller.dispose();

      // Should not throw when platform messages arrive after dispose.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(const MethodCall('onLockOrSleep')),
        (_) {},
      );
    });
  });
}
