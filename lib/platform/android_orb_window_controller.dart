import 'dart:async';

import 'package:flutter/services.dart';

import '../app.dart';
import '../contracts/orb_window_controller.dart';
import '../models/message_models.dart';

/// Android implementation of [OrbWindowController] backed by the
/// `discord_orb/window` [MethodChannel].
class AndroidOrbWindowController implements OrbWindowController {
  AndroidOrbWindowController({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(OrbPlatformChannels.window) {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  final MethodChannel _channel;
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

  bool get isPanelPinned => _isPanelPinned;
  bool get isToastNotificationsEnabled => _isToastNotificationsEnabled;
  ChatListLayout get toastLayout => _toastLayout;

  @override
  bool get usesNativeWindowDrag => false;

  @override
  bool get usesNativeToastOverlay => false;

  @override
  Future<bool> hasOverlayPermission() async {
    final granted = await _channel.invokeMethod<bool>('hasOverlayPermission');
    return granted ?? false;
  }

  @override
  Future<void> openOverlayPermissionSettings() {
    return _channel.invokeMethod<void>('openOverlayPermissionSettings');
  }

  @override
  Future<void> showCollapsedOrb() {
    return _channel.invokeMethod<void>('showCollapsedOrb');
  }

  @override
  Future<OrbPanelExpandDirection> expandPanel(Size size) async {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw ArgumentError.value(
        size,
        'size',
        'Panel size must have positive finite dimensions',
      );
    }
    final result = await _channel.invokeMethod<dynamic>(
      'expandPanel',
      <String, double>{
        'width': size.width,
        'height': size.height,
      },
    );
    return OrbPanelExpandDirection.fromWireValue(result);
  }

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
  Future<void> collapsePanel() {
    return _channel.invokeMethod<void>('collapsePanel');
  }

  @override
  Future<void> hideOrb() {
    return _channel.invokeMethod<void>('hideOrb');
  }

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
    try {
      await _channel.invokeMethod<void>('quitApp');
    } on MissingPluginException {
      await SystemNavigator.pop();
    }
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

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (_disposed) {
      return null;
    }

    switch (call.method) {
      case 'onLockOrSleep':
        _lockOrSleepController.add(null);
        return null;
      case 'onPanelDismissRequested':
        _panelDismissController.add(null);
        return null;
      default:
        throw MissingPluginException(
          'Unhandled method ${call.method} on ${_channel.name}',
        );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _lockOrSleepController.close();
    await _panelDismissController.close();
    await _toastTappedController.close();
    await _toastDismissedController.close();
    await _toastEnabledToggledController.close();
    await _toastLayoutToggledController.close();
  }
}
