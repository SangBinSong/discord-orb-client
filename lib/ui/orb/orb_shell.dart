import 'dart:async';

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
    this.controller,
    this.orbSize = const Size(56, 56),
    this.panelSize = const Size(320, 400),
    this.initialOrbOffset,
    this.safePadding = EdgeInsets.zero,
    this.showRestoreChipWhenHidden = true,
    this.onReauthenticate,
    this.onReselectChannel,
  });

  static const Key restoreChipKey = Key('discord_orb_restore_chip');

  final PreviewRepository previewRepository;
  final OrbWindowController windowController;
  final String? guildId;
  final String? channelId;
  final String? channelName;
  final String? guildName;
  final OrbShellController? controller;
  final Size orbSize;
  final Size panelSize;
  final Offset? initialOrbOffset;
  final EdgeInsets safePadding;
  final bool showRestoreChipWhenHidden;
  final VoidCallback? onReauthenticate;
  final VoidCallback? onReselectChannel;

  @override
  State<OrbShell> createState() => OrbShellState();
}

class OrbShellState extends State<OrbShell> with WidgetsBindingObserver {
  StreamSubscription<void>? _lockSubscription;
  StreamSubscription<void>? _dismissSubscription;

  Offset? _orbOffset;
  bool _isOrbHidden = false;
  bool _isPanelOpen = false;
  OrbPreviewState _previewState = OrbPreviewState.idle;
  List<ChannelMessagePreview> _messages = const <ChannelMessagePreview>[];
  OrbException? _error;
  Object? _activeRequestToken;

  bool get isPanelOpen => _isPanelOpen;
  bool get isOrbHidden => _isOrbHidden;
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribeFromWindowEvents();
    widget.controller?._detach(this);
    _activeRequestToken = null;
    _messages = const <ChannelMessagePreview>[];
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
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

  Size _expandedWindowTargetSize() {
    return Size(
      widget.panelSize.width + 32,
      widget.panelSize.height + widget.orbSize.height + 120,
    );
  }

  bool _needsWindowExpansion(Size viewportSize, EdgeInsets safePadding) {
    final availableWidth =
        viewportSize.width - safePadding.left - safePadding.right;
    final availableHeight =
        viewportSize.height - safePadding.top - safePadding.bottom;
    return _isCollapsedOverlayViewport(viewportSize) ||
        availableWidth < widget.panelSize.width ||
        availableHeight < widget.panelSize.height;
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
    final raw = _orbOffset ??
        Offset(
          viewportSize.width - safePadding.right - widget.orbSize.width - 16,
          safePadding.top + 16,
        );
    return clampOrbOffset(
      offset: raw,
      orbSize: widget.orbSize,
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
      panelSize: widget.panelSize,
      viewportSize: viewportSize,
      safePadding: safePadding,
    );

    _openAndFetch(placement.rect.size);
  }

  void _openAndFetch(Size targetPanelSize) {
    final requestToken = Object();
    setState(() {
      _isPanelOpen = true;
      _previewState = OrbPreviewState.loading;
      _messages = const <ChannelMessagePreview>[];
      _error = null;
      _activeRequestToken = requestToken;
    });

    unawaited(widget.windowController.expandPanel(targetPanelSize));
    _fetchWithToken(requestToken);
  }

  void _retryFetch() {
    if (!_isPanelOpen) {
      return;
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

  /// Closes the panel if open, invalidates any in-flight request, and wipes
  /// all in-memory preview messages.
  void closeAndClear() {
    final wasOpen = _isPanelOpen;
    _activeRequestToken = null;
    widget.previewRepository.clearMemory();
    widget.previewRepository.cancelActivePreview();
    if (wasOpen) {
      unawaited(widget.windowController.collapsePanel());
    }
    if (!mounted) {
      _isPanelOpen = false;
      _previewState = OrbPreviewState.idle;
      _messages = const <ChannelMessagePreview>[];
      _error = null;
      return;
    }
    if (wasOpen ||
        _messages.isNotEmpty ||
        _previewState != OrbPreviewState.idle ||
        _error != null) {
      setState(() {
        _isPanelOpen = false;
        _previewState = OrbPreviewState.idle;
        _messages = const <ChannelMessagePreview>[];
        _error = null;
      });
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
    if (_isCollapsedOverlayViewport(viewportSize)) {
      unawaited(widget.windowController.startOrbDrag());
    }
  }

  void _handleDragDelta(
    Offset delta,
    Size viewportSize,
    EdgeInsets safePadding,
  ) {
    if (_isCollapsedOverlayViewport(viewportSize)) {
      // Collapsed desktop overlay windows use native OS drag started on pan start.
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
        final orbRect = orbOffset & widget.orbSize;
        final placement = computePanelRect(
          orbRect: orbRect,
          panelSize: widget.panelSize,
          viewportSize: viewportSize,
          safePadding: safePadding,
        );
        final canRenderPanel =
            placement.rect.width >= 180 && placement.rect.height >= 160;

        return Stack(
          children: <Widget>[
            if (_isPanelOpen && canRenderPanel)
              Positioned.fromRect(
                rect: placement.rect,
                child: MessagePanel(
                  state: _previewState,
                  messages: _messages,
                  channelName: widget.channelName,
                  guildName: widget.guildName,
                  error: _error,
                  onClose: closeAndClear,
                  onRetry: _retryFetch,
                  onReauthenticate: widget.onReauthenticate,
                  onReselectChannel: widget.onReselectChannel,
                ),
              ),
            Positioned(
              left: orbOffset.dx,
              top: orbOffset.dy,
              child: OrbButton(
                isPanelOpen: _isPanelOpen,
                size: widget.orbSize,
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
