import 'package:flutter/material.dart';

import 'aurora_orb_painter.dart';

/// Floating circular Aurora Nebula Glass orb button supporting tap toggle,
/// drag movement, long-press hide, and collapsed unread message badge.
class OrbButton extends StatefulWidget {
  const OrbButton({
    super.key,
    required this.isPanelOpen,
    required this.onTap,
    this.size = const Size(56, 56),
    this.unreadCount = 0,
    this.showTooltip = true,
    this.animate = true,
    this.onDragStart,
    this.onDragDelta,
    this.onHideRequested,
  });

  static const Key orbButtonKey = Key('discord_orb_button');
  static const Key unreadBadgeKey = Key('orb_unread_badge');
  static const Key auroraPaintKey = Key('orb_aurora_sphere_paint');

  final bool isPanelOpen;
  final VoidCallback onTap;
  final Size size;
  final int unreadCount;
  final bool showTooltip;
  final bool animate;
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragDelta;
  final VoidCallback? onHideRequested;

  @override
  State<OrbButton> createState() => _OrbButtonState();
}

class _OrbButtonState extends State<OrbButton> with TickerProviderStateMixin {
  static const Duration _auroraCycleDuration = Duration(seconds: 9);
  static const Duration _stateTransitionDuration = Duration(milliseconds: 220);

  late final AnimationController _auroraController;
  late final AnimationController _openController;
  late final AnimationController _unreadController;
  late final Listenable _repaintListenable;

  bool get _hasUnread => !widget.isPanelOpen && widget.unreadCount > 0;

  @override
  void initState() {
    super.initState();
    _auroraController = AnimationController(
      vsync: this,
      duration: _auroraCycleDuration,
      value: 0.15,
    );
    _openController = AnimationController(
      vsync: this,
      duration: _stateTransitionDuration,
      value: widget.isPanelOpen ? 1.0 : 0.0,
    );
    _unreadController = AnimationController(
      vsync: this,
      duration: _stateTransitionDuration,
      value: _hasUnread ? 1.0 : 0.0,
    );
    _repaintListenable = Listenable.merge(<Listenable>[
      _auroraController,
      _openController,
      _unreadController,
    ]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAuroraAnimation();
  }

  @override
  void didUpdateWidget(covariant OrbButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAuroraAnimation();

    if (oldWidget.isPanelOpen != widget.isPanelOpen) {
      if (_shouldAnimate()) {
        if (widget.isPanelOpen) {
          _openController.forward();
        } else {
          _openController.reverse();
        }
      } else {
        _openController.value = widget.isPanelOpen ? 1.0 : 0.0;
      }
    }

    final wasUnread = !oldWidget.isPanelOpen && oldWidget.unreadCount > 0;
    if (wasUnread != _hasUnread) {
      if (_shouldAnimate()) {
        if (_hasUnread) {
          _unreadController.forward();
        } else {
          _unreadController.reverse();
        }
      } else {
        _unreadController.value = _hasUnread ? 1.0 : 0.0;
      }
    }
  }

  bool _shouldAnimate() {
    if (!widget.animate) {
      return false;
    }
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disableAnimations) {
      return false;
    }
    return TickerMode.valuesOf(context).enabled;
  }

  void _syncAuroraAnimation() {
    if (_shouldAnimate()) {
      if (!_auroraController.isAnimating) {
        _auroraController.repeat();
      }
    } else {
      if (_auroraController.isAnimating) {
        _auroraController.stop(canceled: false);
      }
    }
  }

  @override
  void dispose() {
    _auroraController.dispose();
    _openController.dispose();
    _unreadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final showUnreadBadge = _hasUnread;
    final badgeText = widget.unreadCount > 99 ? '99+' : '${widget.unreadCount}';

    final Widget orbSphere = RepaintBoundary(
      child: SizedBox(
        width: widget.size.width,
        height: widget.size.height,
        child: AnimatedBuilder(
          animation: _repaintListenable,
          builder: (BuildContext context, Widget? child) {
            return CustomPaint(
              key: OrbButton.auroraPaintKey,
              size: widget.size,
              painter: AuroraOrbPainter(
                phase: _auroraController.value,
                isPanelOpen: widget.isPanelOpen,
                hasUnread: showUnreadBadge,
                openProgress: Curves.easeOutCubic.transform(_openController.value),
                unreadProgress:
                    Curves.easeOutCubic.transform(_unreadController.value),
              ),
              child: child,
            );
          },
          // Pure Sphere when collapsed (no center icon); crisp white X when open.
          child: widget.isPanelOpen
              ? const Center(
                  child: Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 22,
                    shadows: <Shadow>[
                      Shadow(
                        color: Color(0x88070818),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                )
              : null,
        ),
      ),
    );

    final Widget button = GestureDetector(
      key: OrbButton.orbButtonKey,
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onPanStart: widget.onDragStart == null
          ? null
          : (DragStartDetails _) => widget.onDragStart!(),
      onPanUpdate: widget.onDragDelta == null
          ? null
          : (DragUpdateDetails details) => widget.onDragDelta!(details.delta),
      onLongPress: widget.onHideRequested,
      child: SizedBox(
        width: widget.size.width,
        height: widget.size.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            orbSphere,
            if (showUnreadBadge)
              Positioned(
                top: -4,
                right: -4,
                child: IgnorePointer(
                  child: Semantics(
                    label: '$badgeText unread messages',
                    child: Container(
                      key: OrbButton.unreadBadgeKey,
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFED4245),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: colorScheme.surface,
                          width: 1.5,
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          badgeText,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Semantics(
      button: true,
      label: widget.isPanelOpen
          ? 'Close Discord Orb panel'
          : 'Open Discord Orb panel',
      child: widget.showTooltip
          ? Tooltip(
              message: widget.isPanelOpen
                  ? 'Tap to close preview'
                  : 'Tap to preview messages (hold to hide)',
              child: button,
            )
          : button,
    );
  }
}
