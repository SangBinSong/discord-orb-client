import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../contracts/orb_window_controller.dart';
import '../../contracts/preview_repository.dart';
import '../../models/message_models.dart';
import '../../models/orb_error.dart';
import '../panel/message_panel.dart';
import 'orb_button.dart';
import 'panel_positioner.dart';

/// Programmatic controller for hiding/restoring the orb or reading shell state.
class OrbShellController extends ChangeNotifier {
  OrbShellState? _state;

  bool get isPanelOpen => _state?.isPanelOpen ?? false;
  bool get isOrbHidden => _state?.isOrbHidden ?? false;
  OrbPanelExpandDirection get expandDirection =>
      _state?.expandDirection ?? OrbPanelExpandDirection.below;
  ChatListLayout get chatListLayout =>
      _state?.chatListLayout ?? ChatListLayout.standard;
  OrbPreviewState get previewState =>
      _state?.previewState ?? OrbPreviewState.idle;
  List<ChannelMessagePreview> get messages =>
      _state?.messages ?? const <ChannelMessagePreview>[];

  void hideOrb() => _state?.hideOrb();
  void restoreOrb() => _state?.restoreOrb();
  void closeAndClear() => _state?.closeAndClear();

  void _attach(OrbShellState state) {
    _state = state;
  }

  void _detach(OrbShellState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
}

/// Interactive floating Discord Orb shell managing two-tap panel toggling,
/// drag positioning, viewport clamping, and lock/sleep memory clearing.
class OrbShell extends StatefulWidget {
  const OrbShell({
    super.key,
    required this.previewRepository,
    required this.windowController,
    this.guildId,
    this.channelId,
    this.channelName,
    this.guildName,
    this.guildIconUrl,
    this.controller,
    this.orbSize = const Size(56, 56),
    this.panelSize = const Size(320, 400),
    this.initialOrbOffset,
    this.safePadding = EdgeInsets.zero,
    this.showRestoreChipWhenHidden = true,
    this.streamReconnectBaseDelay = const Duration(seconds: 1),
    this.streamReconnectMaxDelay = const Duration(seconds: 30),
    this.chatListLayout = ChatListLayout.standard,
    this.onChatListLayoutChanged,
    this.onExpandDirectionChanged,
    this.onReauthenticate,
    this.onReselectChannel,
  });

  static const Key restoreChipKey = Key('discord_orb_restore_chip');
  static const Key panelResizeHandleKey = Key('discord_orb_panel_resize_handle');

  /// Key for an individual edge/corner resize hit zone on the expanded panel card.
  static Key panelResizeEdgeKey(PanelResizeEdge edge) =>
      Key('discord_orb_panel_resize_${edge.wireName}');

  /// Key for the visible corner resize grip indicator on the expanded panel card.
  static Key panelResizeGripKey(PanelResizeEdge edge) =>
      Key('discord_orb_panel_resize_grip_${edge.wireName}');

  static const double minExpandedWidth = 260;
  static const double maxExpandedWidth = 720;
  static const double minExpandedHeight = 240;
  static const double maxExpandedHeight = 800;

  final PreviewRepository previewRepository;
  final OrbWindowController windowController;
  final String? guildId;
  final String? channelId;
  final String? channelName;
  final String? guildName;
  final String? guildIconUrl;
  final OrbShellController? controller;
  final Size orbSize;
  final Size panelSize;
  final Offset? initialOrbOffset;
  final EdgeInsets safePadding;
  final bool showRestoreChipWhenHidden;
  final Duration streamReconnectBaseDelay;
  final Duration streamReconnectMaxDelay;
  final ChatListLayout chatListLayout;
  final ValueChanged<ChatListLayout>? onChatListLayoutChanged;
  final ValueChanged<OrbPanelExpandDirection>? onExpandDirectionChanged;
  final VoidCallback? onReauthenticate;
  final VoidCallback? onReselectChannel;

  @override
  State<OrbShell> createState() => OrbShellState();
}

class OrbShellState extends State<OrbShell> with WidgetsBindingObserver {
  StreamSubscription<void>? _lockSubscription;
  StreamSubscription<void>? _dismissSubscription;
  StreamSubscription<ChannelMessageEvent>? _messageStreamSubscription;
  Timer? _streamReconnectTimer;
  int _streamReconnectAttempts = 0;

