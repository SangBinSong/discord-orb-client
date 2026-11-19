import 'package:flutter/material.dart';

import '../../contracts/auth_repository.dart';
import '../../models/channel_models.dart';
import '../../models/orb_error.dart';

/// Bottom sheet displaying current session details and session management actions.
class SessionSettingsSheet extends StatefulWidget {
  const SessionSettingsSheet({
    super.key,
    required this.authRepository,
    required this.onReselectChannel,
    required this.onSignedOut,
    required this.onBackendChanged,
    this.selectedChannel,
  });

  final AuthRepository authRepository;
  final EligibleChannel? selectedChannel;
  final VoidCallback onReselectChannel;
  final VoidCallback onSignedOut;
  final VoidCallback onBackendChanged;

  @override
  State<SessionSettingsSheet> createState() => _SessionSettingsSheetState();
}

class _SessionSettingsSheetState extends State<SessionSettingsSheet> {
  bool _isBusy = false;
  String? _errorMessage;

  Future<void> _handleSignOut() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      await widget.authRepository.signOut();
      if (!mounted) return;
      setState(() {
        _isBusy = false;
      });
      widget.onSignedOut();
    } on OrbException catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = 'Failed to sign out: $error';
      });
    }
  }

  Future<void> _handleChangeBackend() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      await widget.authRepository.clearLocalStateForBackendChange();
      if (!mounted) return;
      setState(() {
        _isBusy = false;
      });
      widget.onBackendChanged();
    } on OrbException catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = 'Failed to reset backend configuration: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final backendUrl = widget.authRepository.backendBaseUrl ?? 'Not configured';
    final deviceIdentity = widget.authRepository.currentDeviceIdentity;
    final deviceText = deviceIdentity == null
        ? 'Not registered'
        : '${deviceIdentity.deviceName} (${deviceIdentity.platform.displayName})';
    final selectedChannel = widget.selectedChannel;
    final channelText = selectedChannel == null
        ? 'No channel selected'
        : '${selectedChannel.guildName} · #${selectedChannel.channelName}';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  'Session Settings',
                  style: theme.textTheme.titleLarge,
                ),
                const Spacer(),
                if (_isBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _DetailTile(
              icon: Icons.link,
              label: 'Backend URL',
              value: backendUrl,
            ),
            const SizedBox(height: 10),
            _DetailTile(
              icon: Icons.devices,
              label: 'Device & Platform',
              value: deviceText,
            ),
            const SizedBox(height: 10),
            _DetailTile(
              icon: Icons.tag,
              label: 'Selected Channel',
              value: channelText,
            ),
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: 14),
              Container(
                key: const Key('settings_error_banner'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _errorMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              key: const Key('settings_reselect_channel_button'),
              onPressed: _isBusy ? null : widget.onReselectChannel,
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Change Channel'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('settings_sign_out_button'),
              onPressed: _isBusy ? null : _handleSignOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign Out'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              key: const Key('settings_change_backend_button'),
              onPressed: _isBusy ? null : _handleChangeBackend,
              icon: Icon(Icons.settings_backup_restore, color: colorScheme.error),
              label: Text(
                'Change Backend URL',
                style: TextStyle(color: colorScheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailTile extends StatelessWidget {
  const _DetailTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
