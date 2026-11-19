import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../contracts/auth_repository.dart';
import '../../models/orb_error.dart';
import '../../models/session_models.dart';

/// Default device naming helper for [OrbPlatform].
extension OrbPlatformDefaultDeviceName on OrbPlatform {
  String get defaultDeviceName => switch (this) {
        OrbPlatform.android => 'Android Device',
        OrbPlatform.macos => 'macOS Desktop',
        OrbPlatform.windows => 'Windows Desktop',
      };
}

/// Setup screen for configuring the HTTPS backend URL and device name.
class BackendSetupScreen extends StatefulWidget {
  const BackendSetupScreen({
    super.key,
    required this.authRepository,
    required this.onConfigured,
    this.platform,
    this.initialUrl,
  });

  final AuthRepository authRepository;
  final VoidCallback onConfigured;
  final OrbPlatform? platform;
  final String? initialUrl;

  @override
  State<BackendSetupScreen> createState() => _BackendSetupScreenState();
}

class _BackendSetupScreenState extends State<BackendSetupScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _deviceNameController;
  late final OrbPlatform _resolvedPlatform;

  String? _urlError;
  String? _probeError;
  List<String> _missingEnvNames = const <String>[];
  bool _isProbing = false;

  @override
  void initState() {
    super.initState();
    _resolvedPlatform = widget.platform ?? _detectPlatform();

    final initialUrl =
        widget.initialUrl ?? widget.authRepository.backendBaseUrl ?? '';
    _urlController = TextEditingController(text: initialUrl);

    final existingDeviceName =
        widget.authRepository.currentDeviceIdentity?.deviceName.trim();
    final defaultName = (existingDeviceName != null &&
            existingDeviceName.isNotEmpty)
        ? existingDeviceName
        : _resolvedPlatform.defaultDeviceName;
    _deviceNameController = TextEditingController(text: defaultName);

    if (initialUrl.trim().isNotEmpty) {
      _urlError = _validateHttpsUrl(initialUrl);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }

  OrbPlatform _detectPlatform() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => OrbPlatform.android,
      TargetPlatform.windows => OrbPlatform.windows,
      _ => OrbPlatform.macos,
    };
  }

  String? _validateHttpsUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return 'Backend URL is required.';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return 'Backend URL must start with https:// and include a valid host.';
    }
    return null;
  }

  void _onUrlChanged(String value) {
    final trimmed = value.trim();
    final nextError = trimmed.isEmpty ? null : _validateHttpsUrl(trimmed);
    if (nextError != _urlError ||
        _probeError != null ||
        _missingEnvNames.isNotEmpty) {
      setState(() {
        _urlError = nextError;
        _probeError = null;
        _missingEnvNames = const <String>[];
      });
    }
  }

  Future<void> _submit() async {
    final trimmedUrl = _urlController.text.trim();
    final validationError = _validateHttpsUrl(trimmedUrl);
    if (validationError != null) {
      setState(() {
        _urlError = validationError;
        _probeError = null;
        _missingEnvNames = const <String>[];
      });
      return;
    }

    setState(() {
      _urlError = null;
      _probeError = null;
      _missingEnvNames = const <String>[];
      _isProbing = true;
    });

    try {
      final health =
          await widget.authRepository.validateAndProbeBackend(trimmedUrl);
      if (!mounted) return;

      if (health.setupRequired) {
        setState(() {
          _isProbing = false;
          _missingEnvNames = health.missingEnvNames;
        });
        return;
      }

      final trimmedDeviceName = _deviceNameController.text.trim();
      final effectiveDeviceName = trimmedDeviceName.isEmpty
          ? _resolvedPlatform.defaultDeviceName
          : trimmedDeviceName;

      await widget.authRepository.configureBackend(
        trimmedUrl,
        deviceName: effectiveDeviceName,
      );
      if (!mounted) return;

      setState(() {
        _isProbing = false;
      });
      widget.onConfigured();
    } on OrbException catch (error) {
      if (!mounted) return;
      setState(() {
        _isProbing = false;
        _probeError = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isProbing = false;
        _probeError = 'Failed to connect to backend: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasInvalidUrl = _urlError != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Backend'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Discord Orb Setup',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter your self-hosted Discord Orb backend URL (HTTPS required) and a name for this device.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  key: const Key('backend_url_field'),
                  controller: _urlController,
                  enabled: !_isProbing,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: _onUrlChanged,
                  onSubmitted: (_) {
                    if (!_isProbing && !hasInvalidUrl) {
                      _submit();
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Backend URL',
                    hintText: 'https://orb.example.com',
                    errorText: _urlError,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('device_name_field'),
                  controller: _deviceNameController,
                  enabled: !_isProbing,
                  decoration: InputDecoration(
                    labelText: 'Device Name',
                    helperText: 'Platform: ${_resolvedPlatform.displayName}',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.devices),
                  ),
                ),
                if (_missingEnvNames.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  _StatusBanner(
                    key: const Key('backend_setup_required_banner'),
                    icon: Icons.warning_amber_rounded,
                    color: colorScheme.tertiaryContainer,
                    foregroundColor: colorScheme.onTertiaryContainer,
                    title: 'Backend setup incomplete',
                    body:
                        'The backend reported missing configuration variables:\n'
                        '${_missingEnvNames.map((name) => '• $name').join('\n')}',
                  ),
                ],
                if (_probeError != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _StatusBanner(
                    key: const Key('backend_probe_error_banner'),
                    icon: Icons.error_outline,
                    color: colorScheme.errorContainer,
                    foregroundColor: colorScheme.onErrorContainer,
                    title: 'Connection failed',
                    body: _probeError!,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('backend_connect_button'),
                  onPressed: (_isProbing || hasInvalidUrl) ? null : _submit,
                  icon: _isProbing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          (_probeError != null || _missingEnvNames.isNotEmpty)
                              ? Icons.refresh
                              : Icons.arrow_forward,
                        ),
                  label: Text(
                    _isProbing
                        ? 'Checking backend...'
                        : (_probeError != null || _missingEnvNames.isNotEmpty)
                            ? 'Retry Connection'
                            : 'Connect & Continue',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.foregroundColor,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final Color foregroundColor;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: foregroundColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: foregroundColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: foregroundColor,
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