  Offset? _orbOffset;
  Size? _customPanelSize;
  bool _isOrbHidden = false;
  bool _isPanelOpen = false;
  OrbPanelExpandDirection _expandDirection = OrbPanelExpandDirection.below;
  late ChatListLayout _chatListLayout;
  OrbPreviewState _previewState = OrbPreviewState.idle;
  List<ChannelMessagePreview> _messages = const <ChannelMessagePreview>[];
  OrbException? _error;
  Object? _activeRequestToken;

  bool get isPanelOpen => _isPanelOpen;
  bool get isOrbHidden => _isOrbHidden;
  OrbPanelExpandDirection get expandDirection => _expandDirection;
  ChatListLayout get chatListLayout => _chatListLayout;
  OrbPreviewState get previewState => _previewState;
  List<ChannelMessagePreview> get messages =>
      List<ChannelMessagePreview>.unmodifiable(_messages);
  Offset? get orbOffset => _orbOffset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?._attach(this);
    _orbOffset = widget.initialOrbOffset;
    _chatListLayout = widget.chatListLayout;
    _subscribeToWindowEvents();
  }

  @override
  void didUpdateWidget(covariant OrbShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (!identical(oldWidget.windowController, widget.windowController)) {
      _unsubscribeFromWindowEvents();
      _subscribeToWindowEvents();
    }
    if (oldWidget.guildId != widget.guildId ||
        oldWidget.channelId != widget.channelId) {
      _cancelStreamSubscription();
      widget.previewRepository.clearMemory();
      widget.previewRepository.cancelActivePreview();
      if (_isPanelOpen) {
        final requestToken = Object();
        _activeRequestToken = requestToken;
        _previewState = OrbPreviewState.loading;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
        _fetchWithToken(requestToken);
      } else {
        _activeRequestToken = null;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
      }
    }
    if (oldWidget.chatListLayout != widget.chatListLayout) {
      _chatListLayout = widget.chatListLayout;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribeFromWindowEvents();
    _cancelStreamSubscription();
    widget.previewRepository.cancelActivePreview();
    widget.controller?._detach(this);
    _activeRequestToken = null;
    _messages = const <ChannelMessagePreview>[];
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      closeAndClear();
    }
  }

  void _subscribeToWindowEvents() {
    _lockSubscription =
        widget.windowController.onLockOrSleep.listen((_) => closeAndClear());
    _dismissSubscription = widget.windowController.onPanelDismissRequested
        .listen((_) => closeAndClear());
  }

  void _unsubscribeFromWindowEvents() {
    _lockSubscription?.cancel();
    _lockSubscription = null;
    _dismissSubscription?.cancel();
    _dismissSubscription = null;
  }

  EdgeInsets _effectiveSafePadding(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    return EdgeInsets.only(
      left: mediaPadding.left + widget.safePadding.left,
      top: mediaPadding.top + widget.safePadding.top,
      right: mediaPadding.right + widget.safePadding.right,
      bottom: mediaPadding.bottom + widget.safePadding.bottom,
    );
  }

  bool _isCollapsedOverlayViewport(Size viewportSize) {
    return viewportSize.width <= widget.orbSize.width + 40 &&
        viewportSize.height <= widget.orbSize.height + 40;
  }

  Size get _effectivePanelSize => _customPanelSize ?? widget.panelSize;

  Size _expandedWindowTargetSize() {
    final panel = _effectivePanelSize;
    return Size(
      (panel.width + 32)
          .clamp(OrbShell.minExpandedWidth, OrbShell.maxExpandedWidth),
      (panel.height + widget.orbSize.height + 120)
          .clamp(OrbShell.minExpandedHeight, OrbShell.maxExpandedHeight),
    );
  }

  bool _needsWindowExpansion(Size viewportSize, EdgeInsets safePadding) {
    final panel = _effectivePanelSize;
    final availableWidth =
        viewportSize.width - safePadding.left - safePadding.right;
    final availableHeight =
        viewportSize.height - safePadding.top - safePadding.bottom;
    return _isCollapsedOverlayViewport(viewportSize) ||
        availableWidth < panel.width ||
        availableHeight < panel.height;
  }

