import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../contracts/orb_window_controller.dart';
import '../../contracts/preview_repository.dart';
import '../../core/device_identity_store.dart';
import '../../models/message_models.dart';
import '../../models/orb_error.dart';
import '../panel/message_panel.dart';
import 'orb_button.dart';
import 'orb_message_toast.dart';
import 'panel_positioner.dart';

class _ToastEntry {
  _ToastEntry({
    required this.message,
    required this.timer,
  });

  ChannelMessagePreview message;
  Timer timer;
}

/// Programmatic controller for hiding/restoring the orb or reading shell state.
class OrbShellController extends ChangeNotifier {
  OrbShellState? _state;

  bool get isPanelOpen => _state?.isPanelOpen ?? false;
  bool get isPanelPinned => _state?.isPanelPinned ?? false;
  bool get isToastNotificationsEnabled =>
      _state?.toastNotificationsEnabled ?? false;
  bool get isToastVisible => _state?.isToastVisible ?? false;
  int get unreadCount => _state?.unreadCount ?? 0;
  ChannelMessagePreview? get toastMessage => _state?.toastMessage;
  List<ChannelMessagePreview> get toastMessages =>
      _state?.toastMessages ?? const <ChannelMessagePreview>[];
  int get maxVisibleToastCount =>
      _state?.maxVisibleToastCount ??
      DeviceIdentityStore.defaultMaxVisibleToastCount;
  ChatListLayout get toastLayout =>
      _state?.toastLayout ?? ChatListLayout.standard;
  OrbPanelExpandDirection get toastDirection =>
      _state?.toastDirection ?? OrbPanelExpandDirection.below;
  bool get isOrbHidden => _state?.isOrbHidden ?? false;
  OrbPanelExpandDirection get expandDirection =>
      _state?.expandDirection ?? OrbPanelExpandDirection.below;
  ChatListLayout get chatListLayout =>
      _state?.chatListLayout ?? ChatListLayout.standard;
  OrbPreviewState get previewState =>
      _state?.previewState ?? OrbPreviewState.idle;
  List<ChannelMessagePreview> get messages =>
      _state?.messages ?? const <ChannelMessagePreview>[];
  bool get hasLoadedMessages => _state?.hasLoadedMessages ?? false;
  List<ChannelMessagePreview> get cachedMessages =>
      _state?.cachedMessages ?? const <ChannelMessagePreview>[];

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
    this.panelPinned,
    this.onPanelPinnedChanged,
    this.toastNotificationsEnabled = false,
    this.onToastNotificationsChanged,
    this.maxVisibleToastCount = DeviceIdentityStore.defaultMaxVisibleToastCount,
    this.onMaxVisibleToastCountChanged,
    this.toastLayout = ChatListLayout.standard,
    this.onToastLayoutChanged,
    this.toastDuration = const Duration(seconds: 5),
    this.onExpandDirectionChanged,
    this.onReauthenticate,
    this.onReselectChannel,
  });

  static const Key restoreChipKey = Key('discord_orb_restore_chip');
  static const Key panelResizeHandleKey = Key('discord_orb_panel_resize_handle');
  static const Size toastWindowSize = Size(300, 168);
  static const Size toastCardSize = Size(276, 80);
  static const int maxBufferedToasts = 10;

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
  final bool? panelPinned;
  final ValueChanged<bool>? onPanelPinnedChanged;
  final bool toastNotificationsEnabled;
  final ValueChanged<bool>? onToastNotificationsChanged;
  final int maxVisibleToastCount;
  final ValueChanged<int>? onMaxVisibleToastCountChanged;
  final ChatListLayout toastLayout;
  final ValueChanged<ChatListLayout>? onToastLayoutChanged;
  final Duration toastDuration;
  final ValueChanged<OrbPanelExpandDirection>? onExpandDirectionChanged;
  final VoidCallback? onReauthenticate;
  final VoidCallback? onReselectChannel;

  @override
  State<OrbShell> createState() => OrbShellState();
}

class OrbShellState extends State<OrbShell> with WidgetsBindingObserver {
  StreamSubscription<void>? _lockSubscription;
  StreamSubscription<void>? _dismissSubscription;
  StreamSubscription<void>? _toastTappedSubscription;
  StreamSubscription<String>? _toastDismissedSubscription;
  StreamSubscription<bool>? _toastEnabledToggledSubscription;
  StreamSubscription<ChatListLayout>? _toastLayoutToggledSubscription;
  StreamSubscription<ChannelMessageEvent>? _messageStreamSubscription;
  Timer? _streamReconnectTimer;
  int _streamReconnectAttempts = 0;
  Object? _streamSessionToken;
  String? _streamChannelKey;

  final List<_ToastEntry> _toastEntries = <_ToastEntry>[];
  final Set<String> _unreadMessageIds = <String>{};
  OrbPanelExpandDirection _toastDirection = OrbPanelExpandDirection.below;
  Object? _toastOverlayToken;
  bool _isToastOverlayActive = false;
  bool _isCollapsingToastOverlay = false;
  Size? _lastToastOverlaySize;
  Size _lastViewportSize = const Size(80, 80);
  EdgeInsets _lastSafePadding = EdgeInsets.zero;

