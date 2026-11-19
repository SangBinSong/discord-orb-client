import 'package:flutter/foundation.dart';

/// A Discord text channel that both the signed-in user and the bot can read.
class EligibleChannel {
  const EligibleChannel({
    required this.guildId,
    required this.guildName,
    required this.channelId,
    required this.channelName,
  });

  final String guildId;
  final String guildName;
  final String channelId;
  final String channelName;

  factory EligibleChannel.fromJson(
    Map<String, dynamic> json, {
    String? fallbackGuildId,
    String? fallbackGuildName,
  }) {
    final guildId =
        (json['guild_id'] ?? json['guildId'] ?? fallbackGuildId) as String?;
    final guildName = (json['guild_name'] ??
        json['guildName'] ??
        fallbackGuildName) as String?;
    final channelId = (json['channel_id'] ?? json['channelId']) as String?;
    final channelName =
        (json['channel_name'] ?? json['channelName']) as String?;

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
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'guild_id': guildId,
        'guild_name': guildName,
        'channel_id': channelId,
        'channel_name': channelName,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EligibleChannel &&
        other.guildId == guildId &&
        other.guildName == guildName &&
        other.channelId == channelId &&
        other.channelName == channelName;
  }

  @override
  int get hashCode => Object.hash(guildId, guildName, channelId, channelName);

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
  });

  final String guildId;
  final String guildName;
  final List<EligibleChannel> channels;

  factory EligibleGuild.fromJson(Map<String, dynamic> json) {
    final guildId = (json['guild_id'] ?? json['guildId']) as String?;
    final guildName = (json['guild_name'] ?? json['guildName']) as String?;
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
          ),
        )
        .toList(growable: false);

    return EligibleGuild(
      guildId: guildId,
      guildName: guildName,
      channels: channels,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'guild_id': guildId,
        'guild_name': guildName,
        'channels': channels.map((c) => c.toJson()).toList(growable: false),
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EligibleGuild &&
        other.guildId == guildId &&
        other.guildName == guildName &&
        listEquals(other.channels, channels);
  }

  @override
  int get hashCode =>
      Object.hash(guildId, guildName, Object.hashAll(channels));
}