  bool _usesNativeDragForViewport(Size viewportSize) {
    return widget.windowController.usesNativeWindowDrag ||
        _isCollapsedOverlayViewport(viewportSize);
  }

  Offset _resolvedOrbOffset(Size viewportSize, EdgeInsets safePadding) {
    if (_isCollapsedOverlayViewport(viewportSize)) {
      return Offset(
        ((viewportSize.width - widget.orbSize.width) / 2)
            .clamp(0.0, double.infinity),
        ((viewportSize.height - widget.orbSize.height) / 2)
            .clamp(0.0, double.infinity),
      );
    }
    final anchorY = widget.windowController.usesNativeWindowDrag &&
            _isPanelOpen &&
            _expandDirection == OrbPanelExpandDirection.above
        ? viewportSize.height - safePadding.bottom - widget.orbSize.height - 16
        : safePadding.top + 16;
    final anchoredOffset = Offset(
      viewportSize.width - safePadding.right - widget.orbSize.width - 16,
      anchorY,
    );
    final raw = widget.windowController.usesNativeWindowDrag
        ? anchoredOffset
        : (_orbOffset ?? anchoredOffset);
    return clampOrbOffset(
      offset: raw,
      orbSize: widget.orbSize,
      viewportSize: viewportSize,
      safePadding: safePadding,
    );
  }

  PanelPlacement _resolvedPanelPlacement({
    required Offset orbOffset,
    required Size viewportSize,
    required EdgeInsets safePadding,
  }) {
    final orbRect = orbOffset & widget.orbSize;
    if (widget.windowController.usesNativeWindowDrag &&
        !_isCollapsedOverlayViewport(viewportSize)) {
      final minLeft = safePadding.left + 16;
      final maxRight =
          math.max(minLeft, viewportSize.width - safePadding.right - 16);
      final width = math.max(0.0, maxRight - minLeft);
      final controlsReserve = viewportSize.height >= 200 ? 72.0 : 16.0;

      if (_expandDirection == OrbPanelExpandDirection.above) {
        final top = safePadding.top + controlsReserve;
        final bottom = math.max(top, orbRect.top - 8.0);
        return PanelPlacement(
          rect: Rect.fromLTWH(minLeft, top, width, math.max(0.0, bottom - top)),
          direction: PanelPlacementDirection.above,
        );
      }

      final top = orbRect.bottom + 8.0;
      final bottom = math.max(
        top,
        viewportSize.height - safePadding.bottom - controlsReserve,
      );
      return PanelPlacement(
        rect: Rect.fromLTWH(minLeft, top, width, math.max(0.0, bottom - top)),
        direction: PanelPlacementDirection.below,
      );
    }

    return computePanelRect(
      orbRect: orbRect,
      panelSize: _effectivePanelSize,
      viewportSize: viewportSize,
      safePadding: safePadding,
    );
  }

  void _handleOrbTap(Size viewportSize, EdgeInsets safePadding) {
    if (_isOrbHidden) {
      return;
    }
    if (_isPanelOpen) {
      closeAndClear();
      return;
    }

    if (_needsWindowExpansion(viewportSize, safePadding)) {
      _openAndFetch(_expandedWindowTargetSize());
      return;
    }

    final currentOrbOffset = _resolvedOrbOffset(viewportSize, safePadding);
    final orbRect = currentOrbOffset & widget.orbSize;
    final placement = computePanelRect(
      orbRect: orbRect,
      panelSize: _effectivePanelSize,
      viewportSize: viewportSize,
      safePadding: safePadding,
    );

    _openAndFetch(placement.rect.size);
  }

  void _openAndFetch(Size targetPanelSize) {
    _cancelStreamSubscription();
    final requestToken = Object();
    setState(() {
      _isPanelOpen = true;
      _previewState = OrbPreviewState.loading;
      _messages = const <ChannelMessagePreview>[];
      _error = null;
      _activeRequestToken = requestToken;
    });

    unawaited(_expandWindowAndSyncDirection(targetPanelSize, requestToken));
    _fetchWithToken(requestToken);
  }

