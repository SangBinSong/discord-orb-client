import 'package:flutter/material.dart';

import '../../models/message_models.dart';
import '../../models/orb_error.dart';
import 'message_tile.dart';
import 'panel_status_view.dart';

/// Read-only floating preview panel showing up to 10 newest messages or a
/// distinct status view.
class MessagePanel extends StatelessWidget {
  const MessagePanel({
    super.key,
    required this.state,
    required this.messages,
    this.channelName,
    this.guildName,
    this.error,
    this.onClose,
    this.onRetry,
    this.onReauthenticate,
    this.onReselectChannel,
  });

  static const int maxVisibleMessages = 10;
  static const Key closeButtonKey = Key('message_panel_close_button');
  static const Key messageListKey = Key('message_panel_list');

  final OrbPreviewState state;
  final List<ChannelMessagePreview> messages;
  final String? channelName;
  final String? guildName;
  final OrbException? error;
  final VoidCallback? onClose;
  final VoidCallback? onRetry;
  final VoidCallback? onReauthenticate;
  final VoidCallback? onReselectChannel;

  /// Returns up to [maxVisibleMessages] messages ordered newest-first.
  static List<ChannelMessagePreview> selectNewestMessages(
    List<ChannelMessagePreview> source,
  ) {
    if (source.isEmpty) {
      return const <ChannelMessagePreview>[];
    }
    final indexed = source.indexed.toList(growable: false);
    indexed.sort(((int, ChannelMessagePreview) a, (int, ChannelMessagePreview) b) {
      final timeCmp = b.$2.timestamp.toUtc().compareTo(a.$2.timestamp.toUtc());
      if (timeCmp != 0) {
        return timeCmp;
      }
      return a.$1.compareTo(b.$1);
    });
    return indexed
        .take(maxVisibleMessages)
        .map(((int, ChannelMessagePreview) entry) => entry.$2)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final visibleMessages = state == OrbPreviewState.loaded
        ? selectNewestMessages(messages)
        : const <ChannelMessagePreview>[];
    final effectiveState =
        state == OrbPreviewState.loaded && visibleMessages.isEmpty
            ? OrbPreviewState.emptyChannel
            : state;

    return Material(
      elevation: 10,
      color: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeader(
            channelName: channelName,
            guildName: guildName,
            onClose: onClose,
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
          Expanded(
            child: effectiveState == OrbPreviewState.loaded
                ? ListView.separated(
                    key: messageListKey,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: visibleMessages.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        Divider(
                      height: 1,
                      thickness: 0.5,
                      indent: 12,
                      endIndent: 12,
                      color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                    itemBuilder: (BuildContext context, int index) {
                      return MessageTile(message: visibleMessages[index]);
                    },
                  )
                : PanelStatusView(
                    state: effectiveState,
                    error: error,
                    onRetry: onRetry,
                    onReauthenticate: onReauthenticate,
                    onReselectChannel: onReselectChannel,
                  ),
          ),
        ],
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    this.channelName,
    this.guildName,
    this.onClose,
  });

  final String? channelName;
  final String? guildName;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final titleText = (channelName != null && channelName!.isNotEmpty)
        ? '#$channelName'
        : 'Channel Preview';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.tag,
            size: 18,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  titleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (guildName != null && guildName!.isNotEmpty)
                  Text(
                    guildName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              key: MessagePanel.closeButtonKey,
              tooltip: 'Close preview',
              icon: const Icon(Icons.close, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
