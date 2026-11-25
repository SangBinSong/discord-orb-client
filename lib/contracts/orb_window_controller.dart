import 'dart:async';
import 'dart:ui';

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
  Future<bool> hasOverlayPermission();
  Future<void> openOverlayPermissionSettings();
  Future<void> showCollapsedOrb();
  Future<OrbPanelExpandDirection> expandPanel(Size size);
  Future<void> collapsePanel();
  Future<void> hideOrb();
  Future<void> startOrbDrag();
  Future<void> startPanelResize(PanelResizeEdge edge);
  Future<void> moveOrbBy(Offset delta);
  Future<void> showMainWindow();
  Stream<void> get onLockOrSleep;
  Stream<void> get onPanelDismissRequested;
  Future<void> dispose();
}

/// No-op [OrbWindowController] with test helpers to simulate OS events.
class NoopOrbWindowController implements OrbWindowController {
  final StreamController<void> _lockOrSleepController =
      StreamController<void>.broadcast();
  final StreamController<void> _panelDismissController =
      StreamController<void>.broadcast();

  bool _disposed = false;

  @override
  bool get usesNativeWindowDrag => false;

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
  Future<void> collapsePanel() async {}

  @override
  Future<void> hideOrb() async {}

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

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _lockOrSleepController.close();
    await _panelDismissController.close();
  }
}