  Future<void> _expandWindowAndSyncDirection(
    Size targetPanelSize,
    Object requestToken,
  ) async {
    try {
      final direction =
          await widget.windowController.expandPanel(targetPanelSize);
      if (!mounted ||
          !_isPanelOpen ||
          !identical(_activeRequestToken, requestToken)) {
        return;
      }
      if (direction != _expandDirection) {
        setState(() {
          _expandDirection = direction;
        });
        widget.onExpandDirectionChanged?.call(direction);
      }
    } catch (_) {
      // Ignore host window channel failures in headless tests.
    }
  }

  void _handleLayoutChanged(ChatListLayout next) {
    if (next != _chatListLayout) {
      setState(() {
        _chatListLayout = next;
      });
    }
    widget.onChatListLayoutChanged?.call(next);
  }

  void _handleNonNativeResizeDelta(
    PanelResizeEdge edge,
    Offset delta,
    Size viewportSize,
  ) {
    final current = _effectivePanelSize;
    final maxWidth = math.min(
      OrbShell.maxExpandedWidth,
      math.max(OrbShell.minExpandedWidth, viewportSize.width),
    );
    final maxHeight = math.min(
      OrbShell.maxExpandedHeight,
      math.max(OrbShell.minExpandedHeight, viewportSize.height),
    );

    final double dw = switch (edge) {
      PanelResizeEdge.left ||
      PanelResizeEdge.topLeft ||
      PanelResizeEdge.bottomLeft =>
        -delta.dx,
      PanelResizeEdge.right ||
      PanelResizeEdge.topRight ||
      PanelResizeEdge.bottomRight =>
        delta.dx,
      PanelResizeEdge.top || PanelResizeEdge.bottom => 0.0,
    };
    final double dh = switch (edge) {
      PanelResizeEdge.top ||
      PanelResizeEdge.topLeft ||
      PanelResizeEdge.topRight =>
        -delta.dy,
      PanelResizeEdge.bottom ||
      PanelResizeEdge.bottomLeft ||
      PanelResizeEdge.bottomRight =>
        delta.dy,
      PanelResizeEdge.left || PanelResizeEdge.right => 0.0,
    };

    final nextWidth =
        (current.width + dw).clamp(OrbShell.minExpandedWidth, maxWidth);
    final nextHeight =
        (current.height + dh).clamp(OrbShell.minExpandedHeight, maxHeight);
    setState(() {
      _customPanelSize = Size(nextWidth.toDouble(), nextHeight.toDouble());
    });
  }

  void _handlePanelEdgePointerDown(
    PanelResizeEdge edge,
    PointerDownEvent event,
  ) {
    if (!widget.windowController.usesNativeWindowDrag) {
      return;
    }
    if ((event.buttons & kPrimaryButton) == 0) {
      return;
    }
    unawaited(widget.windowController.startPanelResize(edge));
  }

  MouseCursor _cursorForEdge(PanelResizeEdge edge) {
    return switch (edge) {
      PanelResizeEdge.left => SystemMouseCursors.resizeLeft,
      PanelResizeEdge.right => SystemMouseCursors.resizeRight,
      PanelResizeEdge.top => SystemMouseCursors.resizeUp,
      PanelResizeEdge.bottom => SystemMouseCursors.resizeDown,
      PanelResizeEdge.topLeft ||
      PanelResizeEdge.bottomRight =>
        SystemMouseCursors.resizeUpLeftDownRight,
      PanelResizeEdge.topRight ||
      PanelResizeEdge.bottomLeft =>
        SystemMouseCursors.resizeUpRightDownLeft,
    };
  }

  Widget _buildResizeZone({
    required PanelResizeEdge edge,
    required Size viewportSize,
    Key? zoneKey,
    Widget? child,
  }) {
    final usesNative = widget.windowController.usesNativeWindowDrag;
    final Widget interactive = usesNative
        ? Listener(
            key: zoneKey ?? OrbShell.panelResizeEdgeKey(edge),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (PointerDownEvent event) =>
                _handlePanelEdgePointerDown(edge, event),
            child: child ?? const SizedBox.expand(),
          )
        : GestureDetector(
            key: zoneKey ?? OrbShell.panelResizeEdgeKey(edge),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (DragUpdateDetails details) =>
                _handleNonNativeResizeDelta(edge, details.delta, viewportSize),
            child: child ?? const SizedBox.expand(),
          );
    return MouseRegion(
      cursor: _cursorForEdge(edge),
      child: interactive,
    );
  }

