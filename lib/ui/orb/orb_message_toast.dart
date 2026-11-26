import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/message_models.dart';
import '../common/orb_avatar.dart';
import '../panel/message_tile.dart';
import 'panel_positioner.dart';

/// Compact floating toast bubble displayed next to the collapsed orb when a
/// new real-time channel message arrives.
class OrbMessageToast extends StatelessWidget {
  const OrbMessageToast({
    super.key,
    required this.message,
    required this.onTap,
    required this.onDismiss,
    this.channelName,
    this.layout = ChatListLayout.standard,
    this.cardKey,
    this.dismissKey,
  });

  static const Key toastCardKey = Key('discord_orb_message_toast');
  static const Key dismissButtonKey = Key('discord_orb_toast_dismiss_button');

  static Key cardKeyFor(String messageId) =>
      Key('discord_orb_message_toast_$messageId');
  static Key dismissButtonKeyFor(String messageId) =>
      Key('discord_orb_toast_dismiss_$messageId');

  final ChannelMessagePreview message;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  final String? channelName;
  final ChatListLayout layout;
  final Key? cardKey;
  final Key? dismissKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isCompact = layout == ChatListLayout.compact;
    final compactBody = isCompact
        ? message.content.replaceAll(RegExp(r'\s+'), ' ').trim()
        : MessageTile.compactContent(message.content);
    final hasChannelName = channelName != null && channelName!.isNotEmpty;

    return Semantics(
      container: true,
      button: true,
      label: 'New message from ${message.authorName}: $compactBody',
      hint: 'Tap to open channel preview',
      child: Material(
        key: cardKey ?? toastCardKey,
        elevation: 8,
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isCompact ? 11 : 14),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: isCompact
              ? _buildCompactBody(theme, colorScheme, compactBody)
              : _buildStandardBody(
                  theme,
                  colorScheme,
                  compactBody,
                  hasChannelName,
                ),
        ),
      ),
    );
  }

  Widget _buildCompactBody(
    ThemeData theme,
    ColorScheme colorScheme,
    String compactBody,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
      child: Row(
        children: <Widget>[
          OrbAvatar(
            name: message.authorName,
            imageUrl: message.authorAvatarUrl,
            size: 20,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 82),
            child: Text(
              message.authorName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              compactBody,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 2),
          SizedBox(
            width: 24,
            height: 24,
            child: IconButton(
              key: dismissKey ?? dismissButtonKey,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(
                width: 24,
                height: 24,
              ),
              iconSize: 15,
              tooltip: 'Dismiss notification',
              icon: Icon(
                Icons.close,
                color: colorScheme.onSurfaceVariant,
              ),
              onPressed: onDismiss,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStandardBody(
    ThemeData theme,
    ColorScheme colorScheme,
    String compactBody,
    bool hasChannelName,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: OrbAvatar(
              name: message.authorName,
              imageUrl: message.authorAvatarUrl,
              size: 28,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        message.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                    if (hasChannelName) ...<Widget>[
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '#$channelName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  compactBody,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              key: dismissKey ?? dismissButtonKey,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(
                width: 28,
                height: 28,
              ),
              iconSize: 16,
              tooltip: 'Dismiss notification',
              icon: Icon(
                Icons.close,
                color: colorScheme.onSurfaceVariant,
              ),
              onPressed: onDismiss,
            ),
          ),
        ],
      ),
    );
  }
}

/// Multi-card floating toast stack with up to 3 tucked card-back overflow
/// layers and a clean unclipped `+N more` badge when more than
/// [maxVisibleCount] messages are queued.
class OrbMessageToastStack extends StatelessWidget {
  const OrbMessageToastStack({
    super.key,
    required this.messages,
    required this.maxVisibleCount,
    required this.onTapStack,
    required this.onDismissMessage,
    this.direction = PanelPlacementDirection.below,
    this.layout = ChatListLayout.standard,
    this.channelName,
  });

  static const Key stackKey = Key('discord_orb_toast_stack');
  static const Key overflowBadgeKey = Key('discord_orb_toast_overflow_badge');
  static Key overflowLayerKey(int index) =>
      Key('discord_orb_toast_overflow_layer_$index');

  static const int maxOverflowLayers = 3;
  static const double cardSpacing = 6.0;
  static const double estimatedCardHeight = 68.0;
  static const double estimatedCompactCardHeight = 40.0;
  static const double overflowStepHeight = 6.0;
  static const double overflowInsetPerDepth = 6.0;
  static const double overflowBadgeRowHeight = 24.0;

  /// Estimates the vertical height needed to display [visibleCount] cards and
  /// up to [maxOverflowLayers] tucked overflow layers without clipping.
  static double estimateHeight({
    required int visibleCount,
    bool hasOverflow = false,
    int overflowCount = 0,
    bool compact = false,
  }) {
    if (visibleCount <= 0) {
      return 0.0;
    }
    final effectiveOverflow =
        overflowCount > 0 ? overflowCount : (hasOverflow ? 1 : 0);
    final cardH = compact ? estimatedCompactCardHeight : estimatedCardHeight;
    final cardsHeight =
        (visibleCount * cardH) + (math.max(0, visibleCount - 1) * cardSpacing);
    final layerCount = math.min(maxOverflowLayers, effectiveOverflow);
    final overflowHeight = layerCount > 0
        ? (layerCount * overflowStepHeight) + overflowBadgeRowHeight
        : 0.0;
    return cardsHeight + overflowHeight;
  }

