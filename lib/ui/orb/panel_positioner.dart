import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Vertical placement of the preview panel relative to the floating orb.
enum PanelPlacementDirection {
  below,
  above,
}

/// Computed screen placement for the preview panel.
class PanelPlacement {
  const PanelPlacement({
    required this.rect,
    required this.direction,
  });

  final Rect rect;
  final PanelPlacementDirection direction;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PanelPlacement &&
        other.rect == rect &&
        other.direction == direction;
  }

  @override
  int get hashCode => Object.hash(rect, direction);

  @override
  String toString() => 'PanelPlacement(rect: $rect, direction: $direction)';
}

/// Computes the panel [Rect] and placement direction ([below] or [above])
/// relative to [orbRect] within [viewportSize] and [safePadding].
///
/// Defaults to placing the panel below the orb. If there is insufficient
/// vertical space below, it flips above the orb. Both horizontal and vertical
/// coordinates are clamped inside the safe viewport bounds.
PanelPlacement computePanelRect({
  required Rect orbRect,
  required Size panelSize,
  required Size viewportSize,
  EdgeInsets safePadding = EdgeInsets.zero,
  double gap = 8.0,
}) {
  final minLeft = safePadding.left;
  final maxRight = math.max(minLeft, viewportSize.width - safePadding.right);
  final minTop = safePadding.top;
  final maxBottom = math.max(minTop, viewportSize.height - safePadding.bottom);

  final availableWidth = math.max(0.0, maxRight - minLeft);
  final availableHeight = math.max(0.0, maxBottom - minTop);

  final effectiveWidth = math.min(math.max(0.0, panelSize.width), availableWidth);
  final effectiveHeight =
      math.min(math.max(0.0, panelSize.height), availableHeight);

  final belowTop = orbRect.bottom + gap;
  final aboveTop = orbRect.top - gap - effectiveHeight;

  final fitsBelow = belowTop + effectiveHeight <= maxBottom;
  final fitsAbove = aboveTop >= minTop;
  final spaceBelow = maxBottom - orbRect.bottom;
  final spaceAbove = orbRect.top - minTop;

  final PanelPlacementDirection direction;
  final double rawTop;
  if (fitsBelow) {
    direction = PanelPlacementDirection.below;
    rawTop = belowTop;
  } else if (fitsAbove || spaceAbove > spaceBelow) {
    direction = PanelPlacementDirection.above;
    rawTop = aboveTop;
  } else {
    direction = PanelPlacementDirection.below;
    rawTop = belowTop;
  }

  final idealLeft = orbRect.center.dx - (effectiveWidth / 2);
  final maxLeft = math.max(minLeft, maxRight - effectiveWidth);
  final maxTop = math.max(minTop, maxBottom - effectiveHeight);

  final clampedLeft = idealLeft.clamp(minLeft, maxLeft).toDouble();
  final clampedTop = rawTop.clamp(minTop, maxTop).toDouble();

  return PanelPlacement(
    rect: Rect.fromLTWH(clampedLeft, clampedTop, effectiveWidth, effectiveHeight),
    direction: direction,
  );
}

/// Clamps the floating orb's top-left [offset] so [orbSize] stays within
/// [viewportSize] inset by [safePadding].
Offset clampOrbOffset({
  required Offset offset,
  required Size orbSize,
  required Size viewportSize,
  EdgeInsets safePadding = EdgeInsets.zero,
}) {
  final minLeft = safePadding.left;
  final minTop = safePadding.top;
  final maxLeft =
      math.max(minLeft, viewportSize.width - safePadding.right - orbSize.width);
  final maxTop = math.max(
    minTop,
    viewportSize.height - safePadding.bottom - orbSize.height,
  );

  return Offset(
    offset.dx.clamp(minLeft, maxLeft).toDouble(),
    offset.dy.clamp(minTop, maxTop).toDouble(),
  );
}