  List<Widget> _buildPanelResizeOverlays({
    required BuildContext context,
    required Size viewportSize,
    required PanelPlacementDirection direction,
  }) {
    const double edgeThickness = 7;
    const double cornerInset = 18;
    const double gripSize = 20;
    final gripColor = Theme.of(context)
        .colorScheme
        .onSurfaceVariant
        .withValues(alpha: 0.6);
    final isAbove = direction == PanelPlacementDirection.above;
    final usesNative = widget.windowController.usesNativeWindowDrag;

    Widget cornerGrip(PanelResizeEdge edge) {
      return Semantics(
        label: 'Resize chat panel',
        child: SizedBox(
          key: OrbShell.panelResizeGripKey(edge),
          width: gripSize,
          height: gripSize,
          child: CustomPaint(
            painter: _ResizeGripPainter(
              edge: edge,
              color: gripColor,
            ),
          ),
        ),
      );
    }

    return <Widget>[
      // Left edge
      Positioned(
        left: 0,
        top: cornerInset,
        bottom: cornerInset,
        width: edgeThickness,
        child: _buildResizeZone(
          edge: PanelResizeEdge.left,
          viewportSize: viewportSize,
        ),
      ),
      // Right edge
      Positioned(
        right: 0,
        top: cornerInset,
        bottom: cornerInset,
        width: edgeThickness,
        child: _buildResizeZone(
          edge: PanelResizeEdge.right,
          viewportSize: viewportSize,
        ),
      ),
      // Top edge (slim 6px so header buttons stay fully clickable)
      Positioned(
        left: cornerInset,
        right: cornerInset,
        top: 0,
        height: 6,
        child: _buildResizeZone(
          edge: PanelResizeEdge.top,
          viewportSize: viewportSize,
        ),
      ),
      // Bottom edge
      Positioned(
        left: cornerInset,
        right: cornerInset,
        bottom: 0,
        height: edgeThickness,
        child: _buildResizeZone(
          edge: PanelResizeEdge.bottom,
          viewportSize: viewportSize,
        ),
      ),
      // Top-left corner (shows visible grip when expanded above)
      Positioned(
        left: 0,
        top: 0,
        width: isAbove ? gripSize : 14,
        height: isAbove ? gripSize : 14,
        child: _buildResizeZone(
          edge: PanelResizeEdge.topLeft,
          viewportSize: viewportSize,
          child: isAbove ? cornerGrip(PanelResizeEdge.topLeft) : null,
        ),
      ),
      // Top-right corner (compact 10x10 so it never covers the header close button)
      Positioned(
        right: 0,
        top: 0,
        width: 10,
        height: 10,
        child: _buildResizeZone(
          edge: PanelResizeEdge.topRight,
          viewportSize: viewportSize,
        ),
      ),
      // Bottom-left corner (shows visible grip when expanded below)
      Positioned(
        left: 0,
        bottom: 0,
        width: !isAbove ? gripSize : 16,
        height: !isAbove ? gripSize : 16,
        child: _buildResizeZone(
          edge: PanelResizeEdge.bottomLeft,
          viewportSize: viewportSize,
          child: !isAbove ? cornerGrip(PanelResizeEdge.bottomLeft) : null,
        ),
      ),
      // Bottom-right corner (primary visible grip when expanded below, and
      // keeps panelResizeHandleKey for non-native fallback tests)
      Positioned(
        right: 0,
        bottom: 0,
        width: gripSize,
        height: gripSize,
        child: _buildResizeZone(
          edge: PanelResizeEdge.bottomRight,
          viewportSize: viewportSize,
          zoneKey: usesNative
              ? OrbShell.panelResizeEdgeKey(PanelResizeEdge.bottomRight)
              : OrbShell.panelResizeHandleKey,
          child: !isAbove ? cornerGrip(PanelResizeEdge.bottomRight) : null,
        ),
      ),
    ];
  }