  final List<ChannelMessagePreview> messages;
  final int maxVisibleCount;
  final VoidCallback onTapStack;
  final ValueChanged<String> onDismissMessage;
  final PanelPlacementDirection direction;
  final ChatListLayout layout;
  final String? channelName;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const SizedBox.shrink();
    }
    final clampedMax = maxVisibleCount.clamp(1, 5);
    final visible = messages.take(clampedMax).toList(growable: false);
    final overflowCount = math.max(0, messages.length - visible.length);
    final isAbove = direction == PanelPlacementDirection.above;
    final isCompact = layout == ChatListLayout.compact;

    // Order cards so the newest message (index 0) sits closest to the orb.
    final orderedVisible = isAbove ? visible.reversed.toList() : visible;
    final deckTargetIndex = isAbove ? 0 : (orderedVisible.length - 1);

    final children = <Widget>[];
    if (isAbove && overflowCount > 0) {
      children.add(
        _OverflowBadgeRow(
          overflowCount: overflowCount,
          isAbove: true,
          onTap: onTapStack,
        ),
      );
    }

    for (var i = 0; i < orderedVisible.length; i++) {
      final msg = orderedVisible[i];
      final isNewestCard = msg.id == visible.first.id;
      if (i > 0) {
        children.add(const SizedBox(height: cardSpacing));
      }

      Widget card = OrbMessageToast(
        key: ValueKey<String>(msg.id),
        message: msg,
        channelName: channelName,
        layout: layout,
        cardKey: isNewestCard && visible.length == 1
            ? OrbMessageToast.toastCardKey
            : OrbMessageToast.cardKeyFor(msg.id),
        dismissKey: isNewestCard && visible.length == 1
            ? OrbMessageToast.dismissButtonKey
            : OrbMessageToast.dismissButtonKeyFor(msg.id),
        onTap: onTapStack,
        onDismiss: () => onDismissMessage(msg.id),
      );

      if (overflowCount > 0 && i == deckTargetIndex) {
        card = _StackedOverflowCardShell(
          overflowCount: overflowCount,
          isAbove: isAbove,
          isCompact: isCompact,
          frontCard: card,
        );
      }

      children.add(card);
    }

    if (!isAbove && overflowCount > 0) {
      children.add(
        _OverflowBadgeRow(
          overflowCount: overflowCount,
          isAbove: false,
          onTap: onTapStack,
        ),
      );
    }

    return Column(
      key: stackKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Renders up to [OrbMessageToastStack.maxOverflowLayers] rounded card-back
/// shells tucked neatly behind [frontCard] with progressive inset & peek.
class _StackedOverflowCardShell extends StatelessWidget {
  const _StackedOverflowCardShell({
    required this.overflowCount,
    required this.isAbove,
    required this.isCompact,
    required this.frontCard,
  });

  final int overflowCount;
  final bool isAbove;
  final bool isCompact;
  final Widget frontCard;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final layerCount =
        math.min(OrbMessageToastStack.maxOverflowLayers, overflowCount);
    final totalPeek = layerCount * OrbMessageToastStack.overflowStepHeight;
    final radius = isCompact ? 11.0 : 14.0;

    final layerFills = <Color>[
      colorScheme.surfaceContainer,
      colorScheme.surfaceContainerLow,
      colorScheme.surfaceContainerLowest,
    ];
    final layerBorderAlphas = <double>[0.52, 0.40, 0.30];

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        for (int depth = layerCount; depth >= 1; depth--)
          Positioned(
            left: depth * OrbMessageToastStack.overflowInsetPerDepth,
            right: depth * OrbMessageToastStack.overflowInsetPerDepth,
            top: isAbove
                ? (layerCount - depth) * OrbMessageToastStack.overflowStepHeight
                : depth * OrbMessageToastStack.overflowStepHeight,
            bottom: isAbove
                ? depth * OrbMessageToastStack.overflowStepHeight
                : (layerCount - depth) *
                    OrbMessageToastStack.overflowStepHeight,
            child: IgnorePointer(
              child: DecoratedBox(
                key: OrbMessageToastStack.overflowLayerKey(depth - 1),
                decoration: BoxDecoration(
                  color: layerFills[depth - 1],
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: colorScheme.outlineVariant
                        .withValues(alpha: layerBorderAlphas[depth - 1]),
                    width: 0.9,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(
            top: isAbove ? totalPeek : 0,
            bottom: isAbove ? 0 : totalPeek,
          ),
          child: frontCard,
        ),
      ],
    );
  }
}

class _OverflowBadgeRow extends StatelessWidget {
  const _OverflowBadgeRow({
    required this.overflowCount,
    required this.isAbove,
    required this.onTap,
  });

  final int overflowCount;
  final bool isAbove;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(
          top: isAbove ? 0 : 4,
          bottom: isAbove ? 4 : 0,
          right: 4,
        ),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            key: OrbMessageToastStack.overflowBadgeKey,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: colorScheme.primary.withValues(alpha: 0.35),
                width: 0.8,
              ),
            ),
            child: Text(
              '+$overflowCount more',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
