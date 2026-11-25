import 'package:flutter/material.dart';

import '../../models/message_models.dart';
import '../common/orb_avatar.dart';

/// Read-only tile displaying a single text-only Discord message preview.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    this.layout = ChatListLayout.standard,
  });

  final ChannelMessagePreview message;
  final ChatListLayout layout;

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

  /// Flattens multi-line message text into a single compact line.
  static String compactContent(String content) {
    return content.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final formattedTime = formatTimestamp(message.timestamp);

    if (layout == ChatListLayout.compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          children: <Widget>[
            OrbAvatar(
              name: message.authorName,
              imageUrl: message.authorAvatarUrl,
              size: 18,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
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
                compactContent(message.content),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              formattedTime,
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: OrbAvatar(
              name: message.authorName,
              imageUrl: message.authorAvatarUrl,
              size: 24,
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
                      formattedTime,
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
          ),
        ],
      ),
    );
  }
}
