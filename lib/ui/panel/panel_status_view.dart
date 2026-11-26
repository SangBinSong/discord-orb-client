import 'package:flutter/material.dart';

import '../../models/orb_error.dart';

/// Distinct non-loaded status view for the Discord Orb message panel.
class PanelStatusView extends StatelessWidget {
  const PanelStatusView({
    super.key,
    required this.state,
    this.error,
    this.onRetry,
    this.onReauthenticate,
    this.onReselectChannel,
  });

  static const Key loadingIndicatorKey = Key('panel_status_loading_indicator');
  static const Key retryButtonKey = Key('panel_status_retry_button');
  static const Key reauthenticateButtonKey =
      Key('panel_status_reauthenticate_button');
  static const Key reselectChannelButtonKey =
      Key('panel_status_reselect_channel_button');

  final OrbPreviewState state;
  final OrbException? error;
  final VoidCallback? onRetry;
  final VoidCallback? onReauthenticate;
  final VoidCallback? onReselectChannel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (state == OrbPreviewState.loading) {
      return Center(
        child: Semantics(
          label: 'Loading messages',
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              key: loadingIndicatorKey,
              strokeWidth: 2.2,
              color: colorScheme.primary.withValues(alpha: 0.78),
            ),
          ),
        ),
      );
    }

    final _StatusDescriptor descriptor = _describeState(colorScheme);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              descriptor.icon,
              size: 32,
              color: descriptor.iconColor,
            ),
            const SizedBox(height: 12),
            Text(
              descriptor.title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              descriptor.description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (descriptor.actionLabel != null &&
                descriptor.onAction != null) ...<Widget>[
              const SizedBox(height: 14),
              FilledButton.tonal(
                key: descriptor.actionKey,
                onPressed: descriptor.onAction,
                child: Text(descriptor.actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }

  _StatusDescriptor _describeState(ColorScheme colorScheme) {
    switch (state) {
      case OrbPreviewState.emptyChannel:
        return _StatusDescriptor(
          icon: Icons.chat_bubble_outline,
          iconColor: colorScheme.onSurfaceVariant,
          title: 'Channel is empty',
          description: 'No text messages are available in this channel yet.',
        );
      case OrbPreviewState.sessionExpired:
        return _StatusDescriptor(
          icon: Icons.lock_reset_outlined,
          iconColor: colorScheme.error,
          title: 'Session expired',
          description:
              'Your Discord session expired or was revoked. Sign in again to continue.',
          actionLabel: 'Sign in again',
          actionKey: reauthenticateButtonKey,
          onAction: onReauthenticate,
        );
      case OrbPreviewState.accessDenied:
        return _StatusDescriptor(
          icon: Icons.block_outlined,
          iconColor: colorScheme.error,
          title: 'Channel access denied',
          description:
              'You or the bot no longer have permission to read this channel.',
          actionLabel: 'Choose another channel',
          actionKey: reselectChannelButtonKey,
          onAction: onReselectChannel,
        );
      case OrbPreviewState.botUnavailable:
        return _StatusDescriptor(
          icon: Icons.smart_toy_outlined,
          iconColor: colorScheme.tertiary,
          title: 'Bot unavailable',
          description:
              'The Discord bot is not configured or is currently disabled on the backend.',
        );
      case OrbPreviewState.rateLimited:
        final retrySeconds = error?.retryAfter?.inSeconds;
        final retryNote = retrySeconds != null && retrySeconds > 0
            ? ' Try again in ${retrySeconds}s.'
            : ' Please wait a moment before retrying.';
        return _StatusDescriptor(
          icon: Icons.speed_outlined,
          iconColor: colorScheme.tertiary,
          title: 'Rate limited',
          description: 'Too many preview requests.$retryNote',
          actionLabel: 'Retry',
          actionKey: retryButtonKey,
          onAction: onRetry,
        );
      case OrbPreviewState.networkError:
        return _StatusDescriptor(
          icon: Icons.wifi_off_outlined,
          iconColor: colorScheme.error,
          title: 'Connection error',
          description: (error?.message.isNotEmpty ?? false)
              ? error!.message
              : 'Could not load messages from the backend.',
          actionLabel: 'Retry',
          actionKey: retryButtonKey,
          onAction: onRetry,
        );
      case OrbPreviewState.idle:
      case OrbPreviewState.loading:
      case OrbPreviewState.loaded:
        return _StatusDescriptor(
          icon: Icons.info_outline,
          iconColor: colorScheme.onSurfaceVariant,
          title: 'Preview ready',
          description: 'Tap the orb to load the latest messages.',
        );
    }
  }
}

class _StatusDescriptor {
  const _StatusDescriptor({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    this.actionLabel,
    this.actionKey,
    this.onAction,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;
}
