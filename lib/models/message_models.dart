import 'dart:convert';

/// Density layout mode for displaying messages inside the Discord Orb panel.
enum ChatListLayout {
  standard,
  compact;

  String get storageValue => name;

  static ChatListLayout fromStorageValue(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'compact' => ChatListLayout.compact,
      _ => ChatListLayout.standard,
    };
  }
}

/// Text-only message preview item displayed inside the Discord Orb panel.
class ChannelMessagePreview {
  const ChannelMessagePreview({
    required this.id,
    required this.authorName,
    this.authorAvatarUrl,
    required this.timestamp,
    required this.content,
  });

  final String id;
  final String authorName;
  final String? authorAvatarUrl;
  final DateTime timestamp;
  final String content;

  ChannelMessagePreview copyWith({
    String? id,
    String? authorName,
    String? authorAvatarUrl,
    DateTime? timestamp,
    String? content,
  }) {
    return ChannelMessagePreview(
      id: id ?? this.id,
      authorName: authorName ?? this.authorName,
      authorAvatarUrl: authorAvatarUrl ?? this.authorAvatarUrl,
      timestamp: timestamp ?? this.timestamp,
      content: content ?? this.content,
    );
  }

  factory ChannelMessagePreview.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final authorName = (json['author_name'] ?? json['authorName']) as String?;
    final timestampRaw = json['timestamp'] as String?;
    final content = json['content'] as String?;
    final avatarRaw =
        (json['author_avatar_url'] ?? json['authorAvatarUrl']) as String?;
    final authorAvatarUrl =
        (avatarRaw != null && avatarRaw.trim().isNotEmpty)
            ? avatarRaw.trim()
            : null;

    if (id == null ||
        authorName == null ||
        timestampRaw == null ||
        content == null) {
      throw const FormatException(
        'Missing required ChannelMessagePreview fields',
      );
    }

    return ChannelMessagePreview(
      id: id,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
      timestamp: DateTime.parse(timestampRaw).toUtc(),
      content: content,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'author_name': authorName,
        if (authorAvatarUrl != null) 'author_avatar_url': authorAvatarUrl,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'content': content,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChannelMessagePreview &&
        other.id == id &&
        other.authorName == authorName &&
        other.authorAvatarUrl == authorAvatarUrl &&
        other.timestamp.toUtc() == timestamp.toUtc() &&
        other.content == content;
  }

  @override
  int get hashCode =>
      Object.hash(id, authorName, authorAvatarUrl, timestamp.toUtc(), content);
}

/// Real-time SSE event types emitted by the backend channel stream.
enum ChannelMessageEventType {
  ready,
  create,
  update,
  delete,
}

/// Normalized real-time channel event delivered over SSE.
class ChannelMessageEvent {
  const ChannelMessageEvent._({
    required this.type,
    this.guildId,
    this.channelId,
    this.message,
    this.messageId,
    this.authorName,
    this.authorAvatarUrl,
    this.timestamp,
    this.content,
  });

  const ChannelMessageEvent.ready({
    String? guildId,
    String? channelId,
  }) : this._(
          type: ChannelMessageEventType.ready,
          guildId: guildId,
          channelId: channelId,
        );

  ChannelMessageEvent.create({
    String? guildId,
    String? channelId,
    required ChannelMessagePreview message,
  }) : this._(
          type: ChannelMessageEventType.create,
          guildId: guildId,
          channelId: channelId,
          message: message,
          messageId: message.id,
          authorName: message.authorName,
          authorAvatarUrl: message.authorAvatarUrl,
          timestamp: message.timestamp,
          content: message.content,
        );

  const ChannelMessageEvent.update({
    String? guildId,
    String? channelId,
    required String messageId,
    ChannelMessagePreview? message,
    String? authorName,
    String? authorAvatarUrl,
    DateTime? timestamp,
    String? content,
  }) : this._(
          type: ChannelMessageEventType.update,
          guildId: guildId,
          channelId: channelId,
          message: message,
          messageId: messageId,
          authorName: authorName,
          authorAvatarUrl: authorAvatarUrl,
          timestamp: timestamp,
          content: content,
        );

  const ChannelMessageEvent.delete({
    String? guildId,
    String? channelId,
    required String messageId,
  }) : this._(
          type: ChannelMessageEventType.delete,
          guildId: guildId,
          channelId: channelId,
          messageId: messageId,
        );

  final ChannelMessageEventType type;
  final String? guildId;
  final String? channelId;
  final ChannelMessagePreview? message;
  final String? messageId;
  final String? authorName;
  final String? authorAvatarUrl;
  final DateTime? timestamp;
  final String? content;

