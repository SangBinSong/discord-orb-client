import 'dart:async';
import 'dart:convert';

/// Parsed Server-Sent Events (SSE) frame.
class SseFrame {
  const SseFrame({
    this.event,
    required this.data,
    this.id,
    this.retry,
  });

  final String? event;
  final String data;
  final String? id;
  final Duration? retry;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SseFrame &&
        other.event == event &&
        other.data == data &&
        other.id == id &&
        other.retry == retry;
  }

  @override
  int get hashCode => Object.hash(event, data, id, retry);
}

/// Decodes a UTF-8 HTTP byte stream into WHATWG Server-Sent Events frames.
Stream<SseFrame> parseSseByteStream(Stream<List<int>> byteStream) {
  final lines = byteStream
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  return parseSseLineStream(lines);
}

/// Parses already line-split UTF-8 SSE text lines into [SseFrame] objects.
///
/// Uses an explicit [StreamController] so cancelling the returned stream
/// immediately cancels the upstream HTTP line/byte subscription even while idle.
/// Comment lines (such as `: keepalive`) are silently ignored.
Stream<SseFrame> parseSseLineStream(Stream<String> lines) {
  late final StreamController<SseFrame> controller;
  StreamSubscription<String>? lineSubscription;

  String? eventName;
  String? lastId;
  Duration? retry;
  final dataLines = <String>[];

  controller = StreamController<SseFrame>(
    onListen: () {
      lineSubscription = lines.listen(
        (String rawLine) {
          final line =
              rawLine.startsWith('\uFEFF') ? rawLine.substring(1) : rawLine;

          if (line.isEmpty) {
            if (dataLines.isNotEmpty) {
              controller.add(
                SseFrame(
                  event: eventName,
                  data: dataLines.join('\n'),
                  id: lastId,
                  retry: retry,
                ),
              );
            }
            eventName = null;
            retry = null;
            dataLines.clear();
            return;
          }

          // Comment / keepalive line.
          if (line.startsWith(':')) {
            return;
          }

          final colonIndex = line.indexOf(':');
          final String field;
          final String value;
          if (colonIndex == -1) {
            field = line;
            value = '';
          } else {
            field = line.substring(0, colonIndex);
            final rawValue = line.substring(colonIndex + 1);
            value = rawValue.startsWith(' ') ? rawValue.substring(1) : rawValue;
          }

          switch (field) {
            case 'event':
              eventName = value;
            case 'data':
              dataLines.add(value);
            case 'id':
              if (!value.contains('\u0000')) {
                lastId = value;
              }
            case 'retry':
              final ms = int.tryParse(value);
              if (ms != null && ms >= 0) {
                retry = Duration(milliseconds: ms);
              }
            default:
              // Ignore unrecognized SSE fields per spec.
              break;
          }
        },
        onError: controller.addError,
        onDone: () {
          if (!controller.isClosed) {
            unawaited(controller.close());
          }
        },
        cancelOnError: false,
      );
    },
    onPause: () => lineSubscription?.pause(),
    onResume: () => lineSubscription?.resume(),
    onCancel: () {
      final sub = lineSubscription;
      lineSubscription = null;
      return sub?.cancel();
    },
  );

  return controller.stream;
}
