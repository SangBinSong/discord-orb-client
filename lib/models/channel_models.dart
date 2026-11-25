import 'package:flutter/foundation.dart';

/// A Discord text channel that both the signed-in user and the bot can read.
class EligibleChannel {
  const EligibleChannel({
    required this.guildId,
    required this.guildName,
    required this.channelId,
    required this.channelName,
    this.guildIconUrl,
  });

  final String guildId;
  final String guildName;
  final String channelId;
  final String channelName;
  final String? guildIconUrl;

  factory EligibleChannel.fromJson(
    Map<String, dynamic> json, {
    String? fallbackGuildId,
    String? fallbackGuildName,
    String? fallbackGuildIconUrl,
  }) {
    final guildId =
        (json['guild_id'] ?? json['guildId'] ?? fallbackGuildId) as String?;
    final guildName = (json['guild_name'] ??
        json['guildName'] ??
        fallbackGuildName) as String?;
    final channelId = (json['channel_id'] ?? json['channelId']) as String?;
    final channelName =
        (json['channel_name'] ?? json['channelName']) as String?;
    final rawIcon = (json['guild_icon_url'] ??
        json['guildIconUrl'] ??
        fallbackGuildIconUrl) as String?;
    final guildIconUrl =
        (rawIcon != null && rawIcon.trim().isNotEmpty) ? rawIcon.trim() : null;

    if (guildId == null ||
        guildName == null ||
        channelId == null ||
        channelName == null) {
      throw const FormatException('Missing required EligibleChannel fields');
    }

    return EligibleChannel(
      guildId: guildId,
      guildName: guildName,
      channelId: channelId,
      channelName: channelName,
      guildIconUrl: guildIconUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'guild_id': guildId,
        'guild_name': guildName,
        'channel_id': channelId,
        'channel_name': channelName,
        if (guildIconUrl != null) 'guild_icon_url': guildIconUrl,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EligibleChannel &&
        other.guildId == guildId &&
        other.guildName == guildName &&
        other.channelId == channelId &&
        other.channelName == channelName &&
        other.guildIconUrl == guildIconUrl;
  }

  @override
  int get hashCode =>
      Object.hash(guildId, guildName, channelId, channelName, guildIconUrl);

  @override
  String toString() =>
      'EligibleChannel(guildId: $guildId, channelId: $channelId, channelName: $channelName)';
}

/// A Discord server (guild) grouping eligible channels for the current user.
class EligibleGuild {
  const EligibleGuild({
    required this.guildId,
    required this.guildName,
    required this.channels,
    this.guildIconUrl,
  });

  final String guildId;
  final String guildName;
  final List<EligibleChannel> channels;
  final String? guildIconUrl;

  factory EligibleGuild.fromJson(Map<String, dynamic> json) {
    final guildId = (json['guild_id'] ?? json['guildId']) as String?;
    final guildName = (json['guild_name'] ?? json['guildName']) as String?;
    final rawIcon = (json['guild_icon_url'] ?? json['guildIconUrl']) as String?;
    final guildIconUrl =
        (rawIcon != null && rawIcon.trim().isNotEmpty) ? rawIcon.trim() : null;
    final rawChannels = json['channels'] as List<dynamic>? ?? const <dynamic>[];

    if (guildId == null || guildName == null) {
      throw const FormatException('Missing required EligibleGuild fields');
    }

    final channels = rawChannels
        .map(
          (dynamic item) => EligibleChannel.fromJson(
            item as Map<String, dynamic>,
            fallbackGuildId: guildId,
            fallbackGuildName: guildName,
            fallbackGuildIconUrl: guildIconUrl,
          ),
        )
        .toList(growable: false);

    return EligibleGuild(
      guildId: guildId,
      guildName: guildName,
      channels: channels,
      guildIconUrl: guildIconUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'guild_id': guildId,
        'guild_name': guildName,
        if (guildIconUrl != null) 'guild_icon_url': guildIconUrl,
        'channels': channels.map((c) => c.toJson()).toList(growable: false),
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EligibleGuild &&
        other.guildId == guildId &&
        other.guildName == guildName &&
        other.guildIconUrl == guildIconUrl &&
        listEquals(other.channels, channels);
  }

  @override
  int get hashCode =>
      Object.hash(guildId, guildName, guildIconUrl, Object.hashAll(channels));
}
