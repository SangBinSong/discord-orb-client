import 'dart:async';
import 'dart:ui';

import '../models/message_models.dart';

/// Vertical direction in which the native overlay panel expanded relative to the orb.
enum OrbPanelExpandDirection {
  below,
  above;

  static OrbPanelExpandDirection fromWireValue(Object? raw) {
    if (raw is String && raw.trim().toLowerCase() == 'above') {
      return OrbPanelExpandDirection.above;
    }
    if (raw is Map<Object?, Object?>) {
      final dir = raw['direction'];
      if (dir is String && dir.trim().toLowerCase() == 'above') {
        return OrbPanelExpandDirection.above;
      }
    }
    return OrbPanelExpandDirection.below;
  }
}

/// Edges and corners of the expanded panel that can be dragged to resize it.
enum PanelResizeEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  String get wireName => name;
}

/// Platform window/overlay controller for the floating Discord Orb and panel.
abstract interface class OrbWindowController {
  bool get usesNativeWindowDrag => false;
  bool get usesNativeToastOverlay => false;
  Future<bool> hasOverlayPermission();
  Future<void> openOverlayPermissionSettings();
  Future<void> showCollapsedOrb();
  Future<OrbPanelExpandDirection> expandPanel(Size size);
  Future<OrbPanelExpandDirection> showToastOverlay(Size size);
  Future<void> updateToastStack({
    required List<ChannelMessagePreview> messages,
    required int maxVisibleCount,
    String? channelName,
    bool compact = false,
  });
  Future<void> hideToastStack();
  Future<void> collapsePanel();
  Future<void> hideOrb();
  Future<void> setPanelPinned(bool pinned);
  Future<void> setToastNotificationsEnabled(bool enabled);
  Future<void> setToastLayout(ChatListLayout layout);
  Future<void> quitApp();
  Future<void> startOrbDrag();
  Future<void> startPanelResize(PanelResizeEdge edge);
  Future<void> moveOrbBy(Offset delta);
  Future<void> showMainWindow();
  Stream<void> get onLockOrSleep;
  Stream<void> get onPanelDismissRequested;
  Stream<void> get onToastTapped;
  Stream<String> get onToastDismissed;
  Stream<bool> get onToastEnabledToggled;
  Stream<ChatListLayout> get onToastLayoutToggled;
  Future<void> dispose();
}

/// No-op [OrbWindowController] with test helpers to simulate OS events.
class NoopOrbWindowController implements OrbWindowController {
  final StreamController<void> _lockOrSleepController =
      StreamController<void>.broadcast();
  final StreamController<void> _panelDismissController =
      StreamController<void>.broadcast();
  final StreamController<void> _toastTappedController =
      StreamController<void>.broadcast();
  final StreamController<String> _toastDismissedController =
      StreamController<String>.broadcast();
  final StreamController<bool> _toastEnabledToggledController =
      StreamController<bool>.broadcast();
  final StreamController<ChatListLayout> _toastLayoutToggledController =
      StreamController<ChatListLayout>.broadcast();

  bool _disposed = false;
  bool _isPanelPinned = true;
  bool _isToastNotificationsEnabled = true;
  ChatListLayout _toastLayout = ChatListLayout.standard;
  int quitCallCount = 0;

  bool get isPanelPinned => _isPanelPinned;
  bool get isToastNotificationsEnabled => _isToastNotificationsEnabled;
  ChatListLayout get toastLayout => _toastLayout;
  bool get quitRequested => quitCallCount > 0;

  @override
  bool get usesNativeWindowDrag => false;

  @override
  bool get usesNativeToastOverlay => false;

  @override
  Future<bool> hasOverlayPermission() async => true;

  @override
  Future<void> openOverlayPermissionSettings() async {}

  @override
  Future<void> showCollapsedOrb() async {}

  @override
  Future<OrbPanelExpandDirection> expandPanel(Size size) async =>
      OrbPanelExpandDirection.below;

  @override
  Future<OrbPanelExpandDirection> showToastOverlay(Size size) async =>
      OrbPanelExpandDirection.below;

  @override
  Future<void> updateToastStack({
    required List<ChannelMessagePreview> messages,
    required int maxVisibleCount,
    String? channelName,
    bool compact = false,
  }) async {}

  @override
  Future<void> hideToastStack() async {}

  @override
  Future<void> collapsePanel() async {}

  @override
  Future<void> hideOrb() async {}

  @override
  Future<void> setPanelPinned(bool pinned) async {
    _isPanelPinned = pinned;
  }

  @override
  Future<void> setToastNotificationsEnabled(bool enabled) async {
    _isToastNotificationsEnabled = enabled;
  }

  @override
  Future<void> setToastLayout(ChatListLayout layout) async {
    _toastLayout = layout;
  }

  @override
  Future<void> quitApp() async {
    quitCallCount += 1;
  }

  @override
  Future<void> startOrbDrag() async {}

  @override
  Future<void> startPanelResize(PanelResizeEdge edge) async {}

  @override
  Future<void> moveOrbBy(Offset delta) async {}

  @override
  Future<void> showMainWindow() async {}

  @override
  Stream<void> get onLockOrSleep => _lockOrSleepController.stream;

  @override
  Stream<void> get onPanelDismissRequested => _panelDismissController.stream;

  @override
  Stream<void> get onToastTapped => _toastTappedController.stream;

  @override
  Stream<String> get onToastDismissed => _toastDismissedController.stream;

  @override
  Stream<bool> get onToastEnabledToggled =>
      _toastEnabledToggledController.stream;

  @override
  Stream<ChatListLayout> get onToastLayoutToggled =>
      _toastLayoutToggledController.stream;

  /// Emits a synthetic lock/sleep event for unit and widget tests.
  void emitLockOrSleep() {
    if (!_disposed) {
      _lockOrSleepController.add(null);
    }
  }

  /// Emits a synthetic panel dismiss request for unit and widget tests.
  void emitPanelDismissRequested() {
    if (!_disposed) {
      _panelDismissController.add(null);
    }
  }

  /// Emits a synthetic native toast tap event for unit and widget tests.
  void emitToastTapped() {
    if (!_disposed) {
      _toastTappedController.add(null);
    }
  }

  /// Emits a synthetic native toast dismiss event for unit and widget tests.
  void emitToastDismissed(String messageId) {
    if (!_disposed) {
      _toastDismissedController.add(messageId);
    }
  }

  /// Emits a synthetic native context-menu toast toggle for unit/widget tests.
  void emitToastEnabledToggled(bool enabled) {
    if (!_disposed) {
      _isToastNotificationsEnabled = enabled;
      _toastEnabledToggledController.add(enabled);
    }
  }

  /// Emits a synthetic native context-menu toast layout toggle for tests.
  void emitToastLayoutToggled(ChatListLayout layout) {
    if (!_disposed) {
      _toastLayout = layout;
      _toastLayoutToggledController.add(layout);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _lockOrSleepController.close();
    await _panelDismissController.close();
    await _toastTappedController.close();
    await _toastDismissedController.close();
    await _toastEnabledToggledController.close();
    await _toastLayoutToggledController.close();
  }
}