  void _retryFetch() {
    if (!_isPanelOpen) {
      return;
    }
    _cancelStreamSubscription();
    final requestToken = Object();
    setState(() {
      _previewState = OrbPreviewState.loading;
      _messages = const <ChannelMessagePreview>[];
      _error = null;
      _activeRequestToken = requestToken;
    });
    _fetchWithToken(requestToken);
  }

  Future<void> _fetchWithToken(Object requestToken) async {
    final guildId = widget.guildId;
    final channelId = widget.channelId;
    if (guildId == null ||
        guildId.isEmpty ||
        channelId == null ||
        channelId.isEmpty) {
      if (!mounted ||
          !_isPanelOpen ||
          !identical(_activeRequestToken, requestToken)) {
        return;
      }
      setState(() {
        _previewState = OrbPreviewState.accessDenied;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
      });
      return;
    }

    try {
      final fetched = await widget.previewRepository.fetchLatestMessages(
        guildId: guildId,
        channelId: channelId,
        requestToken: requestToken,
      );
      if (!mounted ||
          !_isPanelOpen ||
          !identical(_activeRequestToken, requestToken)) {
        return;
      }
      final newest = MessagePanel.selectNewestMessages(fetched);
      setState(() {
        if (newest.isEmpty) {
          _previewState = OrbPreviewState.emptyChannel;
          _messages = const <ChannelMessagePreview>[];
        } else {
          _previewState = OrbPreviewState.loaded;
          _messages = newest;
        }
        _error = null;
      });
      _startMessageStream(
        guildId: guildId,
        channelId: channelId,
        requestToken: requestToken,
      );
    } on OrbException catch (e) {
      if (!mounted ||
          !_isPanelOpen ||
          !identical(_activeRequestToken, requestToken)) {
        return;
      }
      setState(() {
        _previewState = e.state;
        _messages = const <ChannelMessagePreview>[];
        _error = e;
      });
    } catch (_) {
      if (!mounted ||
          !_isPanelOpen ||
          !identical(_activeRequestToken, requestToken)) {
        return;
      }
      setState(() {
        _previewState = OrbPreviewState.networkError;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
      });
    }
  }

  void _startMessageStream({
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) {
    if (!mounted ||
        !_isPanelOpen ||
        !identical(_activeRequestToken, requestToken)) {
      return;
    }
    _streamReconnectTimer?.cancel();
    _streamReconnectTimer = null;
    final previous = _messageStreamSubscription;
    _messageStreamSubscription = null;
    if (previous != null) {
      unawaited(previous.cancel());
    }

    final stream = widget.previewRepository.subscribeToChannelMessages(
      guildId: guildId,
      channelId: channelId,
      requestToken: requestToken,
    );

    _messageStreamSubscription = stream.listen(
      (ChannelMessageEvent event) => _handleStreamEvent(event, requestToken),
      onError: (Object error, StackTrace _) => _handleStreamError(
        error,
        guildId: guildId,
        channelId: channelId,
        requestToken: requestToken,
      ),
      onDone: () {
        if (!mounted ||
            !_isPanelOpen ||
            !identical(_activeRequestToken, requestToken)) {
          return;
        }
        _messageStreamSubscription = null;
        _scheduleStreamReconnect(
          guildId: guildId,
          channelId: channelId,
          requestToken: requestToken,
        );
      },
      cancelOnError: true,
    );
  }

  void _handleStreamEvent(ChannelMessageEvent event, Object requestToken) {
    if (!mounted ||
        !_isPanelOpen ||
        !identical(_activeRequestToken, requestToken)) {
      return;
    }
    _streamReconnectAttempts = 0;
    if (event.type == ChannelMessageEventType.ready) {
      return;
    }
    final merged = mergeChannelMessageEvent(
      _messages,
      event,
      maxMessages: MessagePanel.maxVisibleMessages,
    );
    setState(() {
      _messages = merged;
      _previewState = merged.isEmpty
          ? OrbPreviewState.emptyChannel
          : OrbPreviewState.loaded;
      _error = null;
    });
  }

  void _handleStreamError(
    Object error, {
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) {
    if (!mounted ||
        !_isPanelOpen ||
        !identical(_activeRequestToken, requestToken)) {
      return;
    }
    _messageStreamSubscription = null;

    if (error is OrbException) {
      if (error.code == 'preview_cancelled') {
        return;
      }
      if (error.state == OrbPreviewState.sessionExpired ||
          error.state == OrbPreviewState.accessDenied ||
          error.state == OrbPreviewState.botUnavailable) {
        _cancelStreamSubscription();
        widget.previewRepository.clearMemory();
        setState(() {
          _previewState = error.state;
          _messages = const <ChannelMessagePreview>[];
          _error = error;
        });
        return;
      }
      _scheduleStreamReconnect(
        guildId: guildId,
        channelId: channelId,
        requestToken: requestToken,
        minDelay: error.retryAfter,
      );
      return;
    }

    _scheduleStreamReconnect(
      guildId: guildId,
      channelId: channelId,
      requestToken: requestToken,
    );
  }

  void _scheduleStreamReconnect({
    required String guildId,
    required String channelId,
    required Object requestToken,
    Duration? minDelay,
  }) {
    if (!mounted ||
        !_isPanelOpen ||
        !identical(_activeRequestToken, requestToken) ||
        _streamReconnectTimer != null) {
      return;
    }
    final attempt = _streamReconnectAttempts.clamp(0, 10);
    _streamReconnectAttempts += 1;
    final multiplier = 1 << attempt;
    final rawMs = widget.streamReconnectBaseDelay.inMilliseconds * multiplier;
    final maxMs = widget.streamReconnectMaxDelay.inMilliseconds;
    var delayMs = rawMs > maxMs ? maxMs : rawMs;
    if (minDelay != null && minDelay.inMilliseconds > delayMs) {
      delayMs = minDelay.inMilliseconds > maxMs ? maxMs : minDelay.inMilliseconds;
    }
    _streamReconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _streamReconnectTimer = null;
      if (!mounted ||
          !_isPanelOpen ||
          !identical(_activeRequestToken, requestToken)) {
        return;
      }
      _startMessageStream(
        guildId: guildId,
        channelId: channelId,
        requestToken: requestToken,
      );
    });
  }