  Offset? _orbOffset;
  Size? _customPanelSize;
  bool _isOrbHidden = false;
  bool _isPanelOpen = false;
  bool _isHardSuspended = false;
  bool _backgroundStreamHaltedByTerminalError = false;
  late bool _isPanelPinned;
  late bool _toastNotificationsEnabled;
  late ChatListLayout _toastLayout;
  OrbPanelExpandDirection _expandDirection = OrbPanelExpandDirection.below;
  late ChatListLayout _chatListLayout;
  OrbPreviewState _previewState = OrbPreviewState.idle;
  List<ChannelMessagePreview> _messages = const <ChannelMessagePreview>[];
  List<ChannelMessagePreview> _cachedMessages = const <ChannelMessagePreview>[];
  bool _hasLoadedMessages = false;
  String? _loadedChannelKey;
  bool _needsSilentResyncAfterReconnect = false;
  OrbException? _error;
  Object? _activeRequestToken;

  bool get isPanelOpen => _isPanelOpen;
  bool get isPanelPinned => _isPanelPinned;
  bool get toastNotificationsEnabled => _toastNotificationsEnabled;
  ChatListLayout get toastLayout => _toastLayout;
  bool get isToastVisible => _toastEntries.isNotEmpty;
  int get unreadCount => _unreadMessageIds.length;
  ChannelMessagePreview? get toastMessage =>
      _toastEntries.isEmpty ? null : _toastEntries.first.message;
  List<ChannelMessagePreview> get toastMessages => List<ChannelMessagePreview>.unmodifiable(
        _toastEntries.map((_ToastEntry e) => e.message),
      );
  int get maxVisibleToastCount =>
      DeviceIdentityStore.clampMaxVisibleToastCount(widget.maxVisibleToastCount);
  OrbPanelExpandDirection get toastDirection => _toastDirection;
  bool get isOrbHidden => _isOrbHidden;
  OrbPanelExpandDirection get expandDirection => _expandDirection;
  ChatListLayout get chatListLayout => _chatListLayout;
  OrbPreviewState get previewState => _previewState;
  List<ChannelMessagePreview> get messages =>
      List<ChannelMessagePreview>.unmodifiable(_messages);
  bool get hasLoadedMessages => _hasLoadedMessages;
  List<ChannelMessagePreview> get cachedMessages =>
      List<ChannelMessagePreview>.unmodifiable(_cachedMessages);
  Offset? get orbOffset => _orbOffset;

  bool get _hasValidChannel =>
      widget.guildId != null &&
      widget.guildId!.isNotEmpty &&
      widget.channelId != null &&
      widget.channelId!.isNotEmpty;

  String? get _currentChannelKey =>
      _hasValidChannel ? '${widget.guildId}:${widget.channelId}' : null;

  bool get _hasValidCacheForCurrentChannel =>
      _hasLoadedMessages &&
      _loadedChannelKey != null &&
      _loadedChannelKey == _currentChannelKey;

  bool get _hasActiveStreamForCurrentChannel =>
      _messageStreamSubscription != null &&
      _streamChannelKey != null &&
      _streamChannelKey == _currentChannelKey;

