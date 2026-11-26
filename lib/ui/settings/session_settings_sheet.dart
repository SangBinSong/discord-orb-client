import 'package:flutter/material.dart';

import '../../contracts/auth_repository.dart';
import '../../core/device_identity_store.dart';
import '../../models/channel_models.dart';
import '../../models/message_models.dart';
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
    this.chatListLayout = ChatListLayout.standard,
    this.onChatListLayoutChanged,
    this.isPanelPinned = true,
    this.onPanelPinnedChanged,
    this.toastNotificationsEnabled = true,
    this.onToastNotificationsChanged,
    this.maxVisibleToastCount = DeviceIdentityStore.defaultMaxVisibleToastCount,
    this.onMaxVisibleToastCountChanged,
    this.toastLayout = ChatListLayout.standard,
    this.onToastLayoutChanged,
    this.onQuitApp,
  });

  static const Key layoutSelectorKey = Key('settings_chat_layout_selector');
  static const Key panelPinnedSwitchKey = Key('settings_panel_pinned_switch');
  static const Key toastNotificationsSwitchKey =
      Key('settings_toast_notifications_switch');
  static const Key maxToastCountSelectorKey =
      Key('settings_max_toast_count_selector');
  static const Key maxToastCountOffKey = Key('settings_max_toast_count_off');
  static const Key toastLayoutSelectorKey =
      Key('settings_toast_layout_selector');
  static const Key toastLayoutStandardKey =
      Key('settings_toast_layout_standard');
  static const Key toastLayoutCompactKey = Key('settings_toast_layout_compact');
  static const Key quitAppButtonKey = Key('settings_quit_app_button');
  static Key maxToastCountOptionKey(int count) =>
      Key('settings_max_toast_count_$count');

  final AuthRepository authRepository;
  final EligibleChannel? selectedChannel;
  final ChatListLayout chatListLayout;
  final ValueChanged<ChatListLayout>? onChatListLayoutChanged;
  final bool isPanelPinned;
  final ValueChanged<bool>? onPanelPinnedChanged;
  final bool toastNotificationsEnabled;
  final ValueChanged<bool>? onToastNotificationsChanged;
  final int maxVisibleToastCount;
  final ValueChanged<int>? onMaxVisibleToastCountChanged;
  final ChatListLayout toastLayout;
  final ValueChanged<ChatListLayout>? onToastLayoutChanged;
  final VoidCallback onReselectChannel;
  final VoidCallback onSignedOut;
  final VoidCallback onBackendChanged;
  final VoidCallback? onQuitApp;

  @override
  State<SessionSettingsSheet> createState() => _SessionSettingsSheetState();
}

class _SessionSettingsSheetState extends State<SessionSettingsSheet> {
  bool _isBusy = false;
  String? _errorMessage;
  late ChatListLayout _selectedLayout;
  late bool _isPanelPinned;
  late bool _toastNotificationsEnabled;
  late int _maxVisibleToastCount;
  late ChatListLayout _toastLayout;

  @override
  void initState() {
    super.initState();
    _selectedLayout = widget.chatListLayout;
    _isPanelPinned = widget.isPanelPinned;
    _toastNotificationsEnabled = widget.toastNotificationsEnabled;
    _maxVisibleToastCount = DeviceIdentityStore.clampMaxVisibleToastCount(
      widget.maxVisibleToastCount,
    );
    _toastLayout = widget.toastLayout;
  }

