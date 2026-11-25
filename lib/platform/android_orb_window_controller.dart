import 'dart:async';

import 'package:flutter/services.dart';

import '../app.dart';
import '../contracts/orb_window_controller.dart';

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

  bool _disposed = false;

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
  Future<void> expandPanel(Size size) {
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
    return _channel.invokeMethod<void>(
      'expandPanel',
      <String, double>{
        'width': size.width,
        'height': size.height,
      },
    );
  }

  @override
  Future<void> collapsePanel() {
    return _channel.invokeMethod<void>('collapsePanel');
  }

  @override
  Future<void> hideOrb() {
    return _channel.invokeMethod<void>('hideOrb');
  }

  @override
  Future<void> moveOrbBy(Offset delta) async {}

  @override
  Future<void> showMainWindow() async {}

  @override
  Stream<void> get onLockOrSleep => _lockOrSleepController.stream;

  @override
  Stream<void> get onPanelDismissRequested => _panelDismissController.stream;

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
  }
}
