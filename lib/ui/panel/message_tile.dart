import 'package:flutter/material.dart';

import '../../models/message_models.dart';

/// Read-only tile displaying a single text-only Discord message preview.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
  });

  final ChannelMessagePreview message;

  static String formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final now = DateTime.now();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final timePart = '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
    final isSameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (isSameDay) {
      return timePart;
    }
    return '${twoDigits(local.month)}/${twoDigits(local.day)} $timePart';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
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
              const SizedBox(width: 8),
              Text(
                formatTimestamp(message.timestamp),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            message.content,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
