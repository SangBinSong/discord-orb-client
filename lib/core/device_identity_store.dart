import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../contracts/auth_repository.dart';
import '../models/message_models.dart';
import '../models/session_models.dart';
import 'https_validator.dart';

/// Persists per-backend device identity (`device_id`, `device_name`,
/// `platform`) and session tokens in [SecureKeyValueStore].
class DeviceIdentityStore {
  DeviceIdentityStore({
    required this._store,
    OrbPlatform? defaultPlatform,
    Random? random,
    this._defaultDeviceName,
  })  : _defaultPlatform = defaultPlatform ?? detectCurrentPlatform(),
        _random = random ?? Random.secure();

  static const String activeBackendUrlKey = 'orb.active_backend_url';
  static const String selectedChannelKey = 'orb.selected_channel';
  static const String legacySelectedChannelKey = 'selected_channel';
  static const String chatListLayoutKey = 'orb.chat_list_layout';
  static const String panelPinnedKey = 'orb.panel_pinned';
  static const String toastNotificationsEnabledKey =
      'orb.toast_notifications_enabled';
  static const String maxVisibleToastCountKey = 'orb.max_visible_toast_count';
  static const String toastLayoutKey = 'orb.toast_layout';

  static const int minVisibleToastCount = 1;
  static const int maxVisibleToastCount = 5;
  static const int defaultMaxVisibleToastCount = 3;

  /// Clamps a toast popup stack limit to the supported range `[1, 5]`.
  static int clampMaxVisibleToastCount(int count) {
    if (count < minVisibleToastCount) return minVisibleToastCount;
    if (count > maxVisibleToastCount) return maxVisibleToastCount;
    return count;
  }

  final SecureKeyValueStore _store;
  final OrbPlatform _defaultPlatform;
  final Random _random;
  final String? _defaultDeviceName;

  String? _cachedBackendUrl;
  DeviceIdentity? _cachedIdentity;
  OrbSessionTokens? _cachedTokens;
  String? _cachedSelectedChannel;

  String? get cachedBackendUrl => _cachedBackendUrl;
  DeviceIdentity? get cachedIdentity => _cachedIdentity;
  OrbSessionTokens? get cachedTokens => _cachedTokens;
  String? get cachedSelectedChannel => _cachedSelectedChannel;

  /// Detects the current host [OrbPlatform] from `dart:io` [Platform].
  static OrbPlatform detectCurrentPlatform() {
    if (Platform.isAndroid) return OrbPlatform.android;
    if (Platform.isWindows) return OrbPlatform.windows;
    return OrbPlatform.macos;
  }

