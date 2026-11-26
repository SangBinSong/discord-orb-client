import 'package:flutter/material.dart';

import '../../models/message_models.dart';
import '../../models/orb_error.dart';
import '../common/orb_avatar.dart';
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
    this.guildIconUrl,
    this.layout = ChatListLayout.standard,
    this.onLayoutChanged,
    this.isPinned = true,
    this.onPinnedChanged,
    this.toastNotificationsEnabled = true,
    this.onToastNotificationsChanged,
    this.error,
    this.onClose,
    this.onRetry,
    this.onReauthenticate,
    this.onReselectChannel,
  });

  static const int maxVisibleMessages = 10;
  static const Key closeButtonKey = Key('message_panel_close_button');
  static const Key pinToggleButtonKey = Key('message_panel_pin_toggle_button');
  static const Key toastToggleButtonKey =
      Key('message_panel_toast_toggle_button');
  static const Key layoutToggleButtonKey =
      Key('message_panel_layout_toggle_button');
  static const Key messageListKey = Key('message_panel_list');

  final OrbPreviewState state;
  final List<ChannelMessagePreview> messages;
  final String? channelName;
  final String? guildName;
  final String? guildIconUrl;
  final ChatListLayout layout;
  final ValueChanged<ChatListLayout>? onLayoutChanged;
  final bool isPinned;
  final ValueChanged<bool>? onPinnedChanged;
  final bool toastNotificationsEnabled;
  final ValueChanged<bool>? onToastNotificationsChanged;
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
            guildIconUrl: guildIconUrl,
            layout: layout,
            onLayoutChanged: onLayoutChanged,
            isPinned: isPinned,
            onPinnedChanged: onPinnedChanged,
            toastNotificationsEnabled: toastNotificationsEnabled,
            onToastNotificationsChanged: onToastNotificationsChanged,
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
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 14),
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
                      return MessageTile(
                        message: visibleMessages[index],
                        layout: layout,
                      );
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
    this.guildIconUrl,
    required this.layout,
    this.onLayoutChanged,
    required this.isPinned,
    this.onPinnedChanged,
    required this.toastNotificationsEnabled,
    this.onToastNotificationsChanged,
    this.onClose,
  });

  final String? channelName;
  final String? guildName;
  final String? guildIconUrl;
  final ChatListLayout layout;
  final ValueChanged<ChatListLayout>? onLayoutChanged;
  final bool isPinned;
  final ValueChanged<bool>? onPinnedChanged;
  final bool toastNotificationsEnabled;
  final ValueChanged<bool>? onToastNotificationsChanged;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final titleText = (channelName != null && channelName!.isNotEmpty)
        ? '#$channelName'
        : 'Channel Preview';
    final hasGuildBadge = (guildName != null && guildName!.isNotEmpty) ||
        (guildIconUrl != null && guildIconUrl!.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: <Widget>[
          if (hasGuildBadge)
            OrbAvatar(
              name: guildName ?? channelName ?? '#',
              imageUrl: guildIconUrl,
              size: 22,
            )
          else
            Icon(
              Icons.tag,
              size: 18,
              color: colorScheme.primary,
            ),
          const SizedBox(width: 8),
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
          if (onPinnedChanged != null)
            Semantics(
              toggled: isPinned,
              child: IconButton(
                key: MessagePanel.pinToggleButtonKey,
                tooltip: isPinned
                    ? 'Unpin panel (auto-close on focus loss)'
                    : 'Pin panel open',
                icon: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 18,
                  color: isPinned ? colorScheme.primary : null,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () => onPinnedChanged!(!isPinned),
              ),
            ),
          if (onToastNotificationsChanged != null)
            Semantics(
              toggled: toastNotificationsEnabled,
              child: IconButton(
                key: MessagePanel.toastToggleButtonKey,
                tooltip: toastNotificationsEnabled
                    ? 'Turn off toast popups'
                    : 'Turn on toast popups',
                icon: Icon(
                  toastNotificationsEnabled
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  size: 18,
                  color: toastNotificationsEnabled ? colorScheme.primary : null,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    onToastNotificationsChanged!(!toastNotificationsEnabled),
              ),
            ),
          if (onLayoutChanged != null)
            IconButton(
              key: MessagePanel.layoutToggleButtonKey,
              tooltip: layout == ChatListLayout.compact
                  ? 'Switch to standard layout'
                  : 'Switch to compact layout',
              icon: Icon(
                layout == ChatListLayout.compact
                    ? Icons.view_agenda_outlined
                    : Icons.view_headline_outlined,
                size: 18,
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () => onLayoutChanged!(
                layout == ChatListLayout.compact
                    ? ChatListLayout.standard
                    : ChatListLayout.compact,
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
