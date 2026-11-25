import 'package:flutter/material.dart';

import '../../contracts/preview_repository.dart';
import '../../models/channel_models.dart';
import '../../models/orb_error.dart';
import '../common/orb_avatar.dart';

/// Screen that loads and displays eligible Discord text channels grouped by guild.
class ChannelSelectScreen extends StatefulWidget {
  const ChannelSelectScreen({
    super.key,
    required this.previewRepository,
    required this.onChannelSelected,
    this.onSessionExpired,
    this.selectedChannel,
    this.onOpenSettings,
  });

  final PreviewRepository previewRepository;
  final ValueChanged<EligibleChannel> onChannelSelected;
  final VoidCallback? onSessionExpired;
  final EligibleChannel? selectedChannel;
  final VoidCallback? onOpenSettings;

  @override
  State<ChannelSelectScreen> createState() => _ChannelSelectScreenState();
}

class _ChannelSelectScreenState extends State<ChannelSelectScreen> {
  bool _isLoading = true;
  List<EligibleGuild> _guilds = const <EligibleGuild>[];
  OrbException? _orbError;
  String? _genericError;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    setState(() {
      _isLoading = true;
      _orbError = null;
      _genericError = null;
    });

    try {
      final guilds = await widget.previewRepository.fetchEligibleGuilds();
      if (!mounted) return;
      final nonEmptyGuilds = guilds
          .where((guild) => guild.channels.isNotEmpty)
          .toList(growable: false);
      setState(() {
        _isLoading = false;
        _guilds = nonEmptyGuilds;
      });
    } on OrbException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _orbError = error;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _genericError = 'Failed to load channels: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Channel'),
        actions: <Widget>[
          IconButton(
            key: const Key('channel_refresh_icon_button'),
            tooltip: 'Refresh channels',
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadChannels,
          ),
          if (widget.onOpenSettings != null)
            IconButton(
              key: const Key('channel_settings_icon_button'),
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: widget.onOpenSettings,
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(
              key: Key('channel_loading_indicator'),
            ),
            SizedBox(height: 12),
            Text('Loading eligible channels...'),
          ],
        ),
      );
    }

    if (_orbError != null) {
      final error = _orbError!;
      final isSessionExpired = error.state == OrbPreviewState.sessionExpired;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              key: const Key('channel_error_view'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  isSessionExpired
                      ? Icons.lock_clock_outlined
                      : Icons.error_outline,
                  size: 48,
                  color: colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  isSessionExpired
                      ? 'Session Expired'
                      : 'Unable to Load Channels',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  error.message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (isSessionExpired && widget.onSessionExpired != null) ...<Widget>[
                  FilledButton.icon(
                    key: const Key('channel_reauth_button'),
                    onPressed: widget.onSessionExpired,
                    icon: const Icon(Icons.login),
                    label: const Text('Sign in again'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('channel_retry_button'),
                    onPressed: _loadChannels,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ] else
                  FilledButton.icon(
                    key: const Key('channel_retry_button'),
                    onPressed: _loadChannels,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    if (_genericError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              key: const Key('channel_error_view'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.error_outline, size: 48, color: colorScheme.error),
                const SizedBox(height: 16),
                Text(
                  'Unable to Load Channels',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _genericError!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('channel_retry_button'),
                  onPressed: _loadChannels,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_guilds.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              key: const Key('channel_empty_view'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.forum_outlined,
                  size: 48,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  'No Eligible Channels',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'No text channels were found where both your account and the Discord Orb bot have read access.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('channel_empty_refresh_button'),
                  onPressed: _loadChannels,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      key: const Key('channel_guild_list'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _guilds.length,
      itemBuilder: (BuildContext context, int index) {
        final guild = _guilds[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: <Widget>[
                  OrbAvatar(
                    name: guild.guildName,
                    imageUrl: guild.guildIconUrl,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      guild.guildName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final channel in guild.channels)
              ListTile(
                key: Key('channel_tile_${channel.channelId}'),
                leading: const Text(
                  '#',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                title: Text('#${channel.channelName}'),
                selected: widget.selectedChannel?.channelId == channel.channelId,
                trailing: widget.selectedChannel?.channelId == channel.channelId
                    ? Icon(Icons.check_circle, color: colorScheme.primary)
                    : const Icon(Icons.chevron_right),
                onTap: () => widget.onChannelSelected(channel),
              ),
            if (index < _guilds.length - 1) const Divider(height: 1),
          ],
        );
      },
    );
  }
}
