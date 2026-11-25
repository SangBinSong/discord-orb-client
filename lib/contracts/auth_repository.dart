import '../models/session_models.dart';

/// Abstraction for secure key-value persistence of tokens and device identity.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> clearAll();
}

/// In-memory [SecureKeyValueStore] implementation for tests and ephemeral runs.
class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _storage = <String, String>{};

  @override
  Future<String?> read(String key) async => _storage[key];

  @override
  Future<void> write(String key, String value) async {
    _storage[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _storage.remove(key);
  }

  @override
  Future<void> clearAll() async {
    _storage.clear();
  }
}

/// Abstraction for launching external OAuth URLs in the system browser.
abstract interface class SystemBrowserLauncher {
  Future<void> launch(Uri uri);
}

/// Coordinates backend discovery, Discord OAuth sign-in, and session lifecycle.
abstract interface class AuthRepository {
  String? get backendBaseUrl;
  DeviceIdentity? get currentDeviceIdentity;

  Future<BackendHealthStatus> validateAndProbeBackend(String url);
  Future<void> configureBackend(String url, {String? deviceName});
  Future<OrbSessionTokens> signInWithDiscord({
    bool launchBrowser = true,
    void Function(Uri authorizationUri)? onAuthorizationUriReady,
  });
  Future<void> cancelPendingSignIn();
  Future<OrbSessionTokens?> loadStoredSession();
  Future<OrbSessionTokens> refreshAccessToken();
  Future<void> signOut();
  Future<void> clearLocalStateForBackendChange();
}
