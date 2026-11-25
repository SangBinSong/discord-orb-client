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
    required this.timestamp,
    required this.content,
    this.authorAvatarUrl,
  });

  final String id;
  final String authorName;
  final DateTime timestamp;
  final String content;
  final String? authorAvatarUrl;

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
      timestamp: DateTime.parse(timestampRaw).toUtc(),
      content: content,
      authorAvatarUrl: authorAvatarUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'author_name': authorName,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'content': content,
        if (authorAvatarUrl != null) 'author_avatar_url': authorAvatarUrl,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChannelMessagePreview &&
        other.id == id &&
        other.authorName == authorName &&
        other.timestamp.toUtc() == timestamp.toUtc() &&
        other.content == content &&
        other.authorAvatarUrl == authorAvatarUrl;
  }

  @override
  int get hashCode => Object.hash(
        id,
        authorName,
        timestamp.toUtc(),
        content,
        authorAvatarUrl,
      );
}