  void _cancelStreamSubscription() {
    _streamReconnectTimer?.cancel();
    _streamReconnectTimer = null;
    _streamReconnectAttempts = 0;
    final sub = _messageStreamSubscription;
    _messageStreamSubscription = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  /// Closes the panel if open, invalidates any in-flight request, and wipes
  /// all in-memory preview messages.
  void closeAndClear() {
    final wasOpen = _isPanelOpen;
    _activeRequestToken = null;
    _cancelStreamSubscription();
    widget.previewRepository.clearMemory();
    widget.previewRepository.cancelActivePreview();
    if (wasOpen) {
      unawaited(widget.windowController.collapsePanel());
    }
    if (!mounted) {
      _isPanelOpen = false;
      _expandDirection = OrbPanelExpandDirection.below;
      _previewState = OrbPreviewState.idle;
      _messages = const <ChannelMessagePreview>[];
      _error = null;
      return;
    }
    if (wasOpen ||
        _expandDirection != OrbPanelExpandDirection.below ||
        _messages.isNotEmpty ||
        _previewState != OrbPreviewState.idle ||
        _error != null) {
      final directionChanged = _expandDirection != OrbPanelExpandDirection.below;
      setState(() {
        _isPanelOpen = false;
        _expandDirection = OrbPanelExpandDirection.below;
        _previewState = OrbPreviewState.idle;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
      });
      if (directionChanged) {
        widget.onExpandDirectionChanged?.call(OrbPanelExpandDirection.below);
      }
    }
  }

  /// Hides the floating orb and clears any open panel/messages.
  void hideOrb() {
    closeAndClear();
    unawaited(widget.windowController.hideOrb());
    if (!mounted) {
      _isOrbHidden = true;
      return;
    }
    if (!_isOrbHidden) {
      setState(() {
        _isOrbHidden = true;
      });
    }
  }

  /// Restores a previously hidden floating orb.
  void restoreOrb() {
    unawaited(widget.windowController.showCollapsedOrb());
    if (!mounted) {
      _isOrbHidden = false;
      return;
    }
    if (_isOrbHidden) {
      setState(() {
        _isOrbHidden = false;
      });
    }
  }

  void _handleDragStart(Size viewportSize) {
    if (_usesNativeDragForViewport(viewportSize)) {
      unawaited(widget.windowController.startOrbDrag());
    }
  }

  void _handleDragDelta(
    Offset delta,
    Size viewportSize,
    EdgeInsets safePadding,
  ) {
    if (_usesNativeDragForViewport(viewportSize)) {
      // Desktop native overlay windows use OS-level dragging started on pan start.
      return;
    }
    final current = _resolvedOrbOffset(viewportSize, safePadding);
    final next = clampOrbOffset(
      offset: current + delta,
      orbSize: widget.orbSize,
      viewportSize: viewportSize,
      safePadding: safePadding,
    );
    setState(() {
      _orbOffset = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final safePadding = _effectiveSafePadding(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);

        if (_isOrbHidden) {
          if (!widget.showRestoreChipWhenHidden) {
            return const SizedBox.shrink();
          }
          return Stack(
            children: <Widget>[
              Positioned(
                top: safePadding.top + 12,
                right: safePadding.right + 12,
                child: ActionChip(
                  key: OrbShell.restoreChipKey,
                  avatar: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('Show Orb'),
                  onPressed: restoreOrb,
                ),
              ),
            ],
          );
        }

        final orbOffset = _resolvedOrbOffset(viewportSize, safePadding);
        final placement = _resolvedPanelPlacement(
          orbOffset: orbOffset,
          viewportSize: viewportSize,
          safePadding: safePadding,
        );
        final canRenderPanel =
            placement.rect.width >= 180 && placement.rect.height >= 80;
        final showResizeOverlays = !_isCollapsedOverlayViewport(viewportSize);

        return Stack(
          children: <Widget>[
            if (_isPanelOpen && canRenderPanel)
              Positioned.fromRect(
                rect: placement.rect,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: MessagePanel(
                        state: _previewState,
                        messages: _messages,
                        channelName: widget.channelName,
                        guildName: widget.guildName,
                        guildIconUrl: widget.guildIconUrl,
                        layout: _chatListLayout,
                        onLayoutChanged: _handleLayoutChanged,
                        error: _error,
                        onClose: closeAndClear,
                        onRetry: _retryFetch,
                        onReauthenticate: widget.onReauthenticate,
                        onReselectChannel: widget.onReselectChannel,
                      ),
                    ),
                    if (showResizeOverlays)
                      ..._buildPanelResizeOverlays(
                        context: context,
                        viewportSize: viewportSize,
                        direction: placement.direction,
                      ),
                  ],
                ),
              ),
            Positioned(
              left: orbOffset.dx,
              top: orbOffset.dy,
              child: OrbButton(
                isPanelOpen: _isPanelOpen,
                size: widget.orbSize,
                showTooltip: !widget.windowController.usesNativeWindowDrag,
                onTap: () => _handleOrbTap(viewportSize, safePadding),
                onDragStart: () => _handleDragStart(viewportSize),
                onDragDelta: (Offset delta) =>
                    _handleDragDelta(delta, viewportSize, safePadding),
                onHideRequested: hideOrb,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter({
    required this.edge,
    required this.color,
  });

  final PanelResizeEdge edge;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    const offsets = <double>[5.0, 9.0, 13.0];
    switch (edge) {
      case PanelResizeEdge.bottomRight:
        for (final d in offsets) {
          canvas.drawLine(
            Offset(size.width - d, size.height - 3),
            Offset(size.width - 3, size.height - d),
            paint,
          );
        }
      case PanelResizeEdge.bottomLeft:
        for (final d in offsets) {
          canvas.drawLine(
            Offset(3, size.height - d),
            Offset(d, size.height - 3),
            paint,
          );
        }
      case PanelResizeEdge.topLeft:
        for (final d in offsets) {
          canvas.drawLine(
            Offset(3, d),
            Offset(d, 3),
            paint,
          );
        }
      case PanelResizeEdge.topRight:
        for (final d in offsets) {
          canvas.drawLine(
            Offset(size.width - d, 3),
            Offset(size.width - 3, d),
            paint,
          );
        }
      case PanelResizeEdge.left:
      case PanelResizeEdge.right:
      case PanelResizeEdge.top:
      case PanelResizeEdge.bottom:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeGripPainter oldDelegate) {
    return oldDelegate.edge != edge || oldDelegate.color != color;
  }
}
