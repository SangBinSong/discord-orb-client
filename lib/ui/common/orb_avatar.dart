import 'package:flutter/material.dart';

/// Circular user avatar or guild icon with deterministic color & initials
/// fallback when no HTTPS URL is available or image loading fails.
class OrbAvatar extends StatelessWidget {
  const OrbAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = 24,
  });

  final String name;
  final String? imageUrl;
  final double size;

  static const List<Color> _palette = <Color>[
    Color(0xFF5865F2), // Blurple
    Color(0xFF3BA55D), // Green
    Color(0xFFED4245), // Red
    Color(0xFFFAA61A), // Amber
    Color(0xFFEB459E), // Fuchsia
    Color(0xFF00A8FC), // Cyan
    Color(0xFF9B59B6), // Purple
    Color(0xFF1ABC9C), // Teal
  ];

  /// Computes 1–2 uppercase initials from [name] for deterministic fallback.
  static String initialsFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return '?';
    }
    final words = trimmed
        .split(RegExp(r'\s+'))
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    if (words.length >= 2) {
      return '${_firstChar(words[0])}${_firstChar(words[1])}'.toUpperCase();
    }
    final single = words.first;
    final runes = single.runes.take(2).toList(growable: false);
    return String.fromCharCodes(runes).toUpperCase();
  }

  /// Selects a deterministic background color for [name].
  static Color colorFor(String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) {
      return _palette.first;
    }
    var hash = 0;
    for (final codeUnit in normalized.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0x7fffffff;
    }
    return _palette[hash % _palette.length];
  }

  static String _firstChar(String value) {
    final first = value.runes.first;
    return String.fromCharCode(first);
  }

  String? _validHttpsUrl() {
    final raw = imageUrl?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return null;
    }
    return uri.toString();
  }

  @override
  Widget build(BuildContext context) {
    final initials = initialsFor(name);
    final backgroundColor = colorFor(name);
    final fontSize = (size * 0.44).clamp(8.0, 18.0);

    final Widget fallback = ColoredBox(
      color: backgroundColor,
      child: Center(
        child: Text(
          initials,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );

    final validUrl = _validHttpsUrl();

    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: validUrl == null
            ? fallback
            : Image.network(
                validUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (
                  BuildContext context,
                  Object error,
                  StackTrace? stackTrace,
                ) =>
                    fallback,
                loadingBuilder: (
                  BuildContext context,
                  Widget child,
                  ImageChunkEvent? loadingProgress,
                ) {
                  if (loadingProgress == null) {
                    return child;
                  }
                  return fallback;
                },
              ),
      ),
    );
  }
}
