import 'dart:async';
import 'dart:ui' as ui;

import 'package:discord_orb/contracts/orb_window_controller.dart';
import 'package:discord_orb/contracts/preview_repository.dart';
import 'package:discord_orb/models/channel_models.dart';
import 'package:discord_orb/models/message_models.dart';
import 'package:discord_orb/models/orb_error.dart';
import 'package:discord_orb/ui/common/orb_avatar.dart';
import 'package:discord_orb/ui/orb/aurora_orb_painter.dart';
import 'package:discord_orb/ui/orb/orb_button.dart';
import 'package:discord_orb/ui/orb/orb_message_toast.dart';
import 'package:discord_orb/ui/orb/orb_shell.dart';
import 'package:discord_orb/ui/orb/panel_positioner.dart';
import 'package:discord_orb/ui/panel/message_panel.dart';
import 'package:discord_orb/ui/panel/message_tile.dart';
import 'package:discord_orb/ui/panel/panel_status_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingWindowController extends NoopOrbWindowController {
  _RecordingWindowController({
    this.usesNativeWindowDrag = false,
    this.usesNativeToastOverlay = false,
    this.expandDirection = OrbPanelExpandDirection.below,
    this.toastDirection = OrbPanelExpandDirection.below,
  });

  @override
  final bool usesNativeWindowDrag;

  @override
  final bool usesNativeToastOverlay;

  OrbPanelExpandDirection expandDirection;
  OrbPanelExpandDirection toastDirection;

  int expandCount = 0;
  Size? lastExpandSize;
  int toastOverlayCount = 0;
  Size? lastToastSize;
  final List<
      ({
        List<ChannelMessagePreview> messages,
        int maxVisibleCount,
        String? channelName,
        bool compact,
      })> toastStackUpdates = <({
    List<ChannelMessagePreview> messages,
    int maxVisibleCount,
    String? channelName,
    bool compact,
  })>[];
  int hideToastStackCount = 0;
  int collapseCount = 0;
  int hideOrbCount = 0;
  int showCollapsedOrbCount = 0;
  int startOrbDragCount = 0;
  final List<bool> pinnedCalls = <bool>[];
  final List<PanelResizeEdge> startedResizeEdges = <PanelResizeEdge>[];
  final List<Offset> moveOrbDeltas = <Offset>[];
  int showMainWindowCount = 0;

  @override
  Future<OrbPanelExpandDirection> expandPanel(Size size) async {
    expandCount += 1;
    lastExpandSize = size;
    return expandDirection;
  }

  @override
  Future<OrbPanelExpandDirection> showToastOverlay(Size size) async {
    toastOverlayCount += 1;
    lastToastSize = size;
    return toastDirection;
  }

  @override
  Future<void> updateToastStack({
    required List<ChannelMessagePreview> messages,
    required int maxVisibleCount,
    String? channelName,
    bool compact = false,
  }) async {
    toastStackUpdates.add((
      messages: List<ChannelMessagePreview>.unmodifiable(messages),
      maxVisibleCount: maxVisibleCount,
      channelName: channelName,
      compact: compact,
    ));
  }

  @override
  Future<void> hideToastStack() async {
    hideToastStackCount += 1;
  }

  @override
  Future<void> setPanelPinned(bool pinned) async {
    pinnedCalls.add(pinned);
    await super.setPanelPinned(pinned);
  }

  @override
  Future<void> collapsePanel() async {
    collapseCount += 1;
  }

  @override
  Future<void> hideOrb() async {
    hideOrbCount += 1;
  }

  @override
  Future<void> showCollapsedOrb() async {
    showCollapsedOrbCount += 1;
  }

  @override
  Future<void> startOrbDrag() async {
    startOrbDragCount += 1;
  }

  @override
  Future<void> startPanelResize(PanelResizeEdge edge) async {
    startedResizeEdges.add(edge);
  }

  @override
  Future<void> moveOrbBy(Offset delta) async {
    moveOrbDeltas.add(delta);
  }

  @override
  Future<void> showMainWindow() async {
    showMainWindowCount += 1;
  }
}

class _FakePreviewRepository implements PreviewRepository {
  final List<Object> capturedTokens = <Object>[];
  final List<({String guildId, String channelId})> subscribedChannels =
      <({String guildId, String channelId})>[];
  final List<StreamController<ChannelMessageEvent>> _activeStreamControllers =
      <StreamController<ChannelMessageEvent>>[];

  int fetchCalls = 0;
  int subscribeCalls = 0;
  int streamCancelCalls = 0;
  int cancelCalls = 0;
  int clearMemoryCalls = 0;

  int get activeStreamCount => _activeStreamControllers.length;

  Future<List<ChannelMessagePreview>> Function(Object requestToken)? onFetch;
  Stream<ChannelMessageEvent> Function({
    required String guildId,
    required String channelId,
    required Object requestToken,
  })? onSubscribe;

  @override
  Future<List<EligibleGuild>> fetchEligibleGuilds() async =>
      const <EligibleGuild>[];

  @override
  Future<List<ChannelMessagePreview>> fetchLatestMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) {
    fetchCalls += 1;
    capturedTokens.add(requestToken);
    final handler = onFetch;
    if (handler != null) {
      return handler(requestToken);
    }
    return Future<List<ChannelMessagePreview>>.value(
      const <ChannelMessagePreview>[],
    );
  }

  @override
  Stream<ChannelMessageEvent> subscribeToChannelMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) {
    subscribeCalls += 1;
    subscribedChannels.add((guildId: guildId, channelId: channelId));
    final handler = onSubscribe;
    if (handler != null) {
      return handler(
        guildId: guildId,
        channelId: channelId,
        requestToken: requestToken,
      );
    }
    late final StreamController<ChannelMessageEvent> controller;
    controller = StreamController<ChannelMessageEvent>(
      onCancel: () {
        streamCancelCalls += 1;
        _activeStreamControllers.remove(controller);
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      },
    );
    _activeStreamControllers.add(controller);
    return controller.stream;
  }

  void emitEvent(ChannelMessageEvent event) {
    for (final controller
        in List<StreamController<ChannelMessageEvent>>.of(_activeStreamControllers)) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }
  }

  @override
  void cancelActivePreview() {
    cancelCalls += 1;
  }

  @override
  void clearMemory() {
    clearMemoryCalls += 1;
  }
}

ChannelMessagePreview _msg(int index, {DateTime? timestamp}) {
  return ChannelMessagePreview(
    id: 'msg_$index',
    authorName: 'User $index',
    timestamp: timestamp ?? DateTime.utc(2026, 11, 19, 12, index),
    content: 'Message body $index',
  );
}