  /// Generates a cryptographically random UUID v4 installation identifier.
  String generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) {
        buffer.write('-');
      }
      buffer.write(hex(bytes[i]));
    }
    return buffer.toString();
  }

  /// Reads the currently active normalized backend URL, if configured.
  Future<String?> readActiveBackendUrl() async {
    if (_cachedBackendUrl != null) {
      return _cachedBackendUrl;
    }
    final raw = await _store.read(activeBackendUrlKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final normalized = HttpsValidator.validateBackendBaseUrl(raw).toString();
      _cachedBackendUrl = normalized;
      return normalized;
    } catch (_) {
      await _store.delete(activeBackendUrlKey);
      return null;
    }
  }

  /// Configures [backendUrl] as the active backend, wiping prior session
  /// tokens, selected channel keys, and in-memory state if the URL changed,
  /// and preparing a [DeviceIdentity] bound to the new backend.
  Future<DeviceIdentity> configureBackend(
    String backendUrl, {
    String? deviceName,
    OrbPlatform? platform,
  }) async {
    final normalized =
        HttpsValidator.validateBackendBaseUrl(backendUrl).toString();
    final previousUrl = await readActiveBackendUrl();

    if (previousUrl != null && previousUrl != normalized) {
      await clearForBackendChange(previousBackendUrl: previousUrl);
    }

    await _store.write(activeBackendUrlKey, normalized);
    _cachedBackendUrl = normalized;

    return getOrCreateDeviceIdentity(
      normalized,
      deviceName: deviceName,
      platform: platform,
    );
  }

  /// Reads an existing [DeviceIdentity] bound to [backendUrl], or `null`.
  Future<DeviceIdentity?> readDeviceIdentity(String backendUrl) async {
    final normalized =
        HttpsValidator.validateBackendBaseUrl(backendUrl).toString();
    if (_cachedBackendUrl == normalized && _cachedIdentity != null) {
      return _cachedIdentity;
    }
    final raw = await _store.read(_identityKeyFor(normalized));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await _store.delete(_identityKeyFor(normalized));
        return null;
      }
      final identity = DeviceIdentity.fromJson(decoded);
      if (_cachedBackendUrl == normalized) {
        _cachedIdentity = identity;
      }
      return identity;
    } catch (_) {
      await _store.delete(_identityKeyFor(normalized));
      return null;
    }
  }

  /// Returns the existing [DeviceIdentity] for [backendUrl] or creates and
  /// persists a new random `device_id` bound to [backendUrl].
  Future<DeviceIdentity> getOrCreateDeviceIdentity(
    String backendUrl, {
    String? deviceName,
    OrbPlatform? platform,
  }) async {
    final normalized =
        HttpsValidator.validateBackendBaseUrl(backendUrl).toString();
    final effectivePlatform = platform ?? _defaultPlatform;
    final existing = await readDeviceIdentity(normalized);
    final trimmedName = deviceName?.trim();

    if (existing != null) {
      final updatedName = (trimmedName != null && trimmedName.isNotEmpty)
          ? trimmedName
          : existing.deviceName;
      final updated = (updatedName != existing.deviceName ||
              effectivePlatform != existing.platform)
          ? existing.copyWith(
              deviceName: updatedName,
              platform: effectivePlatform,
            )
          : existing;
      if (updated != existing) {
        await _store.write(
          _identityKeyFor(normalized),
          jsonEncode(updated.toJson()),
        );
      }
      if (_cachedBackendUrl == normalized) {
        _cachedIdentity = updated;
      }
      return updated;
    }

    final resolvedName = (trimmedName != null && trimmedName.isNotEmpty)
        ? trimmedName
        : _resolveDefaultDeviceName(effectivePlatform);

    final created = DeviceIdentity(
      deviceName: resolvedName,
      deviceId: generateDeviceId(),
      platform: effectivePlatform,
    );
    await _store.write(
      _identityKeyFor(normalized),
      jsonEncode(created.toJson()),
    );
    if (_cachedBackendUrl == normalized) {
      _cachedIdentity = created;
    }
    return created;
  }

  /// Saves [tokens] as JSON bound to [backendUrl].
  Future<void> saveSessionTokens(
    String backendUrl,
    OrbSessionTokens tokens,
  ) async {
    final normalized =
        HttpsValidator.validateBackendBaseUrl(backendUrl).toString();
    await _store.write(
      _tokensKeyFor(normalized),
      jsonEncode(tokens.toJson()),
    );
    if (_cachedBackendUrl == normalized || _cachedBackendUrl == null) {
      _cachedTokens = tokens;
    }
  }

  /// Reads stored [OrbSessionTokens] bound to [backendUrl], or `null`.
  Future<OrbSessionTokens?> readSessionTokens(String backendUrl) async {
    final normalized =
        HttpsValidator.validateBackendBaseUrl(backendUrl).toString();
    if (_cachedBackendUrl == normalized && _cachedTokens != null) {
      return _cachedTokens;
    }
    final raw = await _store.read(_tokensKeyFor(normalized));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await _store.delete(_tokensKeyFor(normalized));
        return null;
      }
      final tokens = OrbSessionTokens.fromJson(decoded);
      if (_cachedBackendUrl == normalized) {
        _cachedTokens = tokens;
      }
      return tokens;
    } catch (_) {
      await _store.delete(_tokensKeyFor(normalized));
      return null;
    }
  }

  /// Deletes stored session tokens for [backendUrl] and clears cached tokens.
  Future<void> deleteSessionTokens(String backendUrl) async {
    final normalized =
        HttpsValidator.validateBackendBaseUrl(backendUrl).toString();
    _cachedTokens = null;
    await _store.delete(_tokensKeyFor(normalized));
  }

  /// Reads the selected channel key from secure storage.
  Future<String?> readSelectedChannel() async {
    if (_cachedSelectedChannel != null) {
      return _cachedSelectedChannel;
    }
    final value = await _store.read(selectedChannelKey);
    _cachedSelectedChannel = value;
    return value;
  }

  /// Persists the selected channel key in secure storage.
  Future<void> saveSelectedChannel(String channelKey) async {
    _cachedSelectedChannel = channelKey;
    await _store.write(selectedChannelKey, channelKey);
  }

  /// Reads the persisted [ChatListLayout] preference, defaulting to standard.
  Future<ChatListLayout> readChatListLayout() async {
    final raw = await _store.read(chatListLayoutKey);
    return ChatListLayout.fromStorageValue(raw);
  }

  /// Persists the user's preferred [ChatListLayout].
  Future<void> saveChatListLayout(ChatListLayout layout) async {
    await _store.write(chatListLayoutKey, layout.storageValue);
  }

  /// Reads whether the expanded panel stays pinned open when focus moves to
  /// another window. Defaults to `true`.
  Future<bool> readPanelPinned() async {
    final raw = await _store.read(panelPinnedKey);
    return _parseBoolPreference(raw, defaultValue: true);
  }

  /// Persists whether the expanded panel stays pinned open on focus loss.
  Future<void> savePanelPinned(bool pinned) async {
    await _store.write(panelPinnedKey, pinned ? 'true' : 'false');
  }

  /// Reads whether collapsed-orb real-time toast notifications are enabled.
  /// Defaults to `true`.
  Future<bool> readToastNotificationsEnabled() async {
    final raw = await _store.read(toastNotificationsEnabledKey);
    return _parseBoolPreference(raw, defaultValue: true);
  }

  /// Persists whether collapsed-orb real-time toast notifications are enabled.
  Future<void> saveToastNotificationsEnabled(bool enabled) async {
    await _store.write(
      toastNotificationsEnabledKey,
      enabled ? 'true' : 'false',
    );
  }

  /// Reads the maximum number of simultaneously visible toast popup cards
  /// (`1..5`, defaulting to `3`).
  Future<int> readMaxVisibleToastCount() async {
    final raw = await _store.read(maxVisibleToastCountKey);
    if (raw == null || raw.trim().isEmpty) {
      return defaultMaxVisibleToastCount;
    }
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      return defaultMaxVisibleToastCount;
    }
    return clampMaxVisibleToastCount(parsed);
  }

  /// Persists the maximum number of simultaneously visible toast popup cards,
  /// clamped to `[1, 5]`.
  Future<void> saveMaxVisibleToastCount(int count) async {
    final clamped = clampMaxVisibleToastCount(count);
    await _store.write(maxVisibleToastCountKey, clamped.toString());
  }

  /// Reads the persisted toast popup density preference (`standard` or
  /// `compact`), defaulting to [ChatListLayout.standard].
  Future<ChatListLayout> readToastLayout() async {
    final raw = await _store.read(toastLayoutKey);
    return ChatListLayout.fromStorageValue(raw);
  }

  /// Persists the user's preferred toast popup density layout.
  Future<void> saveToastLayout(ChatListLayout layout) async {
    await _store.write(toastLayoutKey, layout.storageValue);
  }

  static bool _parseBoolPreference(
    String? raw, {
    required bool defaultValue,
  }) {
    return switch (raw?.trim().toLowerCase()) {
      'true' => true,
      'false' => false,
      _ => defaultValue,
    };
  }

  /// Deletes all selected channel keys from storage and memory.
  Future<void> deleteSelectedChannel({String? backendUrl}) async {
    _cachedSelectedChannel = null;
    await _store.delete(selectedChannelKey);
    await _store.delete(legacySelectedChannelKey);
    if (backendUrl != null) {
      final normalized =
          HttpsValidator.validateBackendBaseUrl(backendUrl).toString();
      await _store.delete(_selectedChannelKeyFor(normalized));
    }
  }

  /// Immediately clears session tokens, selected channel keys, and in-memory
  /// data when switching or resetting backend URLs.
  Future<void> clearForBackendChange({String? previousBackendUrl}) async {
    final targetBackend = previousBackendUrl ?? _cachedBackendUrl;
    String? normalizedPrevious;
    if (targetBackend != null) {
      try {
        normalizedPrevious =
            HttpsValidator.validateBackendBaseUrl(targetBackend).toString();
      } catch (_) {
        normalizedPrevious = null;
      }
    } else {
      normalizedPrevious = await readActiveBackendUrl();
    }

    clearMemory();

    if (normalizedPrevious != null) {
      await _store.delete(_tokensKeyFor(normalizedPrevious));
      await _store.delete(_selectedChannelKeyFor(normalizedPrevious));
    }
    await _store.delete(selectedChannelKey);
    await _store.delete(legacySelectedChannelKey);
    await _store.delete(activeBackendUrlKey);
  }

  /// Clears all in-memory cached state without altering persisted device IDs.
  void clearMemory() {
    _cachedBackendUrl = null;
    _cachedIdentity = null;
    _cachedTokens = null;
    _cachedSelectedChannel = null;
  }

  String _resolveDefaultDeviceName(OrbPlatform platform) {
    final configured = _defaultDeviceName?.trim();
    if (configured != null && configured.isNotEmpty) {
      return configured;
    }
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) {
        return host;
      }
    } catch (_) {
      // Fallback when localHostname is unavailable.
    }
    return 'Discord Orb (${platform.displayName})';
  }

  static String _backendHash(String normalizedUrl) {
    return sha256.convert(utf8.encode(normalizedUrl)).toString();
  }

  static String _identityKeyFor(String normalizedUrl) =>
      'orb.backend.${_backendHash(normalizedUrl)}.device_identity';

  static String _tokensKeyFor(String normalizedUrl) =>
      'orb.backend.${_backendHash(normalizedUrl)}.session_tokens';

  static String _selectedChannelKeyFor(String normalizedUrl) =>
      'orb.backend.${_backendHash(normalizedUrl)}.selected_channel';
}