  /// Parses an SSE `event` + JSON `data` pair into a [ChannelMessageEvent].
  /// Returns `null` for unrecognized or malformed frames so streams stay resilient.
  static ChannelMessageEvent? fromSseFrame({
    required String? eventName,
    required String data,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final resolvedType =
        (eventName?.trim().isNotEmpty ?? false)
            ? eventName!.trim()
            : (decoded['type'] as String?)?.trim();
    final guildId = decoded['guild_id'] as String?;
    final channelId = decoded['channel_id'] as String?;

    switch (resolvedType) {
      case 'ready':
        return ChannelMessageEvent.ready(
          guildId: guildId,
          channelId: channelId,
        );
      case 'message_create':
        final rawMessage = decoded['message'];
        if (rawMessage is! Map<String, dynamic>) return null;
        try {
          return ChannelMessageEvent.create(
            guildId: guildId,
            channelId: channelId,
            message: ChannelMessagePreview.fromJson(rawMessage),
          );
        } on FormatException {
          return null;
        } on TypeError {
          return null;
        }
      case 'message_update':
        final rawMessage = decoded['message'];
        if (rawMessage is! Map<String, dynamic>) return null;
        final id = rawMessage['id'] as String?;
        if (id == null || id.isEmpty) return null;
        final authorName =
            (rawMessage['author_name'] ?? rawMessage['authorName']) as String?;
        final authorAvatarUrl = (rawMessage['author_avatar_url'] ??
            rawMessage['authorAvatarUrl']) as String?;
        final timestampRaw = rawMessage['timestamp'] as String?;
        final content = rawMessage['content'] as String?;
        DateTime? parsedTimestamp;
        if (timestampRaw != null) {
          try {
            parsedTimestamp = DateTime.parse(timestampRaw).toUtc();
          } on FormatException {
            return null;
          }
        }
        final fullMessage =
            (authorName != null && parsedTimestamp != null && content != null)
                ? ChannelMessagePreview(
                    id: id,
                    authorName: authorName,
                    authorAvatarUrl: authorAvatarUrl,
                    timestamp: parsedTimestamp,
                    content: content,
                  )
                : null;
        return ChannelMessageEvent.update(
          guildId: guildId,
          channelId: channelId,
          messageId: id,
          message: fullMessage,
          authorName: authorName,
          authorAvatarUrl: authorAvatarUrl,
          timestamp: parsedTimestamp,
          content: content,
        );
      case 'message_delete':
        final deletedId =
            (decoded['message_id'] ?? decoded['id']) as String?;
        if (deletedId == null || deletedId.isEmpty) return null;
        return ChannelMessageEvent.delete(
          guildId: guildId,
          channelId: channelId,
          messageId: deletedId,
        );
      default:
        return null;
    }
  }
}

/// Applies an incoming real-time [event] to [current] messages, deduplicating
/// by message ID, preserving newest-first ordering, and capping at [maxMessages].
List<ChannelMessagePreview> mergeChannelMessageEvent(
  List<ChannelMessagePreview> current,
  ChannelMessageEvent event, {
  int maxMessages = 10,
}) {
  switch (event.type) {
    case ChannelMessageEventType.ready:
      return current;
    case ChannelMessageEventType.create:
      final incoming = event.message;
      if (incoming == null) return current;
      final merged = <ChannelMessagePreview>[
        incoming,
        for (final item in current)
          if (item.id != incoming.id) item,
      ];
      return _sortAndCapMessages(merged, maxMessages: maxMessages);
    case ChannelMessageEventType.update:
      final targetId = event.messageId;
      if (targetId == null || targetId.isEmpty) return current;
      var found = false;
      final merged = <ChannelMessagePreview>[];
      for (final item in current) {
        if (item.id == targetId) {
          found = true;
          merged.add(
            item.copyWith(
              authorName: event.authorName,
              authorAvatarUrl: event.authorAvatarUrl,
              timestamp: event.timestamp,
              content: event.content,
            ),
          );
        } else {
          merged.add(item);
        }
      }
      if (!found && event.message != null) {
        merged.add(event.message!);
      }
      return _sortAndCapMessages(merged, maxMessages: maxMessages);
    case ChannelMessageEventType.delete:
      final deletedId = event.messageId;
      if (deletedId == null || deletedId.isEmpty) return current;
      return current
          .where((ChannelMessagePreview item) => item.id != deletedId)
          .toList(growable: false);
  }
}

List<ChannelMessagePreview> _sortAndCapMessages(
  List<ChannelMessagePreview> source, {
  required int maxMessages,
}) {
  if (source.isEmpty) {
    return const <ChannelMessagePreview>[];
  }
  final indexed = source.indexed.toList(growable: false);
  indexed.sort(((int, ChannelMessagePreview) a, (int, ChannelMessagePreview) b) {
    final timeCmp = b.$2.timestamp.toUtc().compareTo(a.$2.timestamp.toUtc());
    if (timeCmp != 0) {
      return timeCmp;
    }
    return a.$1.compareTo(b.$1);
  });
  return indexed
      .take(maxMessages)
      .map(((int, ChannelMessagePreview) entry) => entry.$2)
      .toList(growable: false);
}