Widget _wrapShell({
  Key? shellKey,
  required PreviewRepository previewRepository,
  required OrbWindowController windowController,
  OrbShellController? controller,
  Size viewportSize = const Size(420, 800),
  Offset? initialOrbOffset,
  String? guildId = 'guild-1',
  String? channelId = 'channel-1',
  Duration streamReconnectBaseDelay = const Duration(seconds: 1),
  Duration streamReconnectMaxDelay = const Duration(seconds: 30),
  String? guildIconUrl,
  ChatListLayout chatListLayout = ChatListLayout.standard,
  ValueChanged<ChatListLayout>? onChatListLayoutChanged,
  bool? panelPinned,
  ValueChanged<bool>? onPanelPinnedChanged,
  bool toastNotificationsEnabled = false,
  ValueChanged<bool>? onToastNotificationsChanged,
  int maxVisibleToastCount = 3,
  ValueChanged<int>? onMaxVisibleToastCountChanged,
  ChatListLayout toastLayout = ChatListLayout.standard,
  ValueChanged<ChatListLayout>? onToastLayoutChanged,
  Duration toastDuration = const Duration(seconds: 5),
  ValueChanged<OrbPanelExpandDirection>? onExpandDirectionChanged,
  VoidCallback? onReauthenticate,
  VoidCallback? onReselectChannel,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: viewportSize.width,
          height: viewportSize.height,
          child: OrbShell(
            key: shellKey,
            previewRepository: previewRepository,
            windowController: windowController,
            controller: controller,
            guildId: guildId,
            channelId: channelId,
            channelName: 'general',
            guildName: 'Orb Guild',
            guildIconUrl: guildIconUrl,
            chatListLayout: chatListLayout,
            onChatListLayoutChanged: onChatListLayoutChanged,
            panelPinned: panelPinned,
            onPanelPinnedChanged: onPanelPinnedChanged,
            toastNotificationsEnabled: toastNotificationsEnabled,
            onToastNotificationsChanged: onToastNotificationsChanged,
            maxVisibleToastCount: maxVisibleToastCount,
            onMaxVisibleToastCountChanged: onMaxVisibleToastCountChanged,
            toastLayout: toastLayout,
            onToastLayoutChanged: onToastLayoutChanged,
            toastDuration: toastDuration,
            onExpandDirectionChanged: onExpandDirectionChanged,
            initialOrbOffset: initialOrbOffset,
            streamReconnectBaseDelay: streamReconnectBaseDelay,
            streamReconnectMaxDelay: streamReconnectMaxDelay,
            onReauthenticate: onReauthenticate,
            onReselectChannel: onReselectChannel,
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpSettled(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('panel_positioner', () {
    test('places panel below orb by default when space permits', () {
      final placement = computePanelRect(
        orbRect: const Rect.fromLTWH(200, 40, 56, 56),
        panelSize: const Size(300, 360),
        viewportSize: const Size(500, 800),
        safePadding: const EdgeInsets.only(top: 16, left: 10, right: 10),
      );

      expect(placement.direction, PanelPlacementDirection.below);
      expect(placement.rect.top, greaterThanOrEqualTo(96));
      expect(placement.rect.bottom, lessThanOrEqualTo(800));
      expect(placement.rect.left, greaterThanOrEqualTo(10));
      expect(placement.rect.right, lessThanOrEqualTo(490));
    });

    test('flips above orb when bottom space is insufficient', () {
      final placement = computePanelRect(
        orbRect: const Rect.fromLTWH(200, 680, 56, 56),
        panelSize: const Size(300, 360),
        viewportSize: const Size(500, 800),
        safePadding: const EdgeInsets.all(16),
      );

      expect(placement.direction, PanelPlacementDirection.above);
      expect(placement.rect.bottom, lessThanOrEqualTo(680));
      expect(placement.rect.top, greaterThanOrEqualTo(16));
    });

    test('clamps panel horizontally and vertically inside safe bounds', () {
      final leftEdge = computePanelRect(
        orbRect: const Rect.fromLTWH(4, 24, 56, 56),
        panelSize: const Size(320, 400),
        viewportSize: const Size(400, 700),
        safePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      );
      expect(leftEdge.rect.left, 12);

      final rightEdge = computePanelRect(
        orbRect: const Rect.fromLTWH(340, 24, 56, 56),
        panelSize: const Size(320, 400),
        viewportSize: const Size(400, 700),
        safePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      );
      expect(rightEdge.rect.right, 388);
    });

    test('clampOrbOffset keeps orb inside viewport safe bounds', () {
      final clamped = clampOrbOffset(
        offset: const Offset(-40, 999),
        orbSize: const Size(56, 56),
        viewportSize: const Size(400, 700),
        safePadding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
      );
      expect(clamped, const Offset(8, 700 - 16 - 56));
    });
  });

  group('OrbShell two-tap toggle & late response handling', () {
    testWidgets('first tap opens loading panel and second tap closes and clears',
        (WidgetTester tester) async {
      final repo = _FakePreviewRepository();
      final window = _RecordingWindowController();
      final controller = OrbShellController();
      final completer = Completer<List<ChannelMessagePreview>>();
      repo.onFetch = (_) => completer.future;

      await tester.pumpWidget(
        _wrapShell(
          previewRepository: repo,
          windowController: window,
          controller: controller,
        ),
      );

      expect(controller.isPanelOpen, isFalse);

      // 1st tap: opens immediately in loading state & expands panel.
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();

      expect(controller.isPanelOpen, isTrue);
      expect(controller.previewState, OrbPreviewState.loading);
      expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsOneWidget);
      expect(window.expandCount, 1);
      expect(repo.fetchCalls, 1);
      expect(repo.capturedTokens, hasLength(1));

      // 2nd tap before response arrives: closes panel immediately without
      // tearing down persistent SSE, and ignores the late fetch response.
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();

      expect(controller.isPanelOpen, isFalse);
      expect(controller.previewState, OrbPreviewState.idle);
      expect(controller.messages, isEmpty);
      expect(controller.hasLoadedMessages, isFalse);
      expect(repo.clearMemoryCalls, 0);
      expect(repo.cancelCalls, 0);
      expect(repo.subscribeCalls, 1);
      expect(repo.streamCancelCalls, 0);
      expect(window.collapseCount, 1);

      // Late response arrives after close: must be completely ignored.
      completer.complete(<ChannelMessagePreview>[_msg(1)]);
      await tester.pump();

      expect(controller.isPanelOpen, isFalse);
      expect(controller.previewState, OrbPreviewState.idle);
      expect(controller.messages, isEmpty);
      expect(controller.hasLoadedMessages, isFalse);
      expect(controller.cachedMessages, isEmpty);
      expect(find.text('Message body 1'), findsNothing);
    });

    testWidgets('renders at most 10 newest-first read-only messages',
        (WidgetTester tester) async {
      final repo = _FakePreviewRepository();
      final window = _RecordingWindowController();
      final controller = OrbShellController();
      final messages = List<ChannelMessagePreview>.generate(
        12,
        (int i) => _msg(
          i,
          timestamp: DateTime.utc(2026, 11, 19, 10, i),
        ),
      );
      repo.onFetch = (_) async => messages;

      await tester.pumpWidget(
        _wrapShell(
          previewRepository: repo,
          windowController: window,
          controller: controller,
        ),
      );

      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);

      expect(controller.previewState, OrbPreviewState.loaded);
      expect(controller.messages, hasLength(10));
      expect(controller.messages.first.id, 'msg_11');
      expect(controller.messages.last.id, 'msg_2');

      expect(find.text('User 11'), findsOneWidget);
      expect(find.text('Message body 11'), findsOneWidget);
      expect(find.text('Message body 0'), findsNothing);
      expect(find.text('Message body 1'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('drag moves orb and clamps inside viewport, hide/restore works',
        (WidgetTester tester) async {
      final repo = _FakePreviewRepository();
      final window = _RecordingWindowController();
      final controller = OrbShellController();

      await tester.pumpWidget(
        _wrapShell(
          previewRepository: repo,
          windowController: window,
          controller: controller,
          viewportSize: const Size(400, 700),
          initialOrbOffset: const Offset(100, 40),
        ),
      );

      // Drag far outside top-left; should clamp to (0, 0).
      await tester.drag(
        find.byKey(OrbButton.orbButtonKey),
        const Offset(-500, -500),
      );
      await tester.pump();
      final topLeft = tester.getTopLeft(find.byKey(OrbButton.orbButtonKey));
      final shellTopLeft = tester.getTopLeft(find.byType(OrbShell));
      expect(topLeft - shellTopLeft, Offset.zero);

      // Long press hides orb, then restore chip brings it back.
      await tester.longPress(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();
      expect(controller.isOrbHidden, isTrue);
      expect(window.hideOrbCount, 1);
      expect(find.byKey(OrbButton.orbButtonKey), findsNothing);
      expect(find.byKey(OrbShell.restoreChipKey), findsOneWidget);

      await tester.tap(find.byKey(OrbShell.restoreChipKey));
      await tester.pump();
      expect(controller.isOrbHidden, isFalse);
      expect(window.showCollapsedOrbCount, 1);
      expect(find.byKey(OrbButton.orbButtonKey), findsOneWidget);
    });

    testWidgets(
      'collapsed 80x80 desktop viewport centers orb, delegates drag once to startOrbDrag without moveOrbBy spam, and requests full expanded size on tap without overflow',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(80, 80),
          ),
        );

        // Orb (56x56) is centered inside 80x80 collapsed overlay window -> (12, 12).
        final orbTopLeft = tester.getTopLeft(find.byKey(OrbButton.orbButtonKey));
        final shellTopLeft = tester.getTopLeft(find.byType(OrbShell));
        expect(orbTopLeft - shellTopLeft, const Offset(12, 12));

        // Dragging in collapsed 80x80 viewport initiates native OS drag once via
        // startOrbDrag() instead of spamming moveOrbBy() every pan update.
        await tester.drag(
          find.byKey(OrbButton.orbButtonKey),
          const Offset(24, -16),
        );
        await tester.pump();
        expect(window.startOrbDragCount, 1);
        expect(window.moveOrbDeltas, isEmpty);
        // Orb remains centered in the collapsed window.
        expect(
          tester.getTopLeft(find.byKey(OrbButton.orbButtonKey)) -
              tester.getTopLeft(find.byType(OrbShell)),
          const Offset(12, 12),
        );

        // Tapping orb in 80x80 viewport requests full expanded size, not clamped 80x80,
        // and does not throw RenderFlex overflow during the 1-frame resize transition.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();

        expect(controller.isPanelOpen, isTrue);
        expect(window.expandCount, 1);
        expect(window.lastExpandSize, isNotNull);
        expect(window.lastExpandSize!.width, greaterThanOrEqualTo(320 + 32));
        expect(
          window.lastExpandSize!.height,
          greaterThanOrEqualTo(400 + 56 + 96),
        );
        // MessagePanel is deferred while viewport is still 80x80.
        expect(find.byType(MessagePanel), findsNothing);
        expect(tester.takeException(), isNull);

        // Once native window expands to requested size, panel renders without overlapping orb.
        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: window.lastExpandSize!,
          ),
        );
        await _pumpSettled(tester);

        expect(find.byType(MessagePanel), findsOneWidget);
        expect(find.text('Message body 1'), findsOneWidget);
        final expandedOrbRect =
            tester.getRect(find.byKey(OrbButton.orbButtonKey));
        final panelRect = tester.getRect(find.byType(MessagePanel));
        expect(expandedOrbRect.overlaps(panelRect), isFalse);
      },
    );

    testWidgets(
      'native window drag mode anchors expanded orb at top-right, triggers startOrbDrag instead of shifting local offset, and omits clipped Tooltip while keeping Semantics',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(usesNativeWindowDrag: true);
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(352, 576),
            initialOrbOffset: const Offset(40, 120),
          ),
        );

        // Even with initialOrbOffset provided, native window drag anchors orb at top-right.
        const expectedAnchor = Offset(352 - 56 - 16, 16);
        final shellTopLeft = tester.getTopLeft(find.byType(OrbShell));
        expect(
          tester.getTopLeft(find.byKey(OrbButton.orbButtonKey)) - shellTopLeft,
          expectedAnchor,
        );
        expect(find.byType(Tooltip), findsNothing);
        expect(
          find.bySemanticsLabel('Open Discord Orb panel'),
          findsOneWidget,
        );

        // Open panel -> orb becomes close button at top-right, Semantics updates, Tooltip stays omitted.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(controller.isPanelOpen, isTrue);
        expect(find.byType(MessagePanel), findsOneWidget);
        expect(
          find.bySemanticsLabel('Close Discord Orb panel'),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(OrbButton),
            matching: find.byType(Tooltip),
          ),
          findsNothing,
        );

        // Dragging expanded (X) orb triggers native startOrbDrag() and does not move local offset.
        await tester.drag(
          find.byKey(OrbButton.orbButtonKey),
          const Offset(-80, 60),
        );
        await tester.pump();
        expect(window.startOrbDragCount, 1);
        expect(window.moveOrbDeltas, isEmpty);
        expect(
          tester.getTopLeft(find.byKey(OrbButton.orbButtonKey)) - shellTopLeft,
          expectedAnchor,
        );
      },
    );

    testWidgets(
      'OrbButton showTooltip controls Tooltip rendering while preserving Semantics, and non-native OrbShell enables Tooltip',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  OrbButton(
                    isPanelOpen: false,
                    showTooltip: false,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.byType(Tooltip), findsNothing);
        expect(find.bySemanticsLabel('Open Discord Orb panel'), findsOneWidget);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  OrbButton(
                    isPanelOpen: true,
                    showTooltip: true,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.byType(Tooltip), findsOneWidget);
        expect(
          find.bySemanticsLabel('Close Discord Orb panel'),
          findsOneWidget,
        );

        // Non-native OrbShell (usesNativeWindowDrag == false) passes showTooltip: true.
        final repo = _FakePreviewRepository();
        final nonNativeWindow =
            _RecordingWindowController(usesNativeWindowDrag: false);
        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: nonNativeWindow,
          ),
        );
        expect(
          find.descendant(
            of: find.byType(OrbButton),
            matching: find.byType(Tooltip),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'native expanded window adapts responsively to resized viewports (min 260x240 and large 600x700) without overflow',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(usesNativeWindowDrag: true);
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1), _msg(2)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(352, 576),
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);

        final initialRect = tester.getRect(find.byType(MessagePanel));
        expect(initialRect.width, closeTo(320, 1));

        // Resize larger -> MessagePanel expands to fill resized viewport.
        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(600, 700),
          ),
        );
        await _pumpSettled(tester);

        final largerRect = tester.getRect(find.byType(MessagePanel));
        expect(largerRect.width, closeTo(568, 1));
        expect(largerRect.height, greaterThan(initialRect.height));
        expect(tester.takeException(), isNull);

        // Resize down to minimum 260x240 -> still renders cleanly without overflow.
        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(260, 240),
          ),
        );
        await _pumpSettled(tester);

        final minRect = tester.getRect(find.byType(MessagePanel));
        expect(minRect.width, closeTo(228, 1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'upward (above) expansion anchors native orb at bottom-right and renders MessagePanel strictly above orb',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(
          usesNativeWindowDrag: true,
          expandDirection: OrbPanelExpandDirection.above,
        );
        final controller = OrbShellController();
        OrbPanelExpandDirection? reportedDirection;
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(352, 576),
            onExpandDirectionChanged: (dir) => reportedDirection = dir,
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);

        expect(controller.expandDirection, OrbPanelExpandDirection.above);
        expect(reportedDirection, OrbPanelExpandDirection.above);

        final shellTopLeft = tester.getTopLeft(find.byType(OrbShell));
        final orbRect = tester.getRect(find.byKey(OrbButton.orbButtonKey));
        final panelRect = tester.getRect(find.byType(MessagePanel));

        // Orb is anchored at bottom-right (352 - 56 - 16 = 280, 576 - 56 - 16 = 504).
        expect(orbRect.topLeft - shellTopLeft, const Offset(280, 504));
        expect(panelRect.bottom, lessThanOrEqualTo(orbRect.top));
        expect(orbRect.overlaps(panelRect), isFalse);
      },
    );

    testWidgets(
      'non-native OrbShell resize handle dynamically resizes MessagePanel within bounds',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(usesNativeWindowDrag: false);
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            viewportSize: const Size(640, 720),
            initialOrbOffset: const Offset(40, 20),
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);

        final before = tester.getRect(find.byType(MessagePanel));
        expect(find.byKey(OrbShell.panelResizeHandleKey), findsOneWidget);

        await tester.drag(
          find.byKey(OrbShell.panelResizeHandleKey),
          const Offset(80, 60),
        );
        await tester.pump();

        final after = tester.getRect(find.byType(MessagePanel));
        expect(after.width, greaterThan(before.width));
        expect(after.height, greaterThan(before.height));
      },
    );

    testWidgets(
      'MessagePanel header toggles standard vs compact layout and renders avatars & guild icon fallback',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        ChatListLayout? lastChanged;
        repo.onFetch = (_) async => <ChannelMessagePreview>[
              ChannelMessagePreview(
                id: 'm-1',
                authorName: 'Alice Wonderland',
                timestamp: DateTime.utc(2026, 11, 19, 12, 0),
                content: 'Line one\nLine two',
              ),
            ];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            onChatListLayoutChanged: (layout) => lastChanged = layout,
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);

        // Standard layout shows multi-line content and avatars (guild + author).
        expect(find.text('Line one\nLine two'), findsOneWidget);
        expect(find.byType(OrbAvatar), findsNWidgets(2));
        expect(find.text('OG'), findsOneWidget); // Orb Guild initials
        expect(find.text('AW'), findsOneWidget); // Alice Wonderland initials

        // Tap header layout toggle -> switches to compact single-line layout.
        await tester.tap(find.byKey(MessagePanel.layoutToggleButtonKey));
        await _pumpSettled(tester);

        expect(lastChanged, ChatListLayout.compact);
        expect(find.text('Line one Line two'), findsOneWidget);
        expect(find.text('Line one\nLine two'), findsNothing);
        final authorAvatar = tester.widgetList<OrbAvatar>(
          find.descendant(
            of: find.byType(MessageTile),
            matching: find.byType(OrbAvatar),
          ),
        );
        expect(authorAvatar.single.size, 18);
      },
    );

    testWidgets(
      'native desktop expanded panel renders visible corner resize grips, hover cursors, and invokes startPanelResize on visible card edges for both below and above modes',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(
          usesNativeWindowDrag: true,
          expandDirection: OrbPanelExpandDirection.below,
        );
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(352, 576),
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);

        // Below mode: bottom-left and bottom-right grips are visible; top-left is hidden.
        expect(
          find.byKey(OrbShell.panelResizeGripKey(PanelResizeEdge.bottomRight)),
          findsOneWidget,
        );
        expect(
          find.byKey(OrbShell.panelResizeGripKey(PanelResizeEdge.bottomLeft)),
          findsOneWidget,
        );
        expect(
          find.byKey(OrbShell.panelResizeGripKey(PanelResizeEdge.topLeft)),
          findsNothing,
        );

        // Verify hover MouseRegion cursor on visible bottom-left and left edges.
        final bottomLeftMouseRegion = tester.widget<MouseRegion>(
          find.ancestor(
            of: find.byKey(OrbShell.panelResizeEdgeKey(PanelResizeEdge.bottomLeft)),
            matching: find.byType(MouseRegion),
          ).first,
        );
        expect(
          bottomLeftMouseRegion.cursor,
          SystemMouseCursors.resizeUpRightDownLeft,
        );

        // Pointer down on visible card edges triggers startPanelResize with matching edge.
        await tester.tap(
          find.byKey(OrbShell.panelResizeEdgeKey(PanelResizeEdge.bottomLeft)),
        );
        await tester.tap(
          find.byKey(OrbShell.panelResizeEdgeKey(PanelResizeEdge.left)),
        );
        await tester.tap(
          find.byKey(OrbShell.panelResizeEdgeKey(PanelResizeEdge.bottomRight)),
        );
        await tester.pump();
        expect(
          window.startedResizeEdges,
          <PanelResizeEdge>[
            PanelResizeEdge.bottomLeft,
            PanelResizeEdge.left,
            PanelResizeEdge.bottomRight,
          ],
        );

        // Close and re-open in above mode -> top-left visible grip appears.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        window.expandDirection = OrbPanelExpandDirection.above;
        window.startedResizeEdges.clear();

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);

        expect(
          find.byKey(OrbShell.panelResizeGripKey(PanelResizeEdge.topLeft)),
          findsOneWidget,
        );
        expect(
          find.byKey(OrbShell.panelResizeGripKey(PanelResizeEdge.bottomRight)),
          findsNothing,
        );

        final topLeftMouseRegion = tester.widget<MouseRegion>(
          find.ancestor(
            of: find.byKey(OrbShell.panelResizeEdgeKey(PanelResizeEdge.topLeft)),
            matching: find.byType(MouseRegion),
          ).first,
        );
        expect(
          topLeftMouseRegion.cursor,
          SystemMouseCursors.resizeUpLeftDownRight,
        );

        await tester.tap(
          find.byKey(OrbShell.panelResizeEdgeKey(PanelResizeEdge.topLeft)),
        );
        await tester.tap(
          find.byKey(OrbShell.panelResizeEdgeKey(PanelResizeEdge.top)),
        );
        await tester.pump();
        expect(
          window.startedResizeEdges,
          <PanelResizeEdge>[
            PanelResizeEdge.topLeft,
            PanelResizeEdge.top,
          ],
        );
      },
    );
  });

  group('Lock/sleep & external dismiss memory clearing', () {
    for (final lifecycleState in <AppLifecycleState>[
      AppLifecycleState.paused,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      testWidgets('clears memory and closes panel on $lifecycleState',
          (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(controller.isPanelOpen, isTrue);
        expect(controller.messages, hasLength(1));

        tester.binding.handleAppLifecycleStateChanged(lifecycleState);
        await tester.pump();

        expect(controller.isPanelOpen, isFalse);
        expect(controller.messages, isEmpty);
        expect(repo.clearMemoryCalls, 1);
        expect(repo.cancelCalls, 1);
        expect(window.collapseCount, 1);
      });
    }

    testWidgets('clears memory on onLockOrSleep and onPanelDismissRequested',
        (WidgetTester tester) async {
      final repo = _FakePreviewRepository();
      final window = _RecordingWindowController();
      final controller = OrbShellController();
      repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

      await tester.pumpWidget(
        _wrapShell(
          previewRepository: repo,
          windowController: window,
          controller: controller,
        ),
      );

      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);
      expect(controller.isPanelOpen, isTrue);

      window.emitLockOrSleep();
      await tester.pump();
      expect(controller.isPanelOpen, isFalse);
      expect(controller.messages, isEmpty);
      expect(controller.hasLoadedMessages, isFalse);
      expect(controller.cachedMessages, isEmpty);
      expect(repo.clearMemoryCalls, 1);
      expect(window.collapseCount, 1);

      // Re-open after lock performs fresh fetch, then external dismiss closes
      // panel while preserving RAM cache & persistent SSE.
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);
      expect(controller.isPanelOpen, isTrue);
      expect(controller.hasLoadedMessages, isTrue);

      window.emitPanelDismissRequested();
      await tester.pump();
      expect(controller.isPanelOpen, isFalse);
      expect(controller.messages, isEmpty);
      expect(controller.hasLoadedMessages, isTrue);
      expect(controller.cachedMessages, hasLength(1));
      expect(repo.clearMemoryCalls, 1);
      expect(repo.activeStreamCount, 1);
      expect(window.collapseCount, 2);
    });
  });

  group('Status views & no stale message residue', () {
    testWidgets('renders distinct states with callbacks and no stale residue',
        (WidgetTester tester) async {
      final repo = _FakePreviewRepository();
      final window = _RecordingWindowController();
      final controller = OrbShellController();
      var reauthTapped = 0;
      var reselectTapped = 0;

      await tester.pumpWidget(
        _wrapShell(
          previewRepository: repo,
          windowController: window,
          controller: controller,
          onReauthenticate: () => reauthTapped += 1,
          onReselectChannel: () => reselectTapped += 1,
        ),
      );

      // 1. emptyChannel
      repo.onFetch = (_) async => const <ChannelMessagePreview>[];
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);
      expect(controller.previewState, OrbPreviewState.emptyChannel);
      expect(find.text('Channel is empty'), findsOneWidget);

      // Hard clear before next state test so step 2 performs a fresh fetch.
      controller.closeAndClear();
      await tester.pump();

      // 2. sessionExpired
      repo.onFetch = (_) async => throw const OrbException(
            code: 'session_expired',
            message: 'Session expired',
            state: OrbPreviewState.sessionExpired,
          );
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);
      expect(find.text('Session expired'), findsOneWidget);
      await tester.tap(find.byKey(PanelStatusView.reauthenticateButtonKey));
      expect(reauthTapped, 1);

      // Close
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();

      // 3. accessDenied
      repo.onFetch = (_) async => throw const OrbException(
            code: 'access_denied',
            message: 'Forbidden',
            state: OrbPreviewState.accessDenied,
          );
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);
      expect(find.text('Channel access denied'), findsOneWidget);
      await tester.tap(find.byKey(PanelStatusView.reselectChannelButtonKey));
      expect(reselectTapped, 1);

      // Close
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();

      // 4. botUnavailable
      repo.onFetch = (_) async => throw const OrbException(
            code: 'bot_unavailable',
            message: 'Bot disabled',
            state: OrbPreviewState.botUnavailable,
          );
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);
      expect(find.text('Bot unavailable'), findsOneWidget);

      // Close
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();

      // 5. rateLimited + retry -> loading (no stale messages) -> loaded
      final retryCompleter = Completer<List<ChannelMessagePreview>>();
      var attempt = 0;
      repo.onFetch = (_) {
        attempt += 1;
        if (attempt == 1) {
          return Future<List<ChannelMessagePreview>>.error(
            const OrbException(
              code: 'rate_limited',
              message: 'Slow down',
              state: OrbPreviewState.rateLimited,
              retryAfter: Duration(seconds: 5),
            ),
          );
        }
        return retryCompleter.future;
      };

      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await _pumpSettled(tester);
      expect(find.text('Rate limited'), findsOneWidget);
      expect(find.textContaining('5s'), findsOneWidget);

      await tester.tap(find.byKey(PanelStatusView.retryButtonKey));
      await tester.pump();
      expect(controller.previewState, OrbPreviewState.loading);
      expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsOneWidget);
      expect(find.byType(MessageTile), findsNothing);

      retryCompleter.complete(<ChannelMessagePreview>[_msg(7)]);
      await _pumpSettled(tester);
      expect(controller.previewState, OrbPreviewState.loaded);
      expect(find.text('Message body 7'), findsOneWidget);
    });

    testWidgets('MessagePanel never renders stale messages outside loaded state',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 400,
              child: MessagePanel(
                state: OrbPreviewState.loading,
                messages: <ChannelMessagePreview>[_msg(99)],
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsOneWidget);
      expect(find.byType(MessageTile), findsNothing);
      expect(find.text('Message body 99'), findsNothing);
    });
  });

  group('OrbShell real-time SSE streaming', () {
    testWidgets(
      'keeps collapsed SSE active for unread badge, merges create/update/delete live while open, wipes panel messages on close, and cancels on lock/sleep',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[
              _msg(1, timestamp: DateTime.utc(2026, 11, 25, 12, 1)),
              _msg(2, timestamp: DateTime.utc(2026, 11, 25, 12, 2)),
            ];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
          ),
        );

        // Panel is closed -> background SSE stays connected for unread badge tracking.
        expect(repo.subscribeCalls, 1);
        expect(repo.activeStreamCount, 1);

        // Open panel -> loads initial REST messages and reuses active SSE stream.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);

        expect(repo.subscribeCalls, 1);
        expect(repo.activeStreamCount, 1);
        expect(controller.messages.map((m) => m.id), <String>['msg_2', 'msg_1']);

        // 1. Live message_create (and duplicate ID dedup)
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(3, timestamp: DateTime.utc(2026, 11, 25, 12, 5)),
          ),
        );
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: ChannelMessagePreview(
              id: 'msg_3',
              authorName: 'User 3',
              timestamp: DateTime.utc(2026, 11, 25, 12, 5),
              content: 'Message body 3 deduped',
            ),
          ),
        );
        await _pumpSettled(tester);

        expect(controller.messages.map((m) => m.id), <String>[
          'msg_3',
          'msg_2',
          'msg_1',
        ]);
        expect(find.text('Message body 3 deduped'), findsOneWidget);

        // 2. Partial message_update preserves original author and timestamp
        repo.emitEvent(
          const ChannelMessageEvent.update(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_2',
            content: 'Edited body 2',
          ),
        );
        await _pumpSettled(tester);
        expect(find.text('Edited body 2'), findsOneWidget);
        expect(find.text('User 2'), findsOneWidget);

        // 3. message_delete removes message; deleting all transitions to emptyChannel
        repo.emitEvent(
          const ChannelMessageEvent.delete(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_3',
          ),
        );
        repo.emitEvent(
          const ChannelMessageEvent.delete(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_2',
          ),
        );
        repo.emitEvent(
          const ChannelMessageEvent.delete(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_1',
          ),
        );
        await _pumpSettled(tester);
        expect(controller.previewState, OrbPreviewState.emptyChannel);
        expect(controller.messages, isEmpty);

        // Close panel -> keeps single persistent SSE and RAM cache alive (no teardown/re-subscribe).
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();

        expect(controller.isPanelOpen, isFalse);
        expect(controller.messages, isEmpty);
        expect(controller.hasLoadedMessages, isTrue);
        expect(repo.clearMemoryCalls, 0);
        expect(repo.subscribeCalls, 1);
        expect(repo.streamCancelCalls, 0);
        expect(repo.activeStreamCount, 1);

        // Hard security clear (onLockOrSleep) immediately cancels SSE and purges RAM cache.
        window.emitLockOrSleep();
        await tester.pump();
        expect(repo.clearMemoryCalls, 1);
        expect(controller.hasLoadedMessages, isFalse);
        expect(controller.cachedMessages, isEmpty);
        expect(repo.activeStreamCount, 0);
      },
    );

    testWidgets(
      'cancels stream and clears messages on channel switch and detached lifecycle',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            guildId: 'guild-1',
            channelId: 'channel-1',
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(repo.subscribeCalls, 1);
        expect(repo.subscribedChannels.last.channelId, 'channel-1');
        expect(repo.activeStreamCount, 1);

        // Switch channel while panel is open -> old stream cancelled, memory wiped, new channel subscribed.
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(20)];
        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            guildId: 'guild-1',
            channelId: 'channel-2',
          ),
        );
        await _pumpSettled(tester);

        expect(repo.streamCancelCalls, 1);
        expect(repo.clearMemoryCalls, 1);
        expect(repo.subscribeCalls, 2);
        expect(repo.subscribedChannels.last.channelId, 'channel-2');
        expect(find.text('Message body 1'), findsNothing);
        expect(find.text('Message body 20'), findsOneWidget);

        // Detached lifecycle -> closes panel, cancels stream, wipes memory.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.detached,
        );
        await tester.pump();

        expect(controller.isPanelOpen, isFalse);
        expect(controller.messages, isEmpty);
        expect(repo.activeStreamCount, 0);
        expect(repo.streamCancelCalls, 2);
      },
    );

    testWidgets(
      'reconnects with backoff on transient stream disconnect and stops on fail-closed 403',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        var attempt = 0;
        late StreamController<ChannelMessageEvent> firstStream;
        late StreamController<ChannelMessageEvent> secondStream;
        late StreamController<ChannelMessageEvent> thirdStream;
        repo.onSubscribe = ({
          required String guildId,
          required String channelId,
          required Object requestToken,
        }) {
          attempt += 1;
          if (attempt == 1) {
            firstStream = StreamController<ChannelMessageEvent>();
            return firstStream.stream;
          }
          if (attempt == 2) {
            secondStream = StreamController<ChannelMessageEvent>();
            return secondStream.stream;
          }
          thirdStream = StreamController<ChannelMessageEvent>();
          return thirdStream.stream;
        };

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            streamReconnectBaseDelay: const Duration(milliseconds: 50),
            streamReconnectMaxDelay: const Duration(milliseconds: 200),
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(repo.subscribeCalls, 1);

        // Drop first stream cleanly -> reconnect scheduled after 50ms.
        await firstStream.close();
        await tester.pump(const Duration(milliseconds: 40));
        expect(repo.subscribeCalls, 1);
        await tester.pump(const Duration(milliseconds: 20));
        expect(repo.subscribeCalls, 2);

        // Second stream receives live message after reconnect.
        secondStream.add(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(42, timestamp: DateTime.utc(2026, 11, 25, 13, 0)),
          ),
        );
        await _pumpSettled(tester);
        expect(find.text('Message body 42'), findsOneWidget);

        // Fail-closed 403 error on stream -> wipes messages immediately and does NOT reconnect.
        secondStream.addError(
          const OrbException(
            code: 'access_denied',
            message: 'Access revoked',
            state: OrbPreviewState.accessDenied,
            statusCode: 403,
          ),
        );
        await _pumpSettled(tester);

        expect(controller.previewState, OrbPreviewState.accessDenied);
        expect(controller.messages, isEmpty);
        expect(find.text('Message body 42'), findsNothing);

        await tester.pump(const Duration(milliseconds: 300));
        expect(repo.subscribeCalls, 2);

        unawaited(secondStream.close());
      },
    );
  });

  group('SAN-62: Panel pin toggle & focus-loss retention', () {
    testWidgets(
      'MessagePanel header pin button toggles icon, tooltip, and callback',
      (WidgetTester tester) async {
        bool? lastPinned;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: 400,
                child: MessagePanel(
                  state: OrbPreviewState.loaded,
                  messages: <ChannelMessagePreview>[_msg(1)],
                  isPinned: true,
                  onPinnedChanged: (bool value) => lastPinned = value,
                ),
              ),
            ),
          ),
        );

        expect(find.byKey(MessagePanel.pinToggleButtonKey), findsOneWidget);
        expect(find.byIcon(Icons.push_pin), findsOneWidget);
        expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

        await tester.tap(find.byKey(MessagePanel.pinToggleButtonKey));
        await tester.pump();
        expect(lastPinned, isFalse);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: 400,
                child: MessagePanel(
                  state: OrbPreviewState.loaded,
                  messages: <ChannelMessagePreview>[_msg(1)],
                  isPinned: false,
                  onPinnedChanged: (bool value) => lastPinned = value,
                ),
              ),
            ),
          ),
        );

        expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
        expect(find.byIcon(Icons.push_pin), findsNothing);

        await tester.tap(find.byKey(MessagePanel.pinToggleButtonKey));
        await tester.pump();
        expect(lastPinned, isTrue);
      },
    );

    testWidgets(
      'keeps panel and SSE open on AppLifecycleState.inactive when pinned, syncs pin toggle, dismisses on onPanelDismissRequested, and always clears on onLockOrSleep',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(usesNativeWindowDrag: true);
        final controller = OrbShellController();
        bool? callbackPinned;
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(352, 576),
            panelPinned: true,
            onPanelPinnedChanged: (bool pinned) => callbackPinned = pinned,
          ),
        );

        expect(window.pinnedCalls, <bool>[true]);
        expect(controller.isPanelPinned, isTrue);

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(controller.isPanelOpen, isTrue);
        expect(repo.activeStreamCount, 1);

        // External app activation triggers AppLifecycleState.inactive -> MUST stay open & streaming!
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();

        expect(controller.isPanelOpen, isTrue);
        expect(controller.messages, hasLength(1));
        expect(repo.activeStreamCount, 1);
        expect(window.collapseCount, 0);

        // Live message still arrives while inactive.
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(2, timestamp: DateTime.utc(2026, 11, 25, 14, 0)),
          ),
        );
        await _pumpSettled(tester);
        expect(find.text('Message body 2'), findsOneWidget);

        // Toggle pin OFF from MessagePanel header -> syncs to windowController & callback.
        await tester.tap(find.byKey(MessagePanel.pinToggleButtonKey));
        await tester.pump();
        expect(controller.isPanelPinned, isFalse);
        expect(callbackPinned, isFalse);
        expect(window.pinnedCalls, <bool>[true, false]);

        // Unpinned focus-loss (forwarded by native window as onPanelDismissRequested) dismisses panel.
        window.emitPanelDismissRequested();
        await tester.pump();
        expect(controller.isPanelOpen, isFalse);
        expect(controller.messages, isEmpty);
        expect(window.collapseCount, 1);

        // Re-open, pin back ON, and verify onLockOrSleep ALWAYS clears even when pinned!
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        await tester.tap(find.byKey(MessagePanel.pinToggleButtonKey));
        await tester.pump();
        expect(controller.isPanelPinned, isTrue);
        expect(window.pinnedCalls, <bool>[true, false, true]);

        window.emitLockOrSleep();
        await tester.pump();
        expect(controller.isPanelOpen, isFalse);
        expect(controller.messages, isEmpty);
        expect(repo.activeStreamCount, 0);
        expect(window.collapseCount, 2);
      },
    );
  });

  group('SAN-61: Collapsed orb real-time toast popup', () {
    testWidgets(
      'subscribes in background when collapsed, ignores ready frame, shows toast below/above, updates on consecutive messages, and auto-dismisses after 5s',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(
          usesNativeWindowDrag: true,
          toastDirection: OrbPanelExpandDirection.below,
        );
        final controller = OrbShellController();

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: OrbShell.toastWindowSize,
            toastNotificationsEnabled: true,
          ),
        );

        // Background SSE starts automatically when collapsed with toast enabled.
        expect(repo.subscribeCalls, 1);
        expect(repo.activeStreamCount, 1);
        expect(controller.isPanelOpen, isFalse);
        expect(controller.isToastVisible, isFalse);

        // Initial ready frame must NOT trigger a toast.
        repo.emitEvent(
          const ChannelMessageEvent.ready(
            guildId: 'guild-1',
            channelId: 'channel-1',
          ),
        );
        await tester.pump();
        expect(controller.isToastVisible, isFalse);
        expect(window.toastOverlayCount, 0);
        expect(find.byKey(OrbMessageToast.toastCardKey), findsNothing);

        // Incoming message_create shows floating toast below orb.
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: ChannelMessagePreview(
              id: 'toast-1',
              authorName: 'Alice',
              timestamp: DateTime.utc(2026, 11, 26, 9, 0),
              content: 'First live alert\nSecond line',
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.isToastVisible, isTrue);
        expect(controller.toastMessage?.id, 'toast-1');
        expect(window.toastOverlayCount, 1);
        expect(window.lastToastSize, OrbShell.toastWindowSize);
        expect(find.byKey(OrbMessageToast.toastCardKey), findsOneWidget);
        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('First live alert Second line'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(OrbMessageToast),
            matching: find.byType(OrbAvatar),
          ),
          findsOneWidget,
        );

        final orbRectBelow = tester.getRect(find.byKey(OrbButton.orbButtonKey));
        final toastRectBelow =
            tester.getRect(find.byKey(OrbMessageToast.toastCardKey));
        expect(toastRectBelow.top, greaterThanOrEqualTo(orbRectBelow.bottom));
        expect(orbRectBelow.overlaps(toastRectBelow), isFalse);

        // After 3 seconds, consecutive message_create queues WITHOUT overwriting first toast!
        await tester.pump(const Duration(seconds: 3));
        expect(controller.isToastVisible, isTrue);

        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: ChannelMessagePreview(
              id: 'toast-2',
              authorName: 'Bob',
              timestamp: DateTime.utc(2026, 11, 26, 9, 1),
              content: 'Second queued alert',
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.toastMessage?.id, 'toast-2');
        expect(controller.toastMessages.map((m) => m.id), <String>[
          'toast-2',
          'toast-1',
        ]);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Second queued alert'), findsOneWidget);
        expect(find.text('Alice'), findsOneWidget);

        // 2s later (t=5s): toast-1 expires independently; toast-2 stays visible!
        await tester.pump(const Duration(seconds: 2));
        expect(controller.isToastVisible, isTrue);
        expect(controller.toastMessages.map((m) => m.id), <String>['toast-2']);
        expect(find.text('Alice'), findsNothing);
        expect(find.text('Bob'), findsOneWidget);
        expect(window.collapseCount, 0);

        // 3s more (t=8s, 5s since toast-2): toast-2 expires -> queue empty -> collapses!
        await tester.pump(const Duration(seconds: 3));
        expect(controller.isToastVisible, isFalse);
        expect(controller.toastMessage, isNull);
        expect(controller.toastMessages, isEmpty);
        expect(find.byKey(OrbMessageToast.toastCardKey), findsNothing);
        expect(window.collapseCount, 1);
        // Background SSE stays active after auto-dismiss.
        expect(repo.activeStreamCount, 1);

        // Next toast when native window chooses `above` renders strictly above orb.
        window.toastDirection = OrbPanelExpandDirection.above;
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: ChannelMessagePreview(
              id: 'toast-3',
              authorName: 'Carol',
              timestamp: DateTime.utc(2026, 11, 26, 9, 2),
              content: 'Above-orb notification',
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.toastDirection, OrbPanelExpandDirection.above);
        final orbRectAbove = tester.getRect(find.byKey(OrbButton.orbButtonKey));
        final toastRectAbove =
            tester.getRect(find.byKey(OrbMessageToast.toastCardKey));
        expect(toastRectAbove.bottom, lessThanOrEqualTo(orbRectAbove.top));
        expect(orbRectAbove.overlaps(toastRectAbove), isFalse);

        // Manual dismiss X button clears toast and collapses without stopping SSE.
        await tester.tap(find.byKey(OrbMessageToast.dismissButtonKey));
        await tester.pump();
        expect(controller.isToastVisible, isFalse);
        expect(controller.toastMessage, isNull);
        expect(window.collapseCount, 2);
        expect(repo.activeStreamCount, 1);
      },
    );

    testWidgets(
      'multi-toast stack enforces maxVisibleToastCount with overflow deck visual, promotes on expiry/dismiss, and applies message_update/delete',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(420, 800),
            toastNotificationsEnabled: true,
            maxVisibleToastCount: 3,
          ),
        );

        // Emit 5 messages staggered by 1s each.
        for (var i = 1; i <= 5; i++) {
          repo.emitEvent(
            ChannelMessageEvent.create(
              guildId: 'guild-1',
              channelId: 'channel-1',
              message: _msg(i, timestamp: DateTime.utc(2026, 11, 26, 11, i)),
            ),
          );
          await tester.pump();
          await tester.pump();
          if (i < 5) {
            await tester.pump(const Duration(seconds: 1));
          }
        }

        // At t=4s: 5 queued, 3 visible (msg_5, msg_4, msg_3), +2 overflow deck!
        expect(controller.toastMessages.map((m) => m.id), <String>[
          'msg_5',
          'msg_4',
          'msg_3',
          'msg_2',
          'msg_1',
        ]);
        expect(find.byKey(OrbMessageToastStack.stackKey), findsOneWidget);
        expect(find.byKey(OrbMessageToast.cardKeyFor('msg_5')), findsOneWidget);
        expect(find.byKey(OrbMessageToast.cardKeyFor('msg_4')), findsOneWidget);
        expect(find.byKey(OrbMessageToast.cardKeyFor('msg_3')), findsOneWidget);
        expect(find.byKey(OrbMessageToast.cardKeyFor('msg_2')), findsNothing);
        expect(find.byKey(OrbMessageToast.cardKeyFor('msg_1')), findsNothing);
        expect(
          find.byKey(OrbMessageToastStack.overflowLayerKey(0)),
          findsOneWidget,
        );
        expect(
          find.byKey(OrbMessageToastStack.overflowLayerKey(1)),
          findsOneWidget,
        );
        expect(
          find.byKey(OrbMessageToastStack.overflowBadgeKey),
          findsOneWidget,
        );
        expect(find.text('+2 more'), findsOneWidget);

        // message_update updates active visible toast content in place.
        repo.emitEvent(
          const ChannelMessageEvent.update(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_4',
            content: 'Updated body 4',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('Updated body 4'), findsOneWidget);

        // Dismiss individual card msg_4 -> promotes overflow msg_2 into visible slot!
        await tester.tap(
          find.byKey(OrbMessageToast.dismissButtonKeyFor('msg_4')),
        );
        await tester.pump();

        expect(controller.toastMessages.map((m) => m.id), <String>[
          'msg_5',
          'msg_3',
          'msg_2',
          'msg_1',
        ]);
        expect(find.byKey(OrbMessageToast.cardKeyFor('msg_4')), findsNothing);
        expect(find.byKey(OrbMessageToast.cardKeyFor('msg_2')), findsOneWidget);
        expect(find.text('+1 more'), findsOneWidget);
        expect(
          find.byKey(OrbMessageToastStack.overflowLayerKey(0)),
          findsOneWidget,
        );
        expect(
          find.byKey(OrbMessageToastStack.overflowLayerKey(1)),
          findsNothing,
        );

        // message_delete removes msg_1 -> 3 left -> overflow deck disappears!
        repo.emitEvent(
          const ChannelMessageEvent.delete(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_1',
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.toastMessages.map((m) => m.id), <String>[
          'msg_5',
          'msg_3',
          'msg_2',
        ]);
        expect(find.byKey(OrbMessageToastStack.overflowBadgeKey), findsNothing);

        // Wait until all remaining toasts expire independently (msg_2 at t=6s, msg_3 at t=7s, msg_5 at t=9s).
        await tester.pump(const Duration(seconds: 2)); // t=6s -> msg_2 expires
        expect(controller.toastMessages.map((m) => m.id), <String>[
          'msg_5',
          'msg_3',
        ]);
        await tester.pump(const Duration(seconds: 1)); // t=7s -> msg_3 expires
        expect(controller.toastMessages.map((m) => m.id), <String>['msg_5']);
        await tester.pump(const Duration(seconds: 2)); // t=9s -> msg_5 expires
        expect(controller.toastMessages, isEmpty);
        expect(window.collapseCount, 1);
      },
    );

    testWidgets(
      'usesNativeToastOverlay delegates stack to updateToastStack/hideToastStack without resizing collapsed 80x80 window and handles onToastTapped/onToastDismissed/onLockOrSleep',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(
          usesNativeWindowDrag: true,
          usesNativeToastOverlay: true,
        );
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1), _msg(2)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(80, 80),
            toastNotificationsEnabled: true,
            maxVisibleToastCount: 2,
          ),
        );

        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(1, timestamp: DateTime.utc(2026, 11, 26, 12, 1)),
          ),
        );
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(2, timestamp: DateTime.utc(2026, 11, 26, 12, 2)),
          ),
        );
        await tester.pump();
        await tester.pump();

        // Main 80x80 window NEVER calls showToastOverlay or collapsePanel!
        expect(window.toastOverlayCount, 0);
        expect(window.collapseCount, 0);
        expect(find.byType(OrbMessageToastStack), findsNothing);
        expect(window.toastStackUpdates, hasLength(2));
        expect(
          window.toastStackUpdates.last.messages.map((m) => m.id),
          <String>['msg_2', 'msg_1'],
        );
        expect(window.toastStackUpdates.last.maxVisibleCount, 2);

        // Native dismiss of msg_1 pushes remaining [msg_2] without collapsing 80x80 window.
        window.emitToastDismissed('msg_1');
        await tester.pump();
        expect(window.toastStackUpdates, hasLength(3));
        expect(
          window.toastStackUpdates.last.messages.map((m) => m.id),
          <String>['msg_2'],
        );
        expect(window.hideToastStackCount, 0);

        // Native tap on toast clears queue, hides native toast panel, and opens full MessagePanel!
        window.emitToastTapped();
        await _pumpSettled(tester);

        expect(controller.isPanelOpen, isTrue);
        expect(controller.toastMessages, isEmpty);
        expect(window.hideToastStackCount, 1);
        expect(window.expandCount, 1);

        // Close panel, receive a new toast, then verify onLockOrSleep calls hideToastStack (NOT collapsePanel!).
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        expect(window.collapseCount, 1);

        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(3, timestamp: DateTime.utc(2026, 11, 26, 12, 3)),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.isToastVisible, isTrue);

        window.emitLockOrSleep();
        await tester.pump();
        expect(controller.isToastVisible, isFalse);
        expect(controller.toastMessages, isEmpty);
        expect(window.hideToastStackCount, 2);
        expect(window.collapseCount, 1); // Unchanged! 80x80 orb window untouched.
        expect(repo.activeStreamCount, 0);
      },
    );

    testWidgets(
      'tapping toast opens full MessagePanel seamlessly and closing panel keeps background toast SSE listening',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[
              _msg(1, timestamp: DateTime.utc(2026, 11, 26, 10, 0)),
              _msg(2, timestamp: DateTime.utc(2026, 11, 26, 10, 1)),
            ];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            toastNotificationsEnabled: true,
          ),
        );

        expect(repo.subscribeCalls, 1);
        expect(repo.activeStreamCount, 1);

        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(2, timestamp: DateTime.utc(2026, 11, 26, 10, 1)),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.byKey(OrbMessageToast.toastCardKey), findsOneWidget);

        // Tap toast body -> clears toast, opens full panel, preserves active SSE!
        await tester.tap(find.byKey(OrbMessageToast.toastCardKey));
        await _pumpSettled(tester);

        expect(controller.isPanelOpen, isTrue);
        expect(controller.isToastVisible, isFalse);
        expect(controller.toastMessage, isNull);
        expect(window.expandCount, 1);
        expect(find.byType(MessagePanel), findsOneWidget);
        expect(find.text('Message body 2'), findsOneWidget);
        expect(repo.subscribeCalls, 1); // Active SSE reused seamlessly
        expect(repo.activeStreamCount, 1);

        // Advancing past 5s must NOT collapse the opened panel (toast timer was cancelled).
        await tester.pump(const Duration(seconds: 6));
        expect(controller.isPanelOpen, isTrue);
        expect(window.collapseCount, 0);

        // Explicit panel close collapses panel while keeping single persistent SSE and warm RAM cache.
        await tester.tap(find.byKey(MessagePanel.closeButtonKey));
        await tester.pump();

        expect(controller.isPanelOpen, isFalse);
        expect(controller.messages, isEmpty);
        expect(controller.hasLoadedMessages, isTrue);
        expect(repo.clearMemoryCalls, 0);
        expect(repo.subscribeCalls, 1);
        expect(repo.streamCancelCalls, 0);
        expect(window.collapseCount, 1);
        expect(repo.activeStreamCount, 1);

        // Subsequent incoming message shows toast again!
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(3, timestamp: DateTime.utc(2026, 11, 26, 10, 2)),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.isToastVisible, isTrue);
        expect(find.text('Message body 3'), findsOneWidget);

        // Clean up timer before test ends.
        await tester.pump(const Duration(seconds: 5));
      },
    );

    testWidgets(
      'onLockOrSleep and fail-closed 401/403/503 stop SSE, wipe toast and panel memory, and do not reconnect',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            toastNotificationsEnabled: true,
            streamReconnectBaseDelay: const Duration(milliseconds: 50),
          ),
        );

        expect(repo.activeStreamCount, 1);

        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(10),
          ),
        );
        await tester.pump();
        expect(controller.isToastVisible, isTrue);

        // Lock/sleep immediately wipes toast, collapses overlay, and halts SSE.
        window.emitLockOrSleep();
        await tester.pump();

        expect(controller.isToastVisible, isFalse);
        expect(controller.toastMessage, isNull);
        expect(repo.activeStreamCount, 0);
        expect(window.collapseCount, 1);

        // AppLifecycleState.resumed restores background SSE.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(repo.activeStreamCount, 1);

        // Terminal 401/403/503 error on background stream wipes toast & stops reconnecting.
        for (final terminalState in <(OrbPreviewState, int)>[
          (OrbPreviewState.sessionExpired, 401),
          (OrbPreviewState.accessDenied, 403),
          (OrbPreviewState.botUnavailable, 503),
        ]) {
          final errRepo = _FakePreviewRepository();
          final errWindow = _RecordingWindowController();
          final errController = OrbShellController();
          late StreamController<ChannelMessageEvent> streamCtrl;
          errRepo.onSubscribe = ({
            required String guildId,
            required String channelId,
            required Object requestToken,
          }) {
            streamCtrl = StreamController<ChannelMessageEvent>();
            return streamCtrl.stream;
          };

          await tester.pumpWidget(
            _wrapShell(
              shellKey: UniqueKey(),
              previewRepository: errRepo,
              windowController: errWindow,
              controller: errController,
              toastNotificationsEnabled: true,
              streamReconnectBaseDelay: const Duration(milliseconds: 30),
            ),
          );
          expect(errRepo.subscribeCalls, 1);

          streamCtrl.add(
            ChannelMessageEvent.create(
              guildId: 'guild-1',
              channelId: 'channel-1',
              message: _msg(99),
            ),
          );
          await tester.pump();
          expect(errController.isToastVisible, isTrue);

          streamCtrl.addError(
            OrbException(
              code: 'terminal_${terminalState.$2}',
              message: 'Blocked',
              state: terminalState.$1,
              statusCode: terminalState.$2,
            ),
          );
          await tester.pump();

          expect(errController.isToastVisible, isFalse);
          expect(errController.toastMessage, isNull);
          expect(errWindow.collapseCount, 1);

          await tester.pump(const Duration(milliseconds: 150));
          expect(errRepo.subscribeCalls, 1); // Did NOT reconnect!
          unawaited(streamCtrl.close());
        }
      },
    );

    testWidgets(
      'disabling toastNotificationsEnabled dismisses active toast while keeping collapsed SSE alive for unread badge',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            toastNotificationsEnabled: true,
          ),
        );
        expect(repo.activeStreamCount, 1);

        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(5),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.isToastVisible, isTrue);
        expect(controller.unreadCount, 1);

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            toastNotificationsEnabled: false,
          ),
        );
        await tester.pump();

        expect(controller.isToastVisible, isFalse);
        expect(controller.toastMessage, isNull);
        expect(window.collapseCount, 1);
        // Collapsed SSE stays alive and unread badge count is preserved!
        expect(repo.activeStreamCount, 1);
        expect(controller.unreadCount, 1);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsOneWidget);
        expect(find.text('1'), findsOneWidget);
      },
    );

    testWidgets(
      'MessagePanel header toast quick toggle and native context-menu onToastEnabledToggled hide toasts while keeping collapsed SSE alive',
      (WidgetTester tester) async {
        // 1. Standalone MessagePanel header toggle icon & callback.
        bool? panelToastToggled;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: 400,
                child: MessagePanel(
                  state: OrbPreviewState.loaded,
                  messages: <ChannelMessagePreview>[_msg(1)],
                  toastNotificationsEnabled: true,
                  onToastNotificationsChanged: (bool value) =>
                      panelToastToggled = value,
                ),
              ),
            ),
          ),
        );
        expect(find.byKey(MessagePanel.toastToggleButtonKey), findsOneWidget);
        expect(find.byIcon(Icons.notifications_active_outlined), findsOneWidget);
        await tester.tap(find.byKey(MessagePanel.toastToggleButtonKey));
        await tester.pump();
        expect(panelToastToggled, isFalse);

        // 2. OrbShell with usesNativeToastOverlay: header toggle & native context-menu toggle.
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(
          usesNativeWindowDrag: true,
          usesNativeToastOverlay: true,
        );
        final controller = OrbShellController();
        bool? shellToastCallback;
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            shellKey: UniqueKey(),
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(352, 576),
            toastNotificationsEnabled: true,
            onToastNotificationsChanged: (bool enabled) =>
                shellToastCallback = enabled,
          ),
        );
        expect(repo.activeStreamCount, 1);

        // Show a toast while collapsed, then turn toasts off via native context menu.
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(20),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.isToastVisible, isTrue);
        expect(controller.unreadCount, 1);

        window.emitToastEnabledToggled(false);
        await tester.pump();

        expect(shellToastCallback, isFalse);
        expect(controller.isToastNotificationsEnabled, isFalse);
        expect(controller.isToastVisible, isFalse);
        expect(controller.toastMessages, isEmpty);
        expect(window.hideToastStackCount, 1);
        // Collapsed SSE stays alive for unread badge tracking!
        expect(repo.activeStreamCount, 1);
        expect(controller.unreadCount, 1);

        // Open panel -> clears unread badge; toggle toast back ON from header.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(controller.unreadCount, 0);
        expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);

        await tester.tap(find.byKey(MessagePanel.toastToggleButtonKey));
        await tester.pump();
        expect(shellToastCallback, isTrue);
        expect(controller.isToastNotificationsEnabled, isTrue);
        expect(window.isToastNotificationsEnabled, isTrue);
        expect(find.byIcon(Icons.notifications_active_outlined), findsOneWidget);

        await tester.tap(find.byKey(MessagePanel.closeButtonKey));
        await tester.pump();
        expect(repo.activeStreamCount, 1);
      },
    );

    testWidgets(
      'OrbButton unread badge displays 1, 9, 99+ only when collapsed and hides when 0 or expanded',
      (WidgetTester tester) async {
        Future<void> pumpBadge({
          required bool isPanelOpen,
          required int unreadCount,
        }) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: Center(
                      child: OrbButton(
                        isPanelOpen: isPanelOpen,
                        unreadCount: unreadCount,
                        onTap: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        await pumpBadge(isPanelOpen: false, unreadCount: 0);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsNothing);

        await pumpBadge(isPanelOpen: false, unreadCount: 1);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsOneWidget);
        expect(find.text('1'), findsOneWidget);

        await pumpBadge(isPanelOpen: false, unreadCount: 9);
        expect(find.text('9'), findsOneWidget);

        await pumpBadge(isPanelOpen: false, unreadCount: 100);
        expect(find.text('99+'), findsOneWidget);

        // Badge stays cleanly within the 80x80 collapsed overlay window bounds.
        final boxRect = tester.getRect(find.byType(SizedBox).first);
        final badgeRect = tester.getRect(find.byKey(OrbButton.unreadBadgeKey));
        expect(badgeRect.top, greaterThanOrEqualTo(boxRect.top));
        expect(badgeRect.right, lessThanOrEqualTo(boxRect.right));

        await pumpBadge(isPanelOpen: true, unreadCount: 5);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsNothing);
      },
    );

    testWidgets(
      'collapsed SSE updates unread badge when toasts are off, clears on orb tap, and wipes on onLockOrSleep and 401/403/503',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(
          usesNativeWindowDrag: true,
          usesNativeToastOverlay: true,
        );
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(1)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(80, 80),
            toastNotificationsEnabled: false,
          ),
        );

        expect(repo.activeStreamCount, 1);
        expect(controller.unreadCount, 0);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsNothing);

        // Incoming messages increment badge without showing any toast overlay.
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(1),
          ),
        );
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(2),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.unreadCount, 2);
        expect(controller.toastMessages, isEmpty);
        expect(window.toastOverlayCount, 0);
        expect(window.toastStackUpdates, isEmpty);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsOneWidget);
        expect(find.text('2'), findsOneWidget);

        // message_delete decrements unread badge count.
        repo.emitEvent(
          const ChannelMessageEvent.delete(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_1',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.unreadCount, 1);
        expect(find.text('1'), findsOneWidget);

        // Opening orb resets unread badge to 0.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(controller.isPanelOpen, isTrue);
        expect(controller.unreadCount, 0);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsNothing);

        // Close panel -> collapsed SSE stays active; new message increments badge; onLockOrSleep clears badge & closes SSE.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        expect(repo.activeStreamCount, 1);

        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(3),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.unreadCount, 1);

        window.emitLockOrSleep();
        await tester.pump();
        expect(controller.unreadCount, 0);
        expect(repo.activeStreamCount, 0);
        expect(find.byKey(OrbButton.unreadBadgeKey), findsNothing);

        // Fail-closed 401/403/503 closes SSE and wipes unread badge to 0.
        for (final terminalState in <(OrbPreviewState, int)>[
          (OrbPreviewState.sessionExpired, 401),
          (OrbPreviewState.accessDenied, 403),
          (OrbPreviewState.botUnavailable, 503),
        ]) {
          final errRepo = _FakePreviewRepository();
          final errWindow = _RecordingWindowController();
          final errController = OrbShellController();
          late StreamController<ChannelMessageEvent> streamCtrl;
          errRepo.onSubscribe = ({
            required String guildId,
            required String channelId,
            required Object requestToken,
          }) {
            streamCtrl = StreamController<ChannelMessageEvent>();
            return streamCtrl.stream;
          };

          await tester.pumpWidget(
            _wrapShell(
              shellKey: UniqueKey(),
              previewRepository: errRepo,
              windowController: errWindow,
              controller: errController,
              toastNotificationsEnabled: false,
            ),
          );

          streamCtrl.add(
            ChannelMessageEvent.create(
              guildId: 'guild-1',
              channelId: 'channel-1',
              message: _msg(77),
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(errController.unreadCount, 1);

          streamCtrl.addError(
            OrbException(
              code: 'terminal_${terminalState.$2}',
              message: 'Blocked',
              state: terminalState.$1,
              statusCode: terminalState.$2,
            ),
          );
          await tester.pump();
          await tester.pump();

          expect(errController.unreadCount, 0);
          expect(find.byKey(OrbButton.unreadBadgeKey), findsNothing);
          unawaited(streamCtrl.close());
        }
      },
    );

    testWidgets(
      'OrbMessageToastStack caps stacked overflow card-back layers at 3 (1->1, 2->2, 3->3, 5->3) and renders unclipped badge in both directions',
      (WidgetTester tester) async {
        // Verify height estimator caps overflow layers at maxOverflowLayers (3).
        expect(
          OrbMessageToastStack.estimateHeight(
            visibleCount: 3,
            overflowCount: 3,
          ),
          OrbMessageToastStack.estimateHeight(
            visibleCount: 3,
            overflowCount: 10,
          ),
        );
        expect(
          OrbMessageToastStack.estimateHeight(
            visibleCount: 3,
            overflowCount: 1,
          ),
          lessThan(
            OrbMessageToastStack.estimateHeight(
              visibleCount: 3,
              overflowCount: 3,
            ),
          ),
        );
        expect(
          OrbMessageToastStack.estimateHeight(
            visibleCount: 3,
            overflowCount: 2,
            compact: true,
          ),
          lessThan(
            OrbMessageToastStack.estimateHeight(
              visibleCount: 3,
              overflowCount: 2,
              compact: false,
            ),
          ),
        );

        Future<void> pumpStack({
          required int totalMessages,
          required PanelPlacementDirection direction,
          ChatListLayout layout = ChatListLayout.standard,
        }) async {
          final messages = List<ChannelMessagePreview>.generate(
            totalMessages,
            (int i) => _msg(i + 1),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 288,
                    child: OrbMessageToastStack(
                      messages: messages,
                      maxVisibleCount: 2,
                      direction: direction,
                      layout: layout,
                      channelName: 'general',
                      onTapStack: () {},
                      onDismissMessage: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
        }

        // 0 overflow -> 0 layers, no badge.
        await pumpStack(
          totalMessages: 2,
          direction: PanelPlacementDirection.below,
        );
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(0)), findsNothing);
        expect(find.byKey(OrbMessageToastStack.overflowBadgeKey), findsNothing);

        // 1 overflow -> 1 layer + '+1 more'
        await pumpStack(
          totalMessages: 3,
          direction: PanelPlacementDirection.below,
        );
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(0)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(1)), findsNothing);
        expect(find.text('+1 more'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 2 overflow -> 2 layers + '+2 more'
        await pumpStack(
          totalMessages: 4,
          direction: PanelPlacementDirection.below,
        );
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(0)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(1)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(2)), findsNothing);
        expect(find.text('+2 more'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 3 overflow -> 3 layers + '+3 more'
        await pumpStack(
          totalMessages: 5,
          direction: PanelPlacementDirection.below,
        );
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(0)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(1)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(2)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(3)), findsNothing);
        expect(find.text('+3 more'), findsOneWidget);

        // 5 overflow -> STILL capped at 3 layers + '+5 more' (both below and above)
        for (final direction in PanelPlacementDirection.values) {
          await pumpStack(
            totalMessages: 7,
            direction: direction,
          );
          expect(find.byKey(OrbMessageToastStack.overflowLayerKey(0)), findsOneWidget);
          expect(find.byKey(OrbMessageToastStack.overflowLayerKey(1)), findsOneWidget);
          expect(find.byKey(OrbMessageToastStack.overflowLayerKey(2)), findsOneWidget);
          expect(find.byKey(OrbMessageToastStack.overflowLayerKey(3)), findsNothing);
          expect(find.text('+5 more'), findsOneWidget);
          final stackRect = tester.getRect(find.byKey(OrbMessageToastStack.stackKey));
          final badgeRect =
              tester.getRect(find.byKey(OrbMessageToastStack.overflowBadgeKey));
          expect(badgeRect.top, greaterThanOrEqualTo(stackRect.top - 0.01));
          expect(badgeRect.bottom, lessThanOrEqualTo(stackRect.bottom + 0.01));
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      'compact 1-line toast mode renders single-line cards with 20px avatar, smaller height than standard, and max-3 overflow deck',
      (WidgetTester tester) async {
        final multilineMessage = ChannelMessagePreview(
          id: 'compact-1',
          authorName: 'Alice',
          timestamp: DateTime.utc(2026, 11, 26, 12, 0),
          content: 'Line one\nLine two\twith spaces',
        );

        Future<Size> pumpSingleToast(ChatListLayout layout) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 288,
                    child: OrbMessageToast(
                      message: multilineMessage,
                      channelName: 'general',
                      layout: layout,
                      onTap: () {},
                      onDismiss: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          return tester.getSize(find.byKey(OrbMessageToast.toastCardKey));
        }

        final standardSize = await pumpSingleToast(ChatListLayout.standard);
        final compactSize = await pumpSingleToast(ChatListLayout.compact);

        expect(compactSize.height, lessThan(standardSize.height));
        expect(compactSize.height, lessThanOrEqualTo(44));
        expect(
          tester.widget<OrbAvatar>(find.byType(OrbAvatar)).size,
          20,
        );
        // Compact mode flattens newlines to spaces and renders single-line body.
        expect(find.text('Line one Line two with spaces'), findsOneWidget);
        final bodyText = tester.widget<Text>(
          find.text('Line one Line two with spaces'),
        );
        expect(bodyText.maxLines, 1);
        expect(bodyText.overflow, TextOverflow.ellipsis);
        // Channel suffix is omitted in compact 1-line mode.
        expect(find.text('#general'), findsNothing);
        expect(tester.takeException(), isNull);

        // Compact stack with 6 messages (max 2 visible -> 4 overflow -> capped at 3 layers).
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 288,
                  child: OrbMessageToastStack(
                    messages: List<ChannelMessagePreview>.generate(
                      6,
                      (int i) => _msg(i + 1),
                    ),
                    maxVisibleCount: 2,
                    layout: ChatListLayout.compact,
                    onTapStack: () {},
                    onDismissMessage: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(0)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(1)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(2)), findsOneWidget);
        expect(find.byKey(OrbMessageToastStack.overflowLayerKey(3)), findsNothing);
        expect(find.text('+4 more'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'OrbShell forwards compact flag to native updateToastStack and syncs native onToastLayoutToggled',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController(
          usesNativeWindowDrag: true,
          usesNativeToastOverlay: true,
        );
        final controller = OrbShellController();
        ChatListLayout? callbackLayout;

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            viewportSize: const Size(80, 80),
            toastNotificationsEnabled: true,
            toastLayout: ChatListLayout.standard,
            onToastLayoutChanged: (ChatListLayout layout) =>
                callbackLayout = layout,
          ),
        );

        expect(controller.toastLayout, ChatListLayout.standard);

        // Incoming message pushes standard (compact: false) native toast stack.
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(41),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(window.toastStackUpdates, hasLength(1));
        expect(window.toastStackUpdates.last.compact, isFalse);

        // Native right-click menu toggles Compact Toasts ON -> updates controller, callback, and re-pushes compact: true!
        window.emitToastLayoutToggled(ChatListLayout.compact);
        await tester.pump();

        expect(controller.toastLayout, ChatListLayout.compact);
        expect(callbackLayout, ChatListLayout.compact);
        expect(window.toastStackUpdates, hasLength(2));
        expect(window.toastStackUpdates.last.compact, isTrue);

        // Toggle back to standard -> re-pushes compact: false.
        window.emitToastLayoutToggled(ChatListLayout.standard);
        await tester.pump();

        expect(controller.toastLayout, ChatListLayout.standard);
        expect(callbackLayout, ChatListLayout.standard);
        expect(window.toastStackUpdates, hasLength(3));
        expect(window.toastStackUpdates.last.compact, isFalse);

        // Let toast auto-expire cleanly.
        await tester.pump(const Duration(seconds: 5));
      },
    );
  });

  group('Aurora Nebula Glass Pure Sphere OrbButton', () {
    testWidgets(
      'renders pure sphere with CustomPaint and zero center icon when collapsed, crisp X when open, and unread glow state',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: OrbButton(
                  isPanelOpen: false,
                  unreadCount: 0,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );

        final paintFinder = find.byKey(OrbButton.auroraPaintKey);
        expect(paintFinder, findsOneWidget);
        // Pure Sphere: NO chat bubble or any Icon inside collapsed OrbButton.
        expect(
          find.descendant(
            of: find.byKey(OrbButton.orbButtonKey),
            matching: find.byType(Icon),
          ),
          findsNothing,
        );
        final collapsedPainter =
            tester.widget<CustomPaint>(paintFinder).painter! as AuroraOrbPainter;
        expect(collapsedPainter.isPanelOpen, isFalse);
        expect(collapsedPainter.hasUnread, isFalse);
        final initialPhase = collapsedPainter.phase;

        // Animation ticks continuously forward while mounted.
        await tester.pump(const Duration(milliseconds: 900));
        final nextPainter =
            tester.widget<CustomPaint>(paintFinder).painter! as AuroraOrbPainter;
        expect(nextPainter.phase, isNot(initialPhase));

        // Unread state activates cyan unread highlight + unread badge while keeping pure sphere.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: OrbButton(
                  isPanelOpen: false,
                  unreadCount: 4,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        final unreadPainter =
            tester.widget<CustomPaint>(paintFinder).painter! as AuroraOrbPainter;
        expect(unreadPainter.hasUnread, isTrue);
        expect(unreadPainter.unreadProgress, greaterThan(0.5));
        expect(find.byKey(OrbButton.unreadBadgeKey), findsOneWidget);
        expect(find.text('4'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(OrbButton.orbButtonKey),
            matching: find.byType(Icon),
          ),
          findsNothing,
        );

        // Open state renders crisp white close icon and calms aurora (openProgress -> 1.0).
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: OrbButton(
                  isPanelOpen: true,
                  unreadCount: 4,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        final openPainter =
            tester.widget<CustomPaint>(paintFinder).painter! as AuroraOrbPainter;
        expect(openPainter.isPanelOpen, isTrue);
        expect(openPainter.hasUnread, isFalse);
        expect(openPainter.openProgress, greaterThan(0.5));
        expect(find.byKey(OrbButton.unreadBadgeKey), findsNothing);
        final closeIcon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(OrbButton.orbButtonKey),
            matching: find.byIcon(Icons.close),
          ),
        );
        expect(closeIcon.color, Colors.white);
      },
    );

    testWidgets(
      'auto-pauses aurora animation when MediaQuery.disableAnimations, TickerMode disabled, or animate == false',
      (WidgetTester tester) async {
        // 1. MediaQuery.disableAnimations == true -> pumpAndSettle completes cleanly without timeout.
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: OrbButton(
                    isPanelOpen: false,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final phase1 = (tester
                .widget<CustomPaint>(find.byKey(OrbButton.auroraPaintKey))
                .painter! as AuroraOrbPainter)
            .phase;
        await tester.pump(const Duration(seconds: 2));
        final phase2 = (tester
                .widget<CustomPaint>(find.byKey(OrbButton.auroraPaintKey))
                .painter! as AuroraOrbPainter)
            .phase;
        expect(phase2, phase1);

        // 2. TickerMode(enabled: false) -> pauses cleanly.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TickerMode(
                enabled: false,
                child: Center(
                  child: OrbButton(
                    isPanelOpen: false,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 3. animate: false -> pauses cleanly.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: OrbButton(
                  isPanelOpen: false,
                  animate: false,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      },
    );

    test('AuroraOrbPainter paints cleanly across phases/states and checks shouldRepaint',
        () {
      const painterA = AuroraOrbPainter(
        phase: 0.0,
        isPanelOpen: false,
        hasUnread: false,
        openProgress: 0.0,
        unreadProgress: 0.0,
      );
      const painterSame = AuroraOrbPainter(
        phase: 0.0,
        isPanelOpen: false,
        hasUnread: false,
        openProgress: 0.0,
        unreadProgress: 0.0,
      );
      const painterPhaseMoved = AuroraOrbPainter(
        phase: 0.5,
        isPanelOpen: false,
        hasUnread: false,
        openProgress: 0.0,
        unreadProgress: 0.0,
      );
      const painterUnread = AuroraOrbPainter(
        phase: 1.0,
        isPanelOpen: false,
        hasUnread: true,
        openProgress: 0.0,
        unreadProgress: 1.0,
      );
      const painterOpen = AuroraOrbPainter(
        phase: 0.25,
        isPanelOpen: true,
        hasUnread: false,
        openProgress: 1.0,
        unreadProgress: 0.0,
      );

      expect(painterA.shouldRepaint(painterSame), isFalse);
      expect(painterA.shouldRepaint(painterPhaseMoved), isTrue);
      expect(painterA.shouldRepaint(painterUnread), isTrue);
      expect(painterA.shouldRepaint(painterOpen), isTrue);

      for (final painter in <AuroraOrbPainter>[
        painterA,
        painterPhaseMoved,
        painterUnread,
        painterOpen,
      ]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        painter.paint(canvas, const Size(56, 56));
        final picture = recorder.endRecording();
        picture.dispose();
      }
    });
  });

  group('RAM message cache & single persistent SSE (anti-429)', () {
    testWidgets(
      'repeated open/close toggles call fetchLatestMessages once and subscribeToChannelMessages once with instant 0ms cached reopen',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[
              _msg(1, timestamp: DateTime.utc(2026, 11, 26, 12, 0)),
              _msg(2, timestamp: DateTime.utc(2026, 11, 26, 12, 1)),
            ];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
          ),
        );
        expect(repo.subscribeCalls, 1);
        expect(repo.fetchCalls, 0);
        expect(controller.hasLoadedMessages, isFalse);

        // 1st open -> single initial REST fetch, keeps persistent SSE.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(repo.fetchCalls, 1);
        expect(repo.subscribeCalls, 1);
        expect(repo.streamCancelCalls, 0);
        expect(controller.hasLoadedMessages, isTrue);
        expect(find.text('Message body 2'), findsOneWidget);

        // Close -> Reopen -> Close (panel close button) -> Reopen -> Close (dismiss) -> Reopen
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        expect(controller.isPanelOpen, isFalse);

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump(); // Single synchronous frame -> 0ms instant open!
        expect(controller.isPanelOpen, isTrue);
        expect(controller.previewState, OrbPreviewState.loaded);
        expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsNothing);
        expect(find.text('Message body 2'), findsOneWidget);
        expect(find.text('Message body 1'), findsOneWidget);

        await tester.tap(find.byKey(MessagePanel.closeButtonKey));
        await tester.pump();
        expect(controller.isPanelOpen, isFalse);

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        expect(controller.previewState, OrbPreviewState.loaded);
        expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsNothing);

        window.emitPanelDismissRequested();
        await tester.pump();
        expect(controller.isPanelOpen, isFalse);

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        expect(controller.previewState, OrbPreviewState.loaded);
        expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsNothing);

        // Still at most 1 GET /messages and 1 GET /stream across all toggles!
        expect(repo.fetchCalls, 1);
        expect(repo.subscribeCalls, 1);
        expect(repo.streamCancelCalls, 0);
        expect(repo.activeStreamCount, 1);
      },
    );

    testWidgets(
      'SSE create/update/delete while collapsed keeps RAM cache in sync for instant reopen',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        repo.onFetch = (_) async => <ChannelMessagePreview>[
              _msg(1, timestamp: DateTime.utc(2026, 11, 26, 12, 0)),
              _msg(2, timestamp: DateTime.utc(2026, 11, 26, 12, 1)),
            ];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
          ),
        );

        // Initial open loads cache, then close.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(repo.fetchCalls, 1);

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        expect(controller.isPanelOpen, isFalse);

        // While collapsed, live SSE delivers create, update, and delete.
        repo.emitEvent(
          ChannelMessageEvent.create(
            guildId: 'guild-1',
            channelId: 'channel-1',
            message: _msg(3, timestamp: DateTime.utc(2026, 11, 26, 12, 2)),
          ),
        );
        repo.emitEvent(
          const ChannelMessageEvent.update(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_2',
            content: 'Edited while collapsed',
          ),
        );
        repo.emitEvent(
          const ChannelMessageEvent.delete(
            guildId: 'guild-1',
            channelId: 'channel-1',
            messageId: 'msg_1',
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.unreadCount, 1);

        // Reopen -> 0 extra REST calls, immediately shows updated RAM cache!
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();

        expect(repo.fetchCalls, 1);
        expect(repo.subscribeCalls, 1);
        expect(controller.unreadCount, 0);
        expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsNothing);
        expect(controller.messages.map((m) => m.id), <String>['msg_3', 'msg_2']);
        expect(find.text('Message body 3'), findsOneWidget);
        expect(find.text('Edited while collapsed'), findsOneWidget);
        expect(find.text('Message body 1'), findsNothing);
      },
    );

    testWidgets(
      '429 retryAfter is honored in full on SSE reconnect and silent post-reconnect resync preserves warm cache on transient errors',
      (WidgetTester tester) async {
        final repo = _FakePreviewRepository();
        final window = _RecordingWindowController();
        final controller = OrbShellController();
        final controllers = <StreamController<ChannelMessageEvent>>[];

        repo.onSubscribe = ({
          required String guildId,
          required String channelId,
          required Object requestToken,
        }) {
          final ctrl = StreamController<ChannelMessageEvent>();
          controllers.add(ctrl);
          return ctrl.stream;
        };

        var fetchCount = 0;
        repo.onFetch = (_) async {
          fetchCount += 1;
          if (fetchCount == 1) {
            return <ChannelMessagePreview>[
              _msg(1, timestamp: DateTime.utc(2026, 11, 26, 12, 0)),
            ];
          }
          if (fetchCount == 2) {
            throw const OrbException(
              code: 'rate_limited',
              message: 'Too many requests',
              state: OrbPreviewState.rateLimited,
              statusCode: 429,
              retryAfter: Duration(seconds: 53),
            );
          }
          return <ChannelMessagePreview>[
            _msg(1, timestamp: DateTime.utc(2026, 11, 26, 12, 0)),
            _msg(2, timestamp: DateTime.utc(2026, 11, 26, 12, 1)),
          ];
        };

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: repo,
            windowController: window,
            controller: controller,
            streamReconnectBaseDelay: const Duration(seconds: 1),
            streamReconnectMaxDelay: const Duration(seconds: 30),
          ),
        );

        // Initial open warms cache.
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(repo.fetchCalls, 1);
        expect(repo.subscribeCalls, 1);
        expect(find.text('Message body 1'), findsOneWidget);

        // Simulate 429 on SSE stream with Retry-After: 53s (exceeds 30s maxDelay).
        controllers.first.addError(
          const OrbException(
            code: 'rate_limited',
            message: 'Too many requests',
            state: OrbPreviewState.rateLimited,
            statusCode: 429,
            retryAfter: Duration(seconds: 53),
          ),
        );
        await tester.pump();

        // Cached messages stay visible; reconnect must NOT fire at 30s or 52s!
        expect(controller.previewState, OrbPreviewState.loaded);
        expect(find.text('Message body 1'), findsOneWidget);
        await tester.pump(const Duration(seconds: 31));
        expect(repo.subscribeCalls, 1);
        await tester.pump(const Duration(seconds: 21));
        expect(repo.subscribeCalls, 1);

        // At 53s, SSE reconnects cleanly.
        await tester.pump(const Duration(seconds: 2));
        expect(repo.subscribeCalls, 2);

        // Reconnect ready triggers silent resync -> attempt 2 hits 429 -> warm cache stays visible (no error/loading flash)!
        controllers[1].add(
          const ChannelMessageEvent.ready(
            guildId: 'guild-1',
            channelId: 'channel-1',
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(repo.fetchCalls, 2);
        expect(controller.previewState, OrbPreviewState.loaded);
        expect(find.text('Message body 1'), findsOneWidget);
        expect(find.text('Rate limited'), findsNothing);

        // Close and reopen -> still shows cached message immediately (0ms) and silently resyncs successfully on attempt 3!
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();
        expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsNothing);
        expect(find.text('Message body 1'), findsOneWidget);

        await tester.pump();
        expect(repo.fetchCalls, 3);
        expect(find.text('Message body 2'), findsOneWidget);

        for (final c in controllers) {
          unawaited(c.close());
        }
      },
    );

    testWidgets(
      'hard security clears (lock/sleep, paused/hidden/detached, 401/403/503, channel switch) purge RAM cache and require fresh fetch',
      (WidgetTester tester) async {
        // 1. Lock/sleep & lifecycle paused/hidden/detached
        for (final trigger in <String>[
          'lock',
          'paused',
          'hidden',
          'detached',
        ]) {
          final repo = _FakePreviewRepository();
          final window = _RecordingWindowController();
          final controller = OrbShellController();
          repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(10)];

          await tester.pumpWidget(
            _wrapShell(
              shellKey: UniqueKey(),
              previewRepository: repo,
              windowController: window,
              controller: controller,
            ),
          );

          await tester.tap(find.byKey(OrbButton.orbButtonKey));
          await _pumpSettled(tester);
          expect(repo.fetchCalls, 1);
          expect(controller.hasLoadedMessages, isTrue);

          switch (trigger) {
            case 'lock':
              window.emitLockOrSleep();
            case 'paused':
              tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
            case 'hidden':
              tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
            case 'detached':
              tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
          }
          await tester.pump();

          expect(controller.hasLoadedMessages, isFalse, reason: trigger);
          expect(controller.cachedMessages, isEmpty, reason: trigger);
          expect(repo.activeStreamCount, 0, reason: trigger);

          if (trigger != 'lock') {
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await tester.pump();
          }

          // Reopening after security clear MUST perform a fresh fetch!
          await tester.tap(find.byKey(OrbButton.orbButtonKey));
          await _pumpSettled(tester);
          expect(repo.fetchCalls, 2, reason: trigger);
        }

        // 2. Terminal 401/403/503 SSE errors purge warm RAM cache
        for (final terminal in <(OrbPreviewState, int)>[
          (OrbPreviewState.sessionExpired, 401),
          (OrbPreviewState.accessDenied, 403),
          (OrbPreviewState.botUnavailable, 503),
        ]) {
          final repo = _FakePreviewRepository();
          final window = _RecordingWindowController();
          final controller = OrbShellController();
          late StreamController<ChannelMessageEvent> streamCtrl;
          repo.onSubscribe = ({
            required String guildId,
            required String channelId,
            required Object requestToken,
          }) {
            streamCtrl = StreamController<ChannelMessageEvent>();
            return streamCtrl.stream;
          };
          repo.onFetch = (_) async => <ChannelMessagePreview>[_msg(11)];

          await tester.pumpWidget(
            _wrapShell(
              shellKey: UniqueKey(),
              previewRepository: repo,
              windowController: window,
              controller: controller,
            ),
          );

          await tester.tap(find.byKey(OrbButton.orbButtonKey));
          await _pumpSettled(tester);
          expect(controller.hasLoadedMessages, isTrue);

          streamCtrl.addError(
            OrbException(
              code: 'err_${terminal.$2}',
              message: 'Blocked',
              state: terminal.$1,
              statusCode: terminal.$2,
            ),
          );
          await tester.pump();
          await tester.pump();

          expect(controller.hasLoadedMessages, isFalse);
          expect(controller.cachedMessages, isEmpty);
          expect(controller.messages, isEmpty);
          expect(controller.previewState, terminal.$1);
          unawaited(streamCtrl.close());
        }

        // 3. Channel switch purges RAM cache & fetches new channel cleanly
        final switchRepo = _FakePreviewRepository();
        final switchWindow = _RecordingWindowController();
        final switchController = OrbShellController();
        switchRepo.onFetch = (_) async => <ChannelMessagePreview>[_msg(21)];

        await tester.pumpWidget(
          _wrapShell(
            previewRepository: switchRepo,
            windowController: switchWindow,
            controller: switchController,
            channelId: 'channel-1',
          ),
        );

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(switchRepo.fetchCalls, 1);
        expect(switchController.hasLoadedMessages, isTrue);

        // Close panel, switch channel -> cache must be purged!
        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await tester.pump();

        switchRepo.onFetch = (_) async => <ChannelMessagePreview>[_msg(22)];
        await tester.pumpWidget(
          _wrapShell(
            previewRepository: switchRepo,
            windowController: switchWindow,
            controller: switchController,
            channelId: 'channel-2',
          ),
        );
        await tester.pump();
        expect(switchController.hasLoadedMessages, isFalse);
        expect(switchController.cachedMessages, isEmpty);

        await tester.tap(find.byKey(OrbButton.orbButtonKey));
        await _pumpSettled(tester);
        expect(switchRepo.fetchCalls, 2);
        expect(find.text('Message body 22'), findsOneWidget);
        expect(find.text('Message body 21'), findsNothing);
      },
    );
  });
}
