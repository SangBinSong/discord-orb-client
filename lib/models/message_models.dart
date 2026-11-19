/// Text-only message preview item displayed inside the Discord Orb panel.
class ChannelMessagePreview {
  const ChannelMessagePreview({
    required this.id,
    required this.authorName,
    required this.timestamp,
    required this.content,
  });

  final String id;
  final String authorName;
  final DateTime timestamp;
  final String content;

  factory ChannelMessagePreview.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final authorName = (json['author_name'] ?? json['authorName']) as String?;
    final timestampRaw = json['timestamp'] as String?;
    final content = json['content'] as String?;

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
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'author_name': authorName,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'content': content,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChannelMessagePreview &&
        other.id == id &&
        other.authorName == authorName &&
        other.timestamp.toUtc() == timestamp.toUtc() &&
        other.content == content;
  }

  @override
  int get hashCode =>
      Object.hash(id, authorName, timestamp.toUtc(), content);
}
