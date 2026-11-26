import 'dart:async';

import 'package:discord_orb/contracts/orb_window_controller.dart';
import 'package:discord_orb/models/message_models.dart';
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
  late Object? mockToastOverlayResult;
  late DesktopOrbWindowController controller;

  setUp(() {
    recordedCalls = <MethodCall>[];
    mockOverlayPermission = true;
    mockExpandResult = null;
    mockToastOverlayResult = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      recordedCalls.add(call);
      switch (call.method) {
        case 'hasOverlayPermission':
          return mockOverlayPermission;
        case 'expandPanel':
          return mockExpandResult;
        case 'showToastOverlay':
          return mockToastOverlayResult;
        case 'updateToastStack':
        case 'hideToastStack':
        case 'openOverlayPermissionSettings':
        case 'showCollapsedOrb':
        case 'collapsePanel':
        case 'hideOrb':
        case 'setPanelPinned':
        case 'setToastNotificationsEnabled':
        case 'setToastLayout':
        case 'quitApp':
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
      await controller.showToastOverlay(const Size(300, 168));
      await controller.collapsePanel();
      await controller.hideOrb();
      await controller.setPanelPinned(false);
      await controller.setPanelPinned(true);
      await controller.startOrbDrag();
      await controller.startPanelResize(PanelResizeEdge.bottomLeft);
      await controller.moveOrbBy(const Offset(12.5, -8.0));
      await controller.showMainWindow();

      expect(recordedCalls.length, 14);
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

      expect(recordedCalls[5].method, 'showToastOverlay');
      expect(recordedCalls[5].arguments, <String, dynamic>{
        'width': 300.0,
        'height': 168.0,
      });

      expect(recordedCalls[6].method, 'collapsePanel');
      expect(recordedCalls[6].arguments, isNull);

      expect(recordedCalls[7].method, 'hideOrb');
      expect(recordedCalls[7].arguments, isNull);

      expect(recordedCalls[8].method, 'setPanelPinned');
      expect(recordedCalls[8].arguments, <String, dynamic>{
        'pinned': false,
      });

      expect(recordedCalls[9].method, 'setPanelPinned');
      expect(recordedCalls[9].arguments, <String, dynamic>{
        'pinned': true,
      });

      expect(recordedCalls[10].method, 'startOrbDrag');
      expect(recordedCalls[10].arguments, isNull);

      expect(recordedCalls[11].method, 'startPanelResize');
      expect(recordedCalls[11].arguments, <String, dynamic>{
        'edge': 'bottomLeft',
      });

      expect(recordedCalls[12].method, 'moveOrb');
      expect(recordedCalls[12].arguments, <String, dynamic>{
        'dx': 12.5,
        'dy': -8.0,
      });

      expect(recordedCalls[13].method, 'showMainWindow');
      expect(recordedCalls[13].arguments, isNull);
    });

    test('expandPanel and showToastOverlay decode native above/below direction cleanly',
        () async {
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

      mockToastOverlayResult = 'above';
      expect(
        await controller.showToastOverlay(const Size(300, 168)),
        OrbPanelExpandDirection.above,
      );

      mockToastOverlayResult = 'below';
      expect(
        await controller.showToastOverlay(const Size(300, 168)),
        OrbPanelExpandDirection.below,
      );

      mockToastOverlayResult = null;
      expect(
        await controller.showToastOverlay(const Size(300, 168)),
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

    test(
        'forwards updateToastStack/hideToastStack and emits onToastTapped/onToastDismissed',
        () async {
      final nativeToastController = DesktopOrbWindowController(
        usesNativeToastOverlay: true,
      );
      addTearDown(nativeToastController.dispose);
      expect(nativeToastController.usesNativeToastOverlay, isTrue);

      final message = ChannelMessagePreview(
        id: 'msg-42',
        authorName: 'Alice',
        authorAvatarUrl: 'https://cdn.example.com/a.png',
        timestamp: DateTime.utc(2026, 11, 26, 9, 30),
        content: 'Hello native toast!',
      );
      await nativeToastController.updateToastStack(
        messages: <ChannelMessagePreview>[message],
        maxVisibleCount: 4,
        channelName: 'general',
      );
      await nativeToastController.updateToastStack(
        messages: <ChannelMessagePreview>[message],
        maxVisibleCount: 4,
        channelName: 'general',
        compact: true,
      );
      await nativeToastController.hideToastStack();

      expect(recordedCalls.length, 3);
      expect(recordedCalls[0].method, 'updateToastStack');
      expect(recordedCalls[0].arguments, <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'msg-42',
            'authorName': 'Alice',
            'authorAvatarUrl': 'https://cdn.example.com/a.png',
            'content': 'Hello native toast!',
            'timestamp': '2026-11-26T09:30:00.000Z',
          },
        ],
        'maxVisibleCount': 4,
        'channelName': 'general',
        'compact': false,
      });
      expect(recordedCalls[1].method, 'updateToastStack');
      expect(
        (recordedCalls[1].arguments as Map<dynamic, dynamic>)['compact'],
        isTrue,
      );
      expect(recordedCalls[2].method, 'hideToastStack');
      expect(recordedCalls[2].arguments, isNull);

      var tapCount = 0;
      final dismissedIds = <String>[];
      final tapSub =
          nativeToastController.onToastTapped.listen((_) => tapCount++);
      final dismissSub = nativeToastController.onToastDismissed
          .listen(dismissedIds.add);
      addTearDown(tapSub.cancel);
      addTearDown(dismissSub.cancel);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(const MethodCall('onToastTapped')),
        (_) {},
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(
          const MethodCall(
            'onToastDismissed',
            <String, dynamic>{'messageId': 'msg-42'},
          ),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(tapCount, 1);
      expect(dismissedIds, <String>['msg-42']);

      // Verify setToastNotificationsEnabled, quitApp, and onToastEnabledToggled.
      recordedCalls.clear();
      await nativeToastController.setToastNotificationsEnabled(false);
      await nativeToastController.setToastNotificationsEnabled(true);
      await nativeToastController.quitApp();

      expect(recordedCalls.length, 3);
      expect(recordedCalls[0].method, 'setToastNotificationsEnabled');
      expect(recordedCalls[0].arguments, <String, dynamic>{'enabled': false});
      expect(recordedCalls[1].method, 'setToastNotificationsEnabled');
      expect(recordedCalls[1].arguments, <String, dynamic>{'enabled': true});
      expect(recordedCalls[2].method, 'quitApp');
      expect(recordedCalls[2].arguments, isNull);

      final toggledEvents = <bool>[];
      final toggledSub = nativeToastController.onToastEnabledToggled
          .listen(toggledEvents.add);
      addTearDown(toggledSub.cancel);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(
          const MethodCall(
            'onToastEnabledToggled',
            <String, dynamic>{'enabled': false},
          ),
        ),
        (_) {},
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(
          const MethodCall(
            'onToastEnabledToggled',
            <String, dynamic>{'enabled': true},
          ),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(toggledEvents, <bool>[false, true]);

      // Verify setToastLayout and onToastLayoutToggled.
      recordedCalls.clear();
      await nativeToastController.setToastLayout(ChatListLayout.compact);
      await nativeToastController.setToastLayout(ChatListLayout.standard);

      expect(recordedCalls.length, 2);
      expect(recordedCalls[0].method, 'setToastLayout');
      expect(recordedCalls[0].arguments, <String, dynamic>{'compact': true});
      expect(recordedCalls[1].method, 'setToastLayout');
      expect(recordedCalls[1].arguments, <String, dynamic>{'compact': false});

      final layoutEvents = <ChatListLayout>[];
      final layoutSub =
          nativeToastController.onToastLayoutToggled.listen(layoutEvents.add);
      addTearDown(layoutSub.cancel);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(
          const MethodCall(
            'onToastLayoutToggled',
            <String, dynamic>{'compact': true},
          ),
        ),
        (_) {},
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        DesktopOrbWindowController.channelName,
        codec.encodeMethodCall(
          const MethodCall(
            'onToastLayoutToggled',
            <String, dynamic>{'compact': false},
          ),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(layoutEvents, <ChatListLayout>[
        ChatListLayout.compact,
        ChatListLayout.standard,
      ]);
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
