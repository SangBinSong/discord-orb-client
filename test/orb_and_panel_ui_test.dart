import 'dart:async';

import 'package:discord_orb/contracts/orb_window_controller.dart';
import 'package:discord_orb/contracts/preview_repository.dart';
import 'package:discord_orb/models/channel_models.dart';
import 'package:discord_orb/models/message_models.dart';
import 'package:discord_orb/models/orb_error.dart';
import 'package:discord_orb/ui/orb/orb_button.dart';
import 'package:discord_orb/ui/orb/orb_shell.dart';
import 'package:discord_orb/ui/orb/panel_positioner.dart';
import 'package:discord_orb/ui/panel/message_panel.dart';
import 'package:discord_orb/ui/panel/message_tile.dart';
import 'package:discord_orb/ui/panel/panel_status_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingWindowController extends NoopOrbWindowController {
  int expandCount = 0;
  Size? lastExpandSize;
  int collapseCount = 0;
  int hideOrbCount = 0;
  int showCollapsedOrbCount = 0;
  final List<Offset> moveOrbDeltas = <Offset>[];
  int showMainWindowCount = 0;

  @override
  Future<void> expandPanel(Size size) async {
    expandCount += 1;
    lastExpandSize = size;
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
  int fetchCalls = 0;
  int cancelCalls = 0;
  int clearMemoryCalls = 0;

  Future<List<ChannelMessagePreview>> Function(Object requestToken)? onFetch;

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
  required PreviewRepository previewRepository,
  required OrbWindowController windowController,
  OrbShellController? controller,
  Size viewportSize = const Size(420, 800),
  Offset? initialOrbOffset,
  String? guildId = 'guild-1',
  String? channelId = 'channel-1',
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
            previewRepository: previewRepository,
            windowController: windowController,
            controller: controller,
            guildId: guildId,
            channelId: channelId,
            channelName: 'general',
            guildName: 'Orb Guild',
            initialOrbOffset: initialOrbOffset,
            onReauthenticate: onReauthenticate,
            onReselectChannel: onReselectChannel,
          ),
        ),
      ),
    ),
  );
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

      // 2nd tap before response arrives: closes & clears immediately.
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();

      expect(controller.isPanelOpen, isFalse);
      expect(controller.previewState, OrbPreviewState.idle);
      expect(controller.messages, isEmpty);
      expect(repo.clearMemoryCalls, 1);
      expect(repo.cancelCalls, 1);
      expect(window.collapseCount, 1);

      // Late response arrives after close: must be completely ignored.
      completer.complete(<ChannelMessagePreview>[_msg(1)]);
      await tester.pump();

      expect(controller.isPanelOpen, isFalse);
      expect(controller.previewState, OrbPreviewState.idle);
      expect(controller.messages, isEmpty);
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
      await tester.pumpAndSettle();

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
      'collapsed 80x80 desktop viewport centers orb, delegates drag to moveOrbBy, and requests full expanded size on tap without overflow',
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

        // Dragging in collapsed 80x80 viewport delegates to native window moveOrbBy.
        await tester.drag(
          find.byKey(OrbButton.orbButtonKey),
          const Offset(24, -16),
        );
        await tester.pump();
        expect(window.moveOrbDeltas, isNotEmpty);
        final totalDelta = window.moveOrbDeltas.fold<Offset>(
          Offset.zero,
          (Offset acc, Offset delta) => acc + delta,
        );
        expect(totalDelta.dx, greaterThan(0));
        expect(totalDelta.dy, lessThan(0));
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
        await tester.pumpAndSettle();

        expect(find.byType(MessagePanel), findsOneWidget);
        expect(find.text('Message body 1'), findsOneWidget);
        final expandedOrbRect =
            tester.getRect(find.byKey(OrbButton.orbButtonKey));
        final panelRect = tester.getRect(find.byType(MessagePanel));
        expect(expandedOrbRect.overlaps(panelRect), isFalse);
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
        await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      expect(controller.isPanelOpen, isTrue);

      window.emitLockOrSleep();
      await tester.pump();
      expect(controller.isPanelOpen, isFalse);
      expect(controller.messages, isEmpty);
      expect(repo.clearMemoryCalls, 1);
      expect(window.collapseCount, 1);

      // Re-open and test external dismiss stream.
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pumpAndSettle();
      expect(controller.isPanelOpen, isTrue);

      window.emitPanelDismissRequested();
      await tester.pump();
      expect(controller.isPanelOpen, isFalse);
      expect(controller.messages, isEmpty);
      expect(repo.clearMemoryCalls, 2);
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
      await tester.pumpAndSettle();
      expect(controller.previewState, OrbPreviewState.emptyChannel);
      expect(find.text('Channel is empty'), findsOneWidget);

      // Close
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pump();

      // 2. sessionExpired
      repo.onFetch = (_) async => throw const OrbException(
            code: 'session_expired',
            message: 'Session expired',
            state: OrbPreviewState.sessionExpired,
          );
      await tester.tap(find.byKey(OrbButton.orbButtonKey));
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      expect(find.text('Rate limited'), findsOneWidget);
      expect(find.textContaining('5s'), findsOneWidget);

      await tester.tap(find.byKey(PanelStatusView.retryButtonKey));
      await tester.pump();
      expect(controller.previewState, OrbPreviewState.loading);
      expect(find.byKey(PanelStatusView.loadingIndicatorKey), findsOneWidget);
      expect(find.byType(MessageTile), findsNothing);

      retryCompleter.complete(<ChannelMessagePreview>[_msg(7)]);
      await tester.pumpAndSettle();
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
}