  bool get _canRunBackgroundStream =>
      !_isPanelOpen &&
      !_isOrbHidden &&
      !_isHardSuspended &&
      !_backgroundStreamHaltedByTerminalError &&
      _hasValidChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?._attach(this);
    _orbOffset = widget.initialOrbOffset;
    _chatListLayout = widget.chatListLayout;
    _isPanelPinned =
        widget.panelPinned ?? widget.windowController.usesNativeWindowDrag;
    _toastNotificationsEnabled = widget.toastNotificationsEnabled;
    _toastLayout = widget.toastLayout;
    _subscribeToWindowEvents();
    _syncPanelPinnedToWindow();
    _syncToastNotificationsEnabledToWindow();
    _syncToastLayoutToWindow();
    _ensureBackgroundStreamIfEligible();
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
      _syncPanelPinnedToWindow();
      _syncToastNotificationsEnabledToWindow();
      _syncToastLayoutToWindow();
    }
    if (oldWidget.panelPinned != widget.panelPinned) {
      final nextPinned =
          widget.panelPinned ?? widget.windowController.usesNativeWindowDrag;
      if (nextPinned != _isPanelPinned) {
        _isPanelPinned = nextPinned;
        _syncPanelPinnedToWindow();
      }
    }
    if (!identical(oldWidget.previewRepository, widget.previewRepository) ||
        oldWidget.guildId != widget.guildId ||
        oldWidget.channelId != widget.channelId) {
      _cancelStreamSubscription();
      _purgeMessageCache();
      _backgroundStreamHaltedByTerminalError = false;
      _unreadMessageIds.clear();
      _clearToastState(collapseIfShowing: !_isPanelOpen);
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
        _ensureBackgroundStreamIfEligible();
      }
    }
    if (oldWidget.toastNotificationsEnabled !=
        widget.toastNotificationsEnabled) {
      _applyToastNotificationsEnabled(
        widget.toastNotificationsEnabled,
        notifyCallback: false,
      );
    }
    if (oldWidget.maxVisibleToastCount != widget.maxVisibleToastCount &&
        !_isPanelOpen &&
        _toastEntries.isNotEmpty) {
      _syncToastOverlay();
    }
    if (oldWidget.toastLayout != widget.toastLayout) {
      _applyToastLayout(widget.toastLayout, notifyCallback: false);
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
    _purgeMessageCache();
    for (final entry in _toastEntries) {
      entry.timer.cancel();
    }
    _toastEntries.clear();
    _unreadMessageIds.clear();
    _toastOverlayToken = null;
    if (_isToastOverlayActive &&
        widget.windowController.usesNativeToastOverlay) {
      unawaited(
        widget.windowController.hideToastStack().catchError((Object _) {}),
      );
    }
    _isToastOverlayActive = false;
    _isCollapsingToastOverlay = false;
    _lastToastOverlaySize = null;
    widget.previewRepository.cancelActivePreview();
    widget.controller?._detach(this);
    _activeRequestToken = null;
    _messages = const <ChannelMessagePreview>[];
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isHardSuspended) {
        _isHardSuspended = false;
        _ensureBackgroundStreamIfEligible();
      }
      return;
    }
    if (state == AppLifecycleState.inactive) {
      if (_isPanelPinned || widget.windowController.usesNativeWindowDrag) {
        return;
      }
      closeAndClear();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      closeAndClear(suspendBackgroundStream: true);
    }
  }

  void _syncPanelPinnedToWindow() {
    unawaited(
      widget.windowController
          .setPanelPinned(_isPanelPinned)
          .catchError((Object _) {}),
    );
  }

  void _syncToastNotificationsEnabledToWindow() {
    unawaited(
      widget.windowController
          .setToastNotificationsEnabled(_toastNotificationsEnabled)
          .catchError((Object _) {}),
    );
  }

  void _syncToastLayoutToWindow() {
    unawaited(
      widget.windowController
          .setToastLayout(_toastLayout)
          .catchError((Object _) {}),
    );
  }

  void _applyToastLayout(
    ChatListLayout next, {
    required bool notifyCallback,
  }) {
    final changed = _toastLayout != next;
    _toastLayout = next;
    _syncToastLayoutToWindow();
    if (!_isPanelOpen && _toastEntries.isNotEmpty) {
      _syncToastOverlay();
    }
    if (changed && mounted) {
      setState(() {});
    }
    if (notifyCallback) {
      widget.onToastLayoutChanged?.call(next);
    }
  }

  void _handleToastLayoutChanged(ChatListLayout next) {
    _applyToastLayout(next, notifyCallback: true);
  }

  void _applyToastNotificationsEnabled(
    bool enabled, {
    required bool notifyCallback,
  }) {
    final changed = _toastNotificationsEnabled != enabled;
    _toastNotificationsEnabled = enabled;
    _syncToastNotificationsEnabledToWindow();
    if (!enabled) {
      // Clear active toast cards/overlay, but keep collapsed SSE alive for the unread badge.
      _clearToastState(collapseIfShowing: !_isPanelOpen);
    } else {
      _backgroundStreamHaltedByTerminalError = false;
      _ensureBackgroundStreamIfEligible();
    }
    if (changed && mounted) {
      setState(() {});
    }
    if (notifyCallback) {
      widget.onToastNotificationsChanged?.call(enabled);
    }
  }

  void _handleToastNotificationsChanged(bool enabled) {
    _applyToastNotificationsEnabled(enabled, notifyCallback: true);
  }

  void _subscribeToWindowEvents() {
    _lockSubscription = widget.windowController.onLockOrSleep.listen(
      (_) => closeAndClear(suspendBackgroundStream: true),
    );
    _dismissSubscription = widget.windowController.onPanelDismissRequested
        .listen((_) => _closePanelAndKeepSession());
    _toastTappedSubscription = widget.windowController.onToastTapped.listen(
      (_) => _handleToastTap(_lastViewportSize, _lastSafePadding),
    );
    _toastDismissedSubscription = widget.windowController.onToastDismissed
        .listen(_dismissToastById);
    _toastEnabledToggledSubscription =
        widget.windowController.onToastEnabledToggled.listen(
      _handleToastNotificationsChanged,
    );
    _toastLayoutToggledSubscription =
        widget.windowController.onToastLayoutToggled.listen(
      _handleToastLayoutChanged,
    );
  }

  void _unsubscribeFromWindowEvents() {
    _lockSubscription?.cancel();
    _lockSubscription = null;
    _dismissSubscription?.cancel();
    _dismissSubscription = null;
    _toastTappedSubscription?.cancel();
    _toastTappedSubscription = null;
    _toastDismissedSubscription?.cancel();
    _toastDismissedSubscription = null;
    _toastEnabledToggledSubscription?.cancel();
    _toastEnabledToggledSubscription = null;
    _toastLayoutToggledSubscription?.cancel();
    _toastLayoutToggledSubscription = null;
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
      _isCollapsingToastOverlay = false;
      return Offset(
        ((viewportSize.width - widget.orbSize.width) / 2)
            .clamp(0.0, double.infinity),
        ((viewportSize.height - widget.orbSize.height) / 2)
            .clamp(0.0, double.infinity),
      );
    }
    if (widget.windowController.usesNativeWindowDrag &&
        !_isPanelOpen &&
        !widget.windowController.usesNativeToastOverlay &&
        (_toastEntries.isNotEmpty || _isCollapsingToastOverlay)) {
      final anchorY = _toastDirection == OrbPanelExpandDirection.above
          ? viewportSize.height - safePadding.bottom - widget.orbSize.height - 12
          : safePadding.top + 12;
      final toastOrbOffset = Offset(
        viewportSize.width - safePadding.right - widget.orbSize.width - 12,
        anchorY,
      );
      return clampOrbOffset(
        offset: toastOrbOffset,
        orbSize: widget.orbSize,
        viewportSize: viewportSize,
        safePadding: safePadding,
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

  Size _toastStackTargetSize() {
    final visibleCount = math.min(_toastEntries.length, maxVisibleToastCount);
    final overflowCount = math.max(0, _toastEntries.length - visibleCount);
    final isCompact = _toastLayout == ChatListLayout.compact;
    if (visibleCount <= 1 && overflowCount == 0 && !isCompact) {
      return OrbShell.toastCardSize;
    }
    final estimatedHeight = OrbMessageToastStack.estimateHeight(
      visibleCount: visibleCount,
      overflowCount: overflowCount,
      compact: isCompact,
    );
    return Size(OrbShell.toastCardSize.width, estimatedHeight);
  }

  Size _toastWindowTargetSize() {
    final visibleCount = math.min(_toastEntries.length, maxVisibleToastCount);
    final overflowCount = math.max(0, _toastEntries.length - visibleCount);
    final isCompact = _toastLayout == ChatListLayout.compact;
    if (visibleCount <= 1 && overflowCount == 0 && !isCompact) {
      return OrbShell.toastWindowSize;
    }
    final stackHeight = OrbMessageToastStack.estimateHeight(
      visibleCount: visibleCount,
      overflowCount: overflowCount,
      compact: isCompact,
    );
    final totalHeight = math.max(
      isCompact ? 132.0 : OrbShell.toastWindowSize.height,
      12.0 + widget.orbSize.height + 8.0 + stackHeight + 12.0,
    );
    return Size(OrbShell.toastWindowSize.width, totalHeight);
  }

  PanelPlacement _resolvedToastPlacement({
    required Offset orbOffset,
    required Size viewportSize,
    required EdgeInsets safePadding,
  }) {
    final orbRect = orbOffset & widget.orbSize;
    final desiredStackSize = _toastStackTargetSize();
    if (widget.windowController.usesNativeWindowDrag &&
        !_isCollapsedOverlayViewport(viewportSize)) {
      final minLeft = safePadding.left + 12;
      final maxRight =
          math.max(minLeft, viewportSize.width - safePadding.right - 12);
      final width = math.max(0.0, maxRight - minLeft);
      final desiredHeight = desiredStackSize.height;

      if (_toastDirection == OrbPanelExpandDirection.above) {
        final bottom = math.max(safePadding.top + 12, orbRect.top - 8.0);
        final availableHeight = math.max(0.0, bottom - (safePadding.top + 12));
        final height = math.min(desiredHeight, availableHeight);
        final top = math.max(safePadding.top + 12, bottom - height);
        return PanelPlacement(
          rect: Rect.fromLTWH(minLeft, top, width, height),
          direction: PanelPlacementDirection.above,
        );
      }

      final top = orbRect.bottom + 8.0;
      final maxBottom =
          math.max(top, viewportSize.height - safePadding.bottom - 12);
      final height = math.min(desiredHeight, math.max(0.0, maxBottom - top));
      return PanelPlacement(
        rect: Rect.fromLTWH(minLeft, top, width, height),
        direction: PanelPlacementDirection.below,
      );
    }

    return computePanelRect(
      orbRect: orbRect,
      panelSize: desiredStackSize,
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
      _closePanelAndKeepSession();
      return;
    }
    _openPanelForViewport(viewportSize, safePadding);
  }

  void _handleToastTap(Size viewportSize, EdgeInsets safePadding) {
    if (_isOrbHidden || _isPanelOpen) {
      return;
    }
    _openPanelForViewport(viewportSize, safePadding);
  }

  void _openPanelForViewport(Size viewportSize, EdgeInsets safePadding) {
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
    _isHardSuspended = false;
    _backgroundStreamHaltedByTerminalError = false;
    _unreadMessageIds.clear();
    _clearToastState(collapseIfShowing: false, notify: false);

    final keepActiveStream = _hasActiveStreamForCurrentChannel;
    if (!keepActiveStream && _streamChannelKey != _currentChannelKey) {
      _cancelStreamSubscription();
    }

    final requestToken = Object();
    if (_hasValidCacheForCurrentChannel) {
      final cached = _cachedMessages;
      setState(() {
        _isPanelOpen = true;
        _messages = cached;
        _previewState = cached.isEmpty
            ? OrbPreviewState.emptyChannel
            : OrbPreviewState.loaded;
        _error = null;
        _activeRequestToken = requestToken;
      });

      unawaited(_expandWindowAndSyncDirection(targetPanelSize, requestToken));

      if (_hasValidChannel &&
          !_hasActiveStreamForCurrentChannel &&
          _streamReconnectTimer == null) {
        _startMessageStream(
          guildId: widget.guildId!,
          channelId: widget.channelId!,
        );
      }

      if (_needsSilentResyncAfterReconnect) {
        _fetchWithToken(requestToken, silent: true);
      }
      return;
    }

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

  void _handlePanelPinnedChanged(bool next) {
    if (next != _isPanelPinned) {
      setState(() {
        _isPanelPinned = next;
      });
      _syncPanelPinnedToWindow();
    }
    widget.onPanelPinnedChanged?.call(next);
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
    if (!_hasActiveStreamForCurrentChannel) {
      _cancelStreamSubscription();
    }
    final requestToken = Object();
    setState(() {
      _previewState = OrbPreviewState.loading;
      _messages = const <ChannelMessagePreview>[];
      _error = null;
      _activeRequestToken = requestToken;
    });
    _fetchWithToken(requestToken);
  }

  Future<void> _fetchWithToken(
    Object requestToken, {
    bool silent = false,
  }) async {
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
      _purgeMessageCache();
      setState(() {
        _previewState = OrbPreviewState.accessDenied;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
      });
      return;
    }

    final expectedKey = '$guildId:$channelId';
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
      _cachedMessages = newest;
      _hasLoadedMessages = true;
      _loadedChannelKey = expectedKey;
      _needsSilentResyncAfterReconnect = false;
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
      if (_messageStreamSubscription == null ||
          _streamChannelKey != expectedKey) {
        _startMessageStream(
          guildId: guildId,
          channelId: channelId,
        );
      }
    } on OrbException catch (e) {
      if (!mounted ||
          !_isPanelOpen ||
          !identical(_activeRequestToken, requestToken)) {
        return;
      }
      if (e.state == OrbPreviewState.sessionExpired ||
          e.state == OrbPreviewState.accessDenied ||
          e.state == OrbPreviewState.botUnavailable) {
        _cancelStreamSubscription();
        _purgeMessageCache();
        _backgroundStreamHaltedByTerminalError = true;
        widget.previewRepository.clearMemory();
        setState(() {
          _previewState = e.state;
          _messages = const <ChannelMessagePreview>[];
          _error = e;
        });
        return;
      }
      if (silent && _hasValidCacheForCurrentChannel) {
        // Keep displaying warm RAM cache on transient silent resync errors
        // (including 429 rate-limit) without flashing a loading/error screen.
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
      if (silent && _hasValidCacheForCurrentChannel) {
        return;
      }
      setState(() {
        _previewState = OrbPreviewState.networkError;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
      });
    }
  }

  void _ensureBackgroundStreamIfEligible() {
    if (!mounted || !_canRunBackgroundStream) {
      return;
    }
    final expectedKey = _currentChannelKey;
    if ((_messageStreamSubscription != null || _streamReconnectTimer != null) &&
        _streamChannelKey == expectedKey) {
      return;
    }
    _startMessageStream(
      guildId: widget.guildId!,
      channelId: widget.channelId!,
    );
  }

  void _startMessageStream({
    required String guildId,
    required String channelId,
  }) {
    if (!mounted || (!_isPanelOpen && !_canRunBackgroundStream)) {
      return;
    }
    _streamReconnectTimer?.cancel();
    _streamReconnectTimer = null;
    final previous = _messageStreamSubscription;
    _messageStreamSubscription = null;
    if (previous != null) {
      unawaited(previous.cancel());
    }

    final sessionToken = Object();
    _streamSessionToken = sessionToken;
    _streamChannelKey = '$guildId:$channelId';

    final stream = widget.previewRepository.subscribeToChannelMessages(
      guildId: guildId,
      channelId: channelId,
      requestToken: sessionToken,
    );

    _messageStreamSubscription = stream.listen(
      (ChannelMessageEvent event) => _handleStreamEvent(event, sessionToken),
      onError: (Object error, StackTrace _) => _handleStreamError(
        error,
        guildId: guildId,
        channelId: channelId,
        sessionToken: sessionToken,
      ),
      onDone: () {
        if (!mounted || !identical(_streamSessionToken, sessionToken)) {
          return;
        }
        _messageStreamSubscription = null;
        _streamChannelKey = null;
        if (_hasValidCacheForCurrentChannel) {
          _needsSilentResyncAfterReconnect = true;
        }
        if (_isPanelOpen || _canRunBackgroundStream) {
          _scheduleStreamReconnect(
            guildId: guildId,
            channelId: channelId,
            sessionToken: sessionToken,
          );
        }
      },
      cancelOnError: true,
    );
  }

  void _handleStreamEvent(ChannelMessageEvent event, Object sessionToken) {
    if (!mounted || !identical(_streamSessionToken, sessionToken)) {
      return;
    }
    _streamReconnectAttempts = 0;
    if (event.type == ChannelMessageEventType.ready) {
      if (_needsSilentResyncAfterReconnect &&
          _isPanelOpen &&
          _hasValidCacheForCurrentChannel) {
        final token = _activeRequestToken ?? Object();
        _activeRequestToken = token;
        unawaited(_fetchWithToken(token, silent: true));
      }
      return;
    }

    // Keep RAM message cache continuously updated in both open and collapsed states.
    if (_hasValidCacheForCurrentChannel) {
      _cachedMessages = mergeChannelMessageEvent(
        _cachedMessages,
        event,
        maxMessages: MessagePanel.maxVisibleMessages,
      );
    }

    if (_isPanelOpen) {
      if (_previewState != OrbPreviewState.loaded &&
          _previewState != OrbPreviewState.emptyChannel) {
        return;
      }
      final merged = _hasValidCacheForCurrentChannel
          ? _cachedMessages
          : mergeChannelMessageEvent(
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
      return;
    }

    if (_isOrbHidden || _isHardSuspended) {
      return;
    }

    switch (event.type) {
      case ChannelMessageEventType.ready:
        return;
      case ChannelMessageEventType.create:
        final incoming = event.message;
        if (incoming != null) {
          final addedUnread = _unreadMessageIds.add(incoming.id);
          if (_toastNotificationsEnabled) {
            _enqueueIncomingToast(incoming);
          } else if (addedUnread && mounted) {
            setState(() {});
          }
        }
      case ChannelMessageEventType.update:
        if (_toastNotificationsEnabled) {
          _handleToastUpdateEvent(event);
        }
      case ChannelMessageEventType.delete:
        final deletedId = event.messageId;
        if (deletedId != null && deletedId.isNotEmpty) {
          final removedUnread = _unreadMessageIds.remove(deletedId);
          if (_toastNotificationsEnabled) {
            _dismissToastById(deletedId);
          }
          if (removedUnread && mounted) {
            setState(() {});
          }
        }
    }
  }

  void _enqueueIncomingToast(ChannelMessagePreview message) {
    _isCollapsingToastOverlay = false;

    final existingIndex = _toastEntries.indexWhere(
      (_ToastEntry entry) => entry.message.id == message.id,
    );
    if (existingIndex != -1) {
      _toastEntries[existingIndex].timer.cancel();
      _toastEntries.removeAt(existingIndex);
    }

    late final _ToastEntry entry;
    entry = _ToastEntry(
      message: message,
      timer: Timer(widget.toastDuration, () => _expireToastEntry(entry)),
    );
    _toastEntries.insert(0, entry);

    while (_toastEntries.length > OrbShell.maxBufferedToasts) {
      final removed = _toastEntries.removeLast();
      removed.timer.cancel();
    }

    if (mounted) {
      setState(() {});
    }
    _syncToastOverlay();
  }

  void _handleToastUpdateEvent(ChannelMessageEvent event) {
    final targetId = event.messageId;
    if (targetId == null || targetId.isEmpty) {
      return;
    }
    final index = _toastEntries.indexWhere(
      (_ToastEntry entry) => entry.message.id == targetId,
    );
    if (index == -1) {
      return;
    }
    final existing = _toastEntries[index];
    existing.message = existing.message.copyWith(
      authorName: event.authorName,
      authorAvatarUrl: event.authorAvatarUrl,
      timestamp: event.timestamp,
      content: event.content,
    );
    if (mounted) {
      setState(() {});
    }
    _syncToastOverlay();
  }

  void _expireToastEntry(_ToastEntry entry) {
    final index = _toastEntries.indexWhere(
      (_ToastEntry candidate) => identical(candidate, entry),
    );
    if (index == -1) {
      return;
    }
    _toastEntries.removeAt(index);
    if (_toastEntries.isEmpty) {
      _clearToastState(collapseIfShowing: !_isPanelOpen);
      return;
    }
    if (mounted) {
      setState(() {});
    }
    _syncToastOverlay();
  }

  void _dismissToastById(String messageId) {
    final index = _toastEntries.indexWhere(
      (_ToastEntry entry) => entry.message.id == messageId,
    );
    if (index == -1) {
      return;
    }
    final removed = _toastEntries.removeAt(index);
    removed.timer.cancel();
    if (_toastEntries.isEmpty) {
      _clearToastState(collapseIfShowing: !_isPanelOpen);
      return;
    }
    if (mounted) {
      setState(() {});
    }
    _syncToastOverlay();
  }

  void _syncToastOverlay() {
    if (_isPanelOpen) {
      return;
    }
    if (widget.windowController.usesNativeToastOverlay) {
      if (_toastEntries.isEmpty) {
        if (_isToastOverlayActive) {
          _isToastOverlayActive = false;
          unawaited(
            widget.windowController.hideToastStack().catchError((Object _) {}),
          );
        }
        return;
      }
      _isToastOverlayActive = true;
      unawaited(
        widget.windowController
            .updateToastStack(
              messages: toastMessages,
              maxVisibleCount: maxVisibleToastCount,
              channelName: widget.channelName,
              compact: _toastLayout == ChatListLayout.compact,
            )
            .catchError((Object _) {}),
      );
      return;
    }

    if (_toastEntries.isEmpty) {
      if (_isToastOverlayActive) {
        _isToastOverlayActive = false;
        _isCollapsingToastOverlay = true;
        _lastToastOverlaySize = null;
        unawaited(
          widget.windowController.collapsePanel().catchError((Object _) {}),
        );
      }
      return;
    }

    final targetSize = _toastWindowTargetSize();
    if (!_isToastOverlayActive || _lastToastOverlaySize != targetSize) {
      _isToastOverlayActive = true;
      _lastToastOverlaySize = targetSize;
      final toastToken = Object();
      _toastOverlayToken = toastToken;
      unawaited(_showToastWindowAndSyncDirection(targetSize, toastToken));
    }
  }

  Future<void> _showToastWindowAndSyncDirection(
    Size targetSize,
    Object toastToken,
  ) async {
    try {
      final direction =
          await widget.windowController.showToastOverlay(targetSize);
      if (!mounted ||
          _isPanelOpen ||
          !_isToastOverlayActive ||
          !identical(_toastOverlayToken, toastToken)) {
        return;
      }
      if (direction != _toastDirection) {
        setState(() {
          _toastDirection = direction;
        });
      }
    } catch (_) {
      // Ignore host window channel failures in headless tests.
    }
  }

  void _clearToastState({
    required bool collapseIfShowing,
    bool notify = true,
  }) {
    final hadEntries = _toastEntries.isNotEmpty;
    for (final entry in _toastEntries) {
      entry.timer.cancel();
    }
    _toastEntries.clear();
    _toastOverlayToken = null;
    final wasShowing = hadEntries || _isToastOverlayActive;
    _isToastOverlayActive = false;
    _lastToastOverlaySize = null;

    if (widget.windowController.usesNativeToastOverlay) {
      if (wasShowing) {
        unawaited(
          widget.windowController.hideToastStack().catchError((Object _) {}),
        );
      }
    } else if (collapseIfShowing && wasShowing) {
      _isCollapsingToastOverlay = true;
      unawaited(
        widget.windowController.collapsePanel().catchError((Object _) {}),
      );
    } else {
      _isCollapsingToastOverlay = false;
    }

    if (!notify || !mounted) {
      if (!collapseIfShowing) {
        _toastDirection = OrbPanelExpandDirection.below;
      }
      return;
    }
    if (hadEntries ||
        wasShowing ||
        (!collapseIfShowing &&
            _toastDirection != OrbPanelExpandDirection.below)) {
      setState(() {
        if (!collapseIfShowing) {
          _toastDirection = OrbPanelExpandDirection.below;
        }
      });
    }
  }

  void _handleStreamError(
    Object error, {
    required String guildId,
    required String channelId,
    required Object sessionToken,
  }) {
    if (!mounted || !identical(_streamSessionToken, sessionToken)) {
      return;
    }
    _messageStreamSubscription = null;
    _streamChannelKey = null;

    if (error is OrbException) {
      if (error.code == 'preview_cancelled') {
        return;
      }
      if (error.state == OrbPreviewState.sessionExpired ||
          error.state == OrbPreviewState.accessDenied ||
          error.state == OrbPreviewState.botUnavailable) {
        _cancelStreamSubscription();
        _purgeMessageCache();
        _backgroundStreamHaltedByTerminalError = true;
        final hadUnread = _unreadMessageIds.isNotEmpty;
        _unreadMessageIds.clear();
        widget.previewRepository.clearMemory();
        if (_isPanelOpen) {
          setState(() {
            _previewState = error.state;
            _messages = const <ChannelMessagePreview>[];
            _error = error;
          });
        } else {
          _clearToastState(collapseIfShowing: true);
          if (hadUnread && mounted) {
            setState(() {});
          }
        }
        return;
      }
      if (_hasValidCacheForCurrentChannel) {
        _needsSilentResyncAfterReconnect = true;
      }
      if (_isPanelOpen || _canRunBackgroundStream) {
        _scheduleStreamReconnect(
          guildId: guildId,
          channelId: channelId,
          sessionToken: sessionToken,
          minDelay: error.retryAfter,
        );
      }
      return;
    }

    if (_hasValidCacheForCurrentChannel) {
      _needsSilentResyncAfterReconnect = true;
    }
    if (_isPanelOpen || _canRunBackgroundStream) {
      _scheduleStreamReconnect(
        guildId: guildId,
        channelId: channelId,
        sessionToken: sessionToken,
      );
    }
  }

  void _scheduleStreamReconnect({
    required String guildId,
    required String channelId,
    required Object sessionToken,
    Duration? minDelay,
  }) {
    if (!mounted ||
        !identical(_streamSessionToken, sessionToken) ||
        (!_isPanelOpen && !_canRunBackgroundStream) ||
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
      // Honor explicit server Retry-After (e.g., 429 cooldown) in full.
      delayMs = minDelay.inMilliseconds;
    }
    _streamReconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _streamReconnectTimer = null;
      if (!mounted ||
          !identical(_streamSessionToken, sessionToken) ||
          (!_isPanelOpen && !_canRunBackgroundStream)) {
        return;
      }
      _startMessageStream(
        guildId: guildId,
        channelId: channelId,
      );
    });
  }

  void _purgeMessageCache() {
    _cachedMessages = const <ChannelMessagePreview>[];
    _hasLoadedMessages = false;
    _loadedChannelKey = null;
    _needsSilentResyncAfterReconnect = false;
  }

  void _cancelStreamSubscription() {
    _streamSessionToken = null;
    _streamChannelKey = null;
    _streamReconnectTimer?.cancel();
    _streamReconnectTimer = null;
    _streamReconnectAttempts = 0;
    final sub = _messageStreamSubscription;
    _messageStreamSubscription = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  /// Explicitly closes the expanded panel UI while keeping the RAM message
  /// cache and single persistent SSE stream alive for instant reopen and zero
  /// redundant REST calls.
  void _closePanelAndKeepSession() {
    final wasOpen = _isPanelOpen;
    _activeRequestToken = null;
    if (wasOpen) {
      unawaited(
        widget.windowController.collapsePanel().catchError((Object _) {}),
      );
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
    _ensureBackgroundStreamIfEligible();
  }

  /// Hard security clear: closes any open panel and toast, cancels SSE and
  /// in-flight fetches, and wipes all in-memory messages, RAM cache, toast
  /// previews, and unread badge IDs.
  void closeAndClear({bool suspendBackgroundStream = false}) {
    if (suspendBackgroundStream) {
      _isHardSuspended = true;
    }
    final wasOpen = _isPanelOpen;
    final hadToast = _toastEntries.isNotEmpty || _isToastOverlayActive;
    final hadUnread = _unreadMessageIds.isNotEmpty;
    _unreadMessageIds.clear();
    _activeRequestToken = null;
    _cancelStreamSubscription();
    _purgeMessageCache();
    _clearToastState(collapseIfShowing: false, notify: false);
    widget.previewRepository.clearMemory();
    widget.previewRepository.cancelActivePreview();
    if (wasOpen ||
        (hadToast && !widget.windowController.usesNativeToastOverlay)) {
      unawaited(
        widget.windowController.collapsePanel().catchError((Object _) {}),
      );
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
        hadToast ||
        hadUnread ||
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

  /// Hides the floating orb and clears any open panel/messages/toast.
  void hideOrb() {
    closeAndClear(suspendBackgroundStream: true);
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
    _isHardSuspended = false;
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
    _ensureBackgroundStreamIfEligible();
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
        _lastViewportSize = viewportSize;
        _lastSafePadding = safePadding;

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
        final activeToasts = toastMessages;
        final shouldRenderFlutterToast = !_isPanelOpen &&
            !widget.windowController.usesNativeToastOverlay &&
            activeToasts.isNotEmpty;
        final toastPlacement = shouldRenderFlutterToast
            ? _resolvedToastPlacement(
                orbOffset: orbOffset,
                viewportSize: viewportSize,
                safePadding: safePadding,
              )
            : null;
        final canRenderToast = toastPlacement != null &&
            toastPlacement.rect.width >= 160 &&
            toastPlacement.rect.height >= 48;

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
                        isPinned: _isPanelPinned,
                        onPinnedChanged: _handlePanelPinnedChanged,
                        toastNotificationsEnabled: _toastNotificationsEnabled,
                        onToastNotificationsChanged:
                            _handleToastNotificationsChanged,
                        error: _error,
                        onClose: _closePanelAndKeepSession,
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
            if (shouldRenderFlutterToast && canRenderToast)
              Positioned.fromRect(
                rect: toastPlacement.rect,
                child: Align(
                  alignment:
                      toastPlacement.direction == PanelPlacementDirection.above
                          ? Alignment.bottomCenter
                          : Alignment.topCenter,
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: OrbMessageToastStack(
                      messages: activeToasts,
                      maxVisibleCount: maxVisibleToastCount,
                      direction: toastPlacement.direction,
                      layout: _toastLayout,
                      channelName: widget.channelName,
                      onTapStack: () =>
                          _handleToastTap(viewportSize, safePadding),
                      onDismissMessage: _dismissToastById,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: orbOffset.dx,
              top: orbOffset.dy,
              child: OrbButton(
                isPanelOpen: _isPanelOpen,
                size: widget.orbSize,
                unreadCount: _unreadMessageIds.length,
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
