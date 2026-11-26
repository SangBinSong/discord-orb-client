import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../contracts/orb_window_controller.dart';
import '../models/message_models.dart';

/// Desktop (macOS & Windows) [OrbWindowController] backed by a [MethodChannel].
class DesktopOrbWindowController implements OrbWindowController {
  DesktopOrbWindowController({
    MethodChannel? channel,
    bool? usesNativeToastOverlay,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _usesNativeToastOverlay = usesNativeToastOverlay ?? Platform.isMacOS {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const String channelName = 'discord_orb/window';

  final MethodChannel _channel;
  final bool _usesNativeToastOverlay;
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

  @override
  bool get usesNativeWindowDrag => true;

  @override
  bool get usesNativeToastOverlay => _usesNativeToastOverlay;

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
  Future<OrbPanelExpandDirection> expandPanel(Size size) async {
    final result = await _channel.invokeMethod<dynamic>(
      'expandPanel',
      <String, dynamic>{
        'width': size.width,
        'height': size.height,
      },
    );
    return OrbPanelExpandDirection.fromWireValue(result);
  }

  @override
  Future<OrbPanelExpandDirection> showToastOverlay(Size size) async {
    final result = await _channel.invokeMethod<dynamic>(
      'showToastOverlay',
      <String, dynamic>{
        'width': size.width,
        'height': size.height,
      },
    );
    return OrbPanelExpandDirection.fromWireValue(result);
  }

  @override
  Future<void> updateToastStack({
    required List<ChannelMessagePreview> messages,
    required int maxVisibleCount,
    String? channelName,
    bool compact = false,
  }) async {
    await _channel.invokeMethod<void>(
      'updateToastStack',
      <String, dynamic>{
        'messages': messages
            .map(
              (ChannelMessagePreview message) => <String, dynamic>{
                'id': message.id,
                'authorName': message.authorName,
                if (message.authorAvatarUrl != null)
                  'authorAvatarUrl': message.authorAvatarUrl,
                'content': message.content,
                'timestamp': message.timestamp.toUtc().toIso8601String(),
              },
            )
            .toList(growable: false),
        'maxVisibleCount': maxVisibleCount,
        'compact': compact,
        if (channelName != null && channelName.isNotEmpty)
          'channelName': channelName,
      },
    );
  }

  @override
  Future<void> hideToastStack() async {
    await _channel.invokeMethod<void>('hideToastStack');
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
  Future<void> setPanelPinned(bool pinned) async {
    await _channel.invokeMethod<void>('setPanelPinned', <String, dynamic>{
      'pinned': pinned,
    });
  }

  @override
  Future<void> setToastNotificationsEnabled(bool enabled) async {
    await _channel.invokeMethod<void>(
      'setToastNotificationsEnabled',
      <String, dynamic>{'enabled': enabled},
    );
  }

  @override
  Future<void> setToastLayout(ChatListLayout layout) async {
    await _channel.invokeMethod<void>(
      'setToastLayout',
      <String, dynamic>{'compact': layout == ChatListLayout.compact},
    );
  }

  @override
  Future<void> quitApp() async {
    await _channel.invokeMethod<void>('quitApp');
  }

  @override
  Future<void> startOrbDrag() async {
    await _channel.invokeMethod<void>('startOrbDrag');
  }

  @override
  Future<void> startPanelResize(PanelResizeEdge edge) async {
    await _channel.invokeMethod<void>('startPanelResize', <String, dynamic>{
      'edge': edge.wireName,
    });
  }

  @override
  Future<void> moveOrbBy(Offset delta) async {
    await _channel.invokeMethod<void>('moveOrb', <String, dynamic>{
      'dx': delta.dx,
      'dy': delta.dy,
    });
  }

  @override
  Future<void> showMainWindow() async {
    await _channel.invokeMethod<void>('showMainWindow');
  }

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
      case 'onToastTapped':
        _toastTappedController.add(null);
        return null;
      case 'onToastDismissed':
        final args = call.arguments;
        String? messageId;
        if (args is Map<Object?, Object?>) {
          final raw = args['messageId'];
          if (raw is String && raw.isNotEmpty) {
            messageId = raw;
          }
        } else if (args is String && args.isNotEmpty) {
          messageId = args;
        }
        if (messageId != null) {
          _toastDismissedController.add(messageId);
        }
        return null;
      case 'onToastEnabledToggled':
        final args = call.arguments;
        bool? enabled;
        if (args is Map<Object?, Object?>) {
          final raw = args['enabled'];
          if (raw is bool) {
            enabled = raw;
          }
        } else if (args is bool) {
          enabled = args;
        }
        if (enabled != null) {
          _toastEnabledToggledController.add(enabled);
        }
        return null;
      case 'onToastLayoutToggled':
        final args = call.arguments;
        bool? compact;
        if (args is Map<Object?, Object?>) {
          final raw = args['compact'];
          if (raw is bool) {
            compact = raw;
          }
        } else if (args is bool) {
          compact = args;
        }
        if (compact != null) {
          _toastLayoutToggledController.add(
            compact ? ChatListLayout.compact : ChatListLayout.standard,
          );
        }
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
    await _toastTappedController.close();
    await _toastDismissedController.close();
    await _toastEnabledToggledController.close();
    await _toastLayoutToggledController.close();
  }
}
