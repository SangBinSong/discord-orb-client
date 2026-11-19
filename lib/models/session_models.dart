/// Supported client platforms for Discord Orb.
enum OrbPlatform {
  android('android', 'Android'),
  macos('macos', 'macOS'),
  windows('windows', 'Windows');

  const OrbPlatform(this.wireName, this.displayName);

  final String wireName;
  final String displayName;

  /// Parses a wire platform identifier (case-insensitive).
  static OrbPlatform fromWire(String value) {
    final normalized = value.trim().toLowerCase();
    for (final platform in OrbPlatform.values) {
      if (platform.wireName == normalized) {
        return platform;
      }
    }
    throw ArgumentError.value(value, 'value', 'Unsupported OrbPlatform');
  }
}

/// Device metadata registered with the backend during authentication.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceName,
    required this.deviceId,
    required this.platform,
  });

  final String deviceName;
  final String deviceId;
  final OrbPlatform platform;

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) {
    final deviceName =
        (json['device_name'] ?? json['deviceName']) as String?;
    final deviceId = (json['device_id'] ?? json['deviceId']) as String?;
    final platformRaw = json['platform'] as String?;

    if (deviceName == null || deviceId == null || platformRaw == null) {
      throw const FormatException('Missing required DeviceIdentity fields');
    }

    return DeviceIdentity(
      deviceName: deviceName,
      deviceId: deviceId,
      platform: OrbPlatform.fromWire(platformRaw),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device_name': deviceName,
        'device_id': deviceId,
        'platform': platform.wireName,
      };

  DeviceIdentity copyWith({
    String? deviceName,
    String? deviceId,
    OrbPlatform? platform,
  }) {
    return DeviceIdentity(
      deviceName: deviceName ?? this.deviceName,
      deviceId: deviceId ?? this.deviceId,
      platform: platform ?? this.platform,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceIdentity &&
        other.deviceName == deviceName &&
        other.deviceId == deviceId &&
        other.platform == platform;
  }

  @override
  int get hashCode => Object.hash(deviceName, deviceId, platform);

  @override
  String toString() =>
      'DeviceIdentity(deviceName: $deviceName, deviceId: $deviceId, platform: ${platform.wireName})';
}

/// Access and refresh tokens issued by the Discord Orb backend.
class OrbSessionTokens {
  const OrbSessionTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.sessionExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime sessionExpiresAt;

  factory OrbSessionTokens.fromJson(Map<String, dynamic> json) {
    final accessToken =
        (json['access_token'] ?? json['accessToken']) as String?;
    final refreshToken =
        (json['refresh_token'] ?? json['refreshToken']) as String?;
    final accessExpiresRaw =
        (json['access_expires_at'] ?? json['accessExpiresAt']) as String?;
    final sessionExpiresRaw =
        (json['session_expires_at'] ?? json['sessionExpiresAt']) as String?;

    if (accessToken == null ||
        refreshToken == null ||
        accessExpiresRaw == null ||
        sessionExpiresRaw == null) {
      throw const FormatException('Missing required OrbSessionTokens fields');
    }

    return OrbSessionTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessExpiresAt: DateTime.parse(accessExpiresRaw).toUtc(),
      sessionExpiresAt: DateTime.parse(sessionExpiresRaw).toUtc(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
        'session_expires_at': sessionExpiresAt.toUtc().toIso8601String(),
      };

  bool isAccessExpired({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    return !current.isBefore(accessExpiresAt.toUtc());
  }

  bool isSessionExpired({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    return !current.isBefore(sessionExpiresAt.toUtc());
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OrbSessionTokens &&
        other.accessToken == accessToken &&
        other.refreshToken == refreshToken &&
        other.accessExpiresAt.toUtc() == accessExpiresAt.toUtc() &&
        other.sessionExpiresAt.toUtc() == sessionExpiresAt.toUtc();
  }

  @override
  int get hashCode => Object.hash(
        accessToken,
        refreshToken,
        accessExpiresAt.toUtc(),
        sessionExpiresAt.toUtc(),
      );
}

/// Result of probing a Discord Orb backend health endpoint.
class BackendHealthStatus {
  const BackendHealthStatus({
    required this.setupRequired,
    this.missingEnvNames = const <String>[],
  });

  final bool setupRequired;
  final List<String> missingEnvNames;

  factory BackendHealthStatus.fromJson(Map<String, dynamic> json) {
    final setupRequired =
        (json['setup_required'] ?? json['setupRequired']) as bool? ?? false;
    final rawMissing = json['missing_env_names'] ??
        json['missingEnvNames'] ??
        json['missing_env'] ??
        const <dynamic>[];

    final missingEnvNames = (rawMissing as List<dynamic>)
        .map((dynamic item) => item.toString())
        .toList(growable: false);

    return BackendHealthStatus(
      setupRequired: setupRequired,
      missingEnvNames: missingEnvNames,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'setup_required': setupRequired,
        'missing_env_names': missingEnvNames,
      };
}