  @override
  void didUpdateWidget(covariant SessionSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatListLayout != widget.chatListLayout) {
      _selectedLayout = widget.chatListLayout;
    }
    if (oldWidget.isPanelPinned != widget.isPanelPinned) {
      _isPanelPinned = widget.isPanelPinned;
    }
    if (oldWidget.toastNotificationsEnabled !=
        widget.toastNotificationsEnabled) {
      _toastNotificationsEnabled = widget.toastNotificationsEnabled;
    }
    if (oldWidget.maxVisibleToastCount != widget.maxVisibleToastCount) {
      _maxVisibleToastCount = DeviceIdentityStore.clampMaxVisibleToastCount(
        widget.maxVisibleToastCount,
      );
    }
    if (oldWidget.toastLayout != widget.toastLayout) {
      _toastLayout = widget.toastLayout;
    }
  }

  void _handleLayoutSelected(ChatListLayout next) {
    if (next == _selectedLayout) return;
    setState(() {
      _selectedLayout = next;
    });
    widget.onChatListLayoutChanged?.call(next);
  }

  void _handlePanelPinnedChanged(bool next) {
    if (next == _isPanelPinned) return;
    setState(() {
      _isPanelPinned = next;
    });
    widget.onPanelPinnedChanged?.call(next);
  }

  void _handleToastNotificationsChanged(bool next) {
    if (next == _toastNotificationsEnabled) return;
    setState(() {
      _toastNotificationsEnabled = next;
    });
    widget.onToastNotificationsChanged?.call(next);
  }

  void _handleMaxVisibleToastCountChanged(int next) {
    final clamped = DeviceIdentityStore.clampMaxVisibleToastCount(next);
    final wasOff = !_toastNotificationsEnabled;
    final countChanged = clamped != _maxVisibleToastCount;
    if (!wasOff && !countChanged) return;
    setState(() {
      _toastNotificationsEnabled = true;
      _maxVisibleToastCount = clamped;
    });
    if (wasOff) {
      widget.onToastNotificationsChanged?.call(true);
    }
    if (countChanged) {
      widget.onMaxVisibleToastCountChanged?.call(clamped);
    }
  }

  void _handleToastLayoutChanged(ChatListLayout next) {
    if (next == _toastLayout) return;
    setState(() {
      _toastLayout = next;
    });
    widget.onToastLayoutChanged?.call(next);
  }

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
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Session Settings',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (_isBusy) ...<Widget>[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            _DetailTile(
              icon: Icons.link,
              label: 'Backend URL',
              value: backendUrl,
            ),
            const SizedBox(height: 6),
            _DetailTile(
              icon: Icons.devices,
              label: 'Device & Platform',
              value: deviceText,
            ),
            const SizedBox(height: 6),
            _DetailTile(
              icon: Icons.tag,
              label: 'Selected Channel',
              value: channelText,
            ),
            if (widget.onChatListLayoutChanged != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                'Message Layout',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              SegmentedButton<ChatListLayout>(
                key: SessionSettingsSheet.layoutSelectorKey,
                segments: const <ButtonSegment<ChatListLayout>>[
                  ButtonSegment<ChatListLayout>(
                    value: ChatListLayout.standard,
                    icon: Icon(Icons.view_agenda_outlined, size: 16),
                    label: Text('Standard'),
                  ),
                  ButtonSegment<ChatListLayout>(
                    value: ChatListLayout.compact,
                    icon: Icon(Icons.view_headline_outlined, size: 16),
                    label: Text('Compact'),
                  ),
                ],
                selected: <ChatListLayout>{_selectedLayout},
                onSelectionChanged: _isBusy
                    ? null
                    : (Set<ChatListLayout> selection) {
                        if (selection.isNotEmpty) {
                          _handleLayoutSelected(selection.first);
                        }
                      },
              ),
            ],
            if (widget.onPanelPinnedChanged != null) ...<Widget>[
              const SizedBox(height: 4),
              SwitchListTile(
                key: SessionSettingsSheet.panelPinnedSwitchKey,
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                secondary: Icon(
                  _isPanelPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
                title: const Text('Pin panel open'),
                value: _isPanelPinned,
                onChanged: _isBusy ? null : _handlePanelPinnedChanged,
              ),
            ],
            if (widget.onToastNotificationsChanged != null) ...<Widget>[
              SwitchListTile(
                key: SessionSettingsSheet.toastNotificationsSwitchKey,
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                secondary: Icon(
                  _toastNotificationsEnabled
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
                title: const Text('Message toast popups'),
                value: _toastNotificationsEnabled,
                onChanged: _isBusy ? null : _handleToastNotificationsChanged,
              ),
            ],
            if (widget.onMaxVisibleToastCountChanged != null ||
                widget.onToastNotificationsChanged != null) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Row(
                  key: SessionSettingsSheet.maxToastCountSelectorKey,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Max Toast Popups',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 4,
                      children: <Widget>[
                        if (widget.onToastNotificationsChanged != null)
                          _OptionPillButton(
                            key: SessionSettingsSheet.maxToastCountOffKey,
                            label: 'Off',
                            semanticLabel: 'Turn off toast popups',
                            width: 34,
                            selected: !_toastNotificationsEnabled,
                            enabled: !_isBusy,
                            onTap: () =>
                                _handleToastNotificationsChanged(false),
                          ),
                        if (widget.onMaxVisibleToastCountChanged != null)
                          for (int count =
                                  DeviceIdentityStore.minVisibleToastCount;
                              count <= DeviceIdentityStore.maxVisibleToastCount;
                              count++)
                            _OptionPillButton(
                              key: SessionSettingsSheet.maxToastCountOptionKey(
                                count,
                              ),
                              label: '$count',
                              semanticLabel: '$count max toast popups',
                              width: 26,
                              selected: _toastNotificationsEnabled &&
                                  _maxVisibleToastCount == count,
                              enabled: !_isBusy,
                              onTap: () =>
                                  _handleMaxVisibleToastCountChanged(count),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (widget.onToastLayoutChanged != null) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Row(
                  key: SessionSettingsSheet.toastLayoutSelectorKey,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Toast Layout',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 4,
                      children: <Widget>[
                        _OptionPillButton(
                          key: SessionSettingsSheet.toastLayoutStandardKey,
                          label: 'Standard',
                          semanticLabel: 'Standard toast layout',
                          width: 66,
                          selected: _toastLayout == ChatListLayout.standard,
                          enabled: !_isBusy,
                          onTap: () =>
                              _handleToastLayoutChanged(ChatListLayout.standard),
                        ),
                        _OptionPillButton(
                          key: SessionSettingsSheet.toastLayoutCompactKey,
                          label: 'Compact',
                          semanticLabel: 'Compact toast layout',
                          width: 66,
                          selected: _toastLayout == ChatListLayout.compact,
                          enabled: !_isBusy,
                          onTap: () =>
                              _handleToastLayoutChanged(ChatListLayout.compact),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                key: const Key('settings_error_banner'),
                padding: const EdgeInsets.all(10),
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
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const Key('settings_reselect_channel_button'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 36),
              ),
              onPressed: _isBusy ? null : widget.onReselectChannel,
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text('Change Channel'),
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: const Key('settings_sign_out_button'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 36),
              ),
              onPressed: _isBusy ? null : _handleSignOut,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign Out'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              key: const Key('settings_change_backend_button'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 34),
              ),
              onPressed: _isBusy ? null : _handleChangeBackend,
              icon: Icon(
                Icons.settings_backup_restore,
                size: 18,
                color: colorScheme.error,
              ),
              label: Text(
                'Change Backend URL',
                style: TextStyle(color: colorScheme.error),
              ),
            ),
            if (widget.onQuitApp != null) ...<Widget>[
              const SizedBox(height: 2),
              TextButton.icon(
                key: SessionSettingsSheet.quitAppButtonKey,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 34),
                ),
                onPressed: _isBusy ? null : widget.onQuitApp,
                icon: Icon(
                  Icons.power_settings_new,
                  size: 18,
                  color: colorScheme.error,
                ),
                label: Text(
                  'Quit Discord Orb',
                  style: TextStyle(color: colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OptionPillButton extends StatelessWidget {
  const _OptionPillButton({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.width,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final double width;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bgColor = selected
        ? (enabled
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5))
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35);
    final fgColor = selected
        ? (enabled
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSurfaceVariant.withValues(alpha: 0.5))
        : (enabled
            ? colorScheme.onSurfaceVariant
            : colorScheme.onSurfaceVariant.withValues(alpha: 0.4));

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: semanticLabel,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: width,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected && enabled
                  ? colorScheme.primary.withValues(alpha: 0.7)
                  : colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: fgColor,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
