import '../models/channel_models.dart';
import '../models/message_models.dart';

/// Fetches eligible Discord channels and latest text message previews.
abstract interface class PreviewRepository {
  Future<List<EligibleGuild>> fetchEligibleGuilds();
  Future<List<ChannelMessagePreview>> fetchLatestMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  });
  Stream<ChannelMessageEvent> subscribeToChannelMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  });
  void cancelActivePreview();
  void clearMemory();
}
