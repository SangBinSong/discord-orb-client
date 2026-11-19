import 'dart:async';

import 'package:flutter/services.dart';

import '../contracts/orb_window_controller.dart';

/// Desktop (macOS & Windows) [OrbWindowController] backed by a [MethodChannel].
class DesktopOrbWindowController implements OrbWindowController {
  DesktopOrbWindowController({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const String channelName = 'discord_orb/window';

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
  Future<void> openOverlayPermissionSettings() async {
    await _channel.invokeMethod<void>('openOverlayPermissionSettings');
  }

  @override
  Future<void> showCollapsedOrb() async {
    await _channel.invokeMethod<void>('showCollapsedOrb');
  }

  @override
  Future<void> expandPanel(Size size) async {
    await _channel.invokeMethod<void>('expandPanel', <String, dynamic>{
      'width': size.width,
      'height': size.height,
    });
  }

  @override
  Future<void> collapsePanel() async {
    await _channel.invokeMethod<void>('collapsePanel');
  }

  @override
  Future<void> hideOrb() async {
    await _channel.invokeMethod<void>('hideOrb');
  }

  @override
  Stream<void> get onLockOrSleep => _lockOrSleepController.stream;

  @override
  Stream<void> get onPanelDismissRequested => _panelDismissController.stream;

  Future<dynamic> _handleMethodCall(MethodCall call) async {
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
          'Unhandled method ${call.method} on $channelName',
        );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _lockOrSleepController.close();
    await _panelDismissController.close();
  }
}
