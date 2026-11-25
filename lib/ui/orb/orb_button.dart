import 'package:flutter/material.dart';

/// Floating circular orb button supporting tap toggle, drag movement, and
/// long-press hide.
class OrbButton extends StatelessWidget {
  const OrbButton({
    super.key,
    required this.isPanelOpen,
    required this.onTap,
    this.size = const Size(56, 56),
    this.showTooltip = true,
    this.onDragStart,
    this.onDragDelta,
    this.onHideRequested,
  });

  static const Key orbButtonKey = Key('discord_orb_button');

  final bool isPanelOpen;
  final VoidCallback onTap;
  final Size size;
  final bool showTooltip;
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragDelta;
  final VoidCallback? onHideRequested;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Widget button = GestureDetector(
      key: orbButtonKey,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onPanStart: onDragStart == null
          ? null
          : (DragStartDetails _) => onDragStart!(),
      onPanUpdate: onDragDelta == null
          ? null
          : (DragUpdateDetails details) => onDragDelta!(details.delta),
      onLongPress: onHideRequested,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPanelOpen
              ? colorScheme.primaryContainer
              : colorScheme.primary,
          border: Border.all(
            color: isPanelOpen
                ? colorScheme.primary
                : colorScheme.onPrimary.withValues(alpha: 0.25),
            width: isPanelOpen ? 2.5 : 1.5,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            isPanelOpen ? Icons.close : Icons.forum_rounded,
            color: isPanelOpen
                ? colorScheme.onPrimaryContainer
                : colorScheme.onPrimary,
            size: 24,
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: isPanelOpen ? 'Close Discord Orb panel' : 'Open Discord Orb panel',
      child: showTooltip
          ? Tooltip(
              message: isPanelOpen
                  ? 'Tap to close preview'
                  : 'Tap to preview messages (hold to hide)',
              child: button,
            )
          : button,
    );
  }
}
