import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/token_manager.dart';
import '../contracts/preview_repository.dart';
import '../core/http_client.dart';
import '../core/https_validator.dart';
import '../models/channel_models.dart';
import '../models/message_models.dart';
import '../models/orb_error.dart';
import 'sse_parser.dart';

/// Concrete [PreviewRepository] implementing single-flight message preview
/// fetching, stale-response discarding, 401 token refresh retry, and typed
/// [OrbException] error mapping.
class PreviewRepositoryImpl implements PreviewRepository {
  PreviewRepositoryImpl({
    required this._httpClient,
    required this._tokenManager,
    required this._backendBaseUrlProvider,
  });

  final OrbHttpClient _httpClient;
  final TokenManager _tokenManager;
  final String? Function() _backendBaseUrlProvider;

  int _previewEpoch = 0;
  int _streamEpoch = 0;
  Object? _activeRequestToken;
  Completer<List<ChannelMessagePreview>>? _activeCompleter;
  StreamController<ChannelMessageEvent>? _activeStreamController;
  StreamSubscription<SseFrame>? _activeStreamSubscription;
  List<EligibleGuild>? _cachedGuilds;
  List<ChannelMessagePreview>? _cachedMessages;

  Object? get activeRequestToken => _activeRequestToken;
  List<EligibleGuild>? get cachedGuilds => _cachedGuilds;
  List<ChannelMessagePreview>? get cachedMessages => _cachedMessages;
  bool get hasInFlightPreview =>
      _activeCompleter != null && !_activeCompleter!.isCompleted;
  bool get hasActiveStream =>
      _activeStreamController != null && !_activeStreamController!.isClosed;

  @override
  Future<List<EligibleGuild>> fetchEligibleGuilds() async {
    final backendUrl = _requireBackendUrl();
    final uri = HttpsValidator.resolveEndpoint(backendUrl, '/api/v1/channels');
    final startSessionEpoch = _tokenManager.sessionEpoch;

    final response = await _authorizedGetWithRefresh(
      backendUrl: backendUrl,
      uri: uri,
    );

    if (_tokenManager.sessionEpoch != startSessionEpoch) {
      throw const OrbException(
        code: 'session_expired',
        message: 'Session changed while loading channels.',
        state: OrbPreviewState.sessionExpired,
        statusCode: HttpStatus.unauthorized,
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected JSON object from /api/v1/channels');
      }
      final rawGuilds = decoded['guilds'];
      if (rawGuilds is! List<dynamic>) {
        throw const FormatException('Missing guilds list in /api/v1/channels');
      }
      final guilds = rawGuilds
          .map(
            (dynamic item) =>
                EligibleGuild.fromJson(item as Map<String, dynamic>),
          )
          .toList(growable: false);
      _cachedGuilds = guilds;
      return guilds;
    } on FormatException catch (error) {
      throw OrbException(
        code: 'invalid_channels_response',
        message: 'Malformed channels payload: ${error.message}',
        state: OrbPreviewState.networkError,
        statusCode: response.statusCode,
      );
    } on TypeError catch (error) {
      throw OrbException(
        code: 'invalid_channels_response',
        message: 'Malformed channels payload: $error',
        state: OrbPreviewState.networkError,
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<ChannelMessagePreview>> fetchLatestMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) {
    _supersedeActivePreview(newToken: requestToken);

    final myEpoch = _previewEpoch;
    final mySessionEpoch = _tokenManager.sessionEpoch;
    final completer = Completer<List<ChannelMessagePreview>>();
    _activeCompleter = completer;

    bool isStale() =>
        _previewEpoch != myEpoch ||
        _tokenManager.sessionEpoch != mySessionEpoch;

    unawaited(
      _executeLatestMessagesFetch(
        guildId: guildId,
        channelId: channelId,
        completer: completer,
        myEpoch: myEpoch,
        isStale: isStale,
      ),
    );

    return completer.future;
  }

  @override
  Stream<ChannelMessageEvent> subscribeToChannelMessages({
    required String guildId,
    required String channelId,
    required Object requestToken,
  }) {
    _closeActiveStream();
    final myStreamEpoch = _streamEpoch;
    final mySessionEpoch = _tokenManager.sessionEpoch;
    late final StreamController<ChannelMessageEvent> controller;

    bool isStale() =>
        _streamEpoch != myStreamEpoch ||
        _tokenManager.sessionEpoch != mySessionEpoch ||
        controller.isClosed;

    controller = StreamController<ChannelMessageEvent>(
      onCancel: () {
        if (identical(_activeStreamController, controller)) {
          _closeActiveStream();
        }
      },
    );
    _activeStreamController = controller;

    unawaited(
      _pumpChannelStream(
        guildId: guildId,
        channelId: channelId,
        controller: controller,
        myStreamEpoch: myStreamEpoch,
        isStale: isStale,
      ),
    );

    return controller.stream;
  }

  @override
  void cancelActivePreview() {
    _previewEpoch++;
    _activeRequestToken = null;
    _closeActiveStream();
    final active = _activeCompleter;
    _activeCompleter = null;
    if (active != null && !active.isCompleted) {
      active.completeError(_cancelledException());
    }
  }

  @override
  void clearMemory() {
    cancelActivePreview();
    _cachedGuilds = null;
    _cachedMessages = null;
  }

  void _closeActiveStream() {
    _streamEpoch++;
    final subscription = _activeStreamSubscription;
    _activeStreamSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    final controller = _activeStreamController;
    _activeStreamController = null;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  Future<void> _pumpChannelStream({
    required String guildId,
    required String channelId,
    required StreamController<ChannelMessageEvent> controller,
    required int myStreamEpoch,
    required bool Function() isStale,
  }) async {
    try {
      final backendUrl = _requireBackendUrl();
      final encodedGuild = Uri.encodeComponent(guildId);
      final encodedChannel = Uri.encodeComponent(channelId);
      final uri = HttpsValidator.resolveEndpoint(
        backendUrl,
        '/api/v1/guilds/$encodedGuild/channels/$encodedChannel/stream',
      );

      final streamedResponse = await _authorizedStreamGetWithRefresh(
        backendUrl: backendUrl,
        uri: uri,
        isStale: isStale,
      );

      if (isStale()) {
        unawaited(streamedResponse.stream.listen((_) {}).cancel());
        return;
      }

      final doneCompleter = Completer<void>();
      final sub = parseSseByteStream(streamedResponse.stream).listen(
        (SseFrame frame) {
          if (isStale()) {
            _closeActiveStream();
            return;
          }
          final event = ChannelMessageEvent.fromSseFrame(
            eventName: frame.event,
            data: frame.data,
          );
          if (event != null && !controller.isClosed) {
            controller.add(event);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!isStale() && !controller.isClosed) {
            controller.addError(error, stackTrace);
          }
          if (!doneCompleter.isCompleted) {
            doneCompleter.complete();
          }
        },
        onDone: () {
          if (!doneCompleter.isCompleted) {
            doneCompleter.complete();
          }
        },
        cancelOnError: true,
      );

      if (isStale()) {
        await sub.cancel();
        return;
      }

      _activeStreamSubscription = sub;
      await doneCompleter.future;

      if (identical(_activeStreamSubscription, sub)) {
        _activeStreamSubscription = null;
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    } on OrbException catch (error, stackTrace) {
      if (error.state == OrbPreviewState.sessionExpired &&
          _streamEpoch == myStreamEpoch &&
          !controller.isClosed) {
        controller.addError(error, stackTrace);
        await controller.close();
        return;
      }
      if (!isStale() && !controller.isClosed) {
        controller.addError(error, stackTrace);
        await controller.close();
      }
    } catch (error, stackTrace) {
      if (!isStale() && !controller.isClosed) {
        controller.addError(
          OrbException(
            code: 'stream_error',
            message: 'Real-time stream error: $error',
            state: OrbPreviewState.networkError,
          ),
          stackTrace,
        );
        await controller.close();
      }
    } finally {
      if (identical(_activeStreamController, controller)) {
        _activeStreamController = null;
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }

  Future<http.StreamedResponse> _authorizedStreamGetWithRefresh({
    required String backendUrl,
    required Uri uri,
    required bool Function() isStale,
  }) async {
    var accessToken = await _tokenManager.getValidAccessToken(backendUrl);
    if (isStale()) {
      throw _cancelledException();
    }

    var response = await _sendAuthorizedStreamGet(uri, accessToken);
    if (isStale()) {
      unawaited(response.stream.listen((_) {}).cancel());
      throw _cancelledException();
    }

    if (response.statusCode == HttpStatus.unauthorized) {
      await _drainStreamSafely(response);
      final refreshed = await _tokenManager.refreshAccessToken(
        backendUrl,
        failedAccessToken: accessToken,
      );
      if (isStale()) {
        throw _cancelledException();
      }
      accessToken = refreshed.accessToken;
      response = await _sendAuthorizedStreamGet(uri, accessToken);
      if (isStale()) {
        unawaited(response.stream.listen((_) {}).cancel());
        throw _cancelledException();
      }
      if (response.statusCode == HttpStatus.unauthorized) {
        final full = await http.Response.fromStream(response);
        await _tokenManager.invalidateSession(backendUrl);
        throw OrbHttpClient.mapHttpError(full);
      }
    }

    if (response.statusCode != HttpStatus.ok) {
      final full = await http.Response.fromStream(response);
      throw OrbHttpClient.mapHttpError(full);
    }

    return response;
  }

  Future<http.StreamedResponse> _sendAuthorizedStreamGet(
    Uri uri,
    String accessToken,
  ) {
    final request = http.Request('GET', uri)
      ..headers['authorization'] = 'Bearer $accessToken'
      ..headers['accept'] = 'text/event-stream'
      ..headers['cache-control'] = 'no-cache';
    return _httpClient.send(request);
  }

  static Future<void> _drainStreamSafely(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>();
    } catch (_) {
      // Ignore drain errors on rejected streams.
    }
  }

  void _supersedeActivePreview({required Object newToken}) {
    _previewEpoch++;
    _activeRequestToken = newToken;
    final previous = _activeCompleter;
    _activeCompleter = null;
    if (previous != null && !previous.isCompleted) {
      previous.completeError(_cancelledException());
    }
  }

  Future<void> _executeLatestMessagesFetch({
    required String guildId,
    required String channelId,
    required Completer<List<ChannelMessagePreview>> completer,
    required int myEpoch,
    required bool Function() isStale,
  }) async {
    try {
      final backendUrl = _requireBackendUrl();
      final encodedGuild = Uri.encodeComponent(guildId);
      final encodedChannel = Uri.encodeComponent(channelId);
      final uri = HttpsValidator.resolveEndpoint(
        backendUrl,
        '/api/v1/guilds/$encodedGuild/channels/$encodedChannel/messages',
      );

      final response = await _authorizedGetWithRefresh(
        backendUrl: backendUrl,
        uri: uri,
        isStale: isStale,
      );

      if (isStale()) {
        _completeCancelledIfOpen(completer);
        return;
      }

      final messages = _parseMessagesResponse(response);
      if (isStale()) {
        _completeCancelledIfOpen(completer);
        return;
      }

      _cachedMessages = messages;
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.complete(messages);
      }
    } on OrbException catch (error, stackTrace) {
      if (error.state == OrbPreviewState.sessionExpired &&
          _previewEpoch == myEpoch) {
        if (identical(_activeCompleter, completer)) {
          _activeCompleter = null;
        }
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
        return;
      }
      if (isStale()) {
        _completeCancelledIfOpen(completer);
        return;
      }
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    } catch (error, stackTrace) {
      if (isStale()) {
        _completeCancelledIfOpen(completer);
        return;
      }
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  List<ChannelMessagePreview> _parseMessagesResponse(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected JSON object from messages API');
      }
      final rawMessages = decoded['messages'];
      if (rawMessages is! List<dynamic>) {
        throw const FormatException('Missing messages list in response');
      }
      return rawMessages
          .map(
            (dynamic item) =>
                ChannelMessagePreview.fromJson(item as Map<String, dynamic>),
          )
          .toList(growable: false);
    } on FormatException catch (error) {
      throw OrbException(
        code: 'invalid_messages_response',
        message: 'Malformed messages payload: ${error.message}',
        state: OrbPreviewState.networkError,
        statusCode: response.statusCode,
      );
    } on TypeError catch (error) {
      throw OrbException(
        code: 'invalid_messages_response',
        message: 'Malformed messages payload: $error',
        state: OrbPreviewState.networkError,
        statusCode: response.statusCode,
      );
    }
  }

  Future<http.Response> _authorizedGetWithRefresh({
    required String backendUrl,
    required Uri uri,
    bool Function()? isStale,
  }) async {
    var accessToken = await _tokenManager.getValidAccessToken(backendUrl);
    if (isStale?.call() ?? false) {
      throw _cancelledException();
    }

    var response = await _sendAuthorizedGet(uri, accessToken);
    if (isStale?.call() ?? false) {
      throw _cancelledException();
    }

    if (response.statusCode == HttpStatus.unauthorized) {
      final refreshed = await _tokenManager.refreshAccessToken(
        backendUrl,
        failedAccessToken: accessToken,
      );
      if (isStale?.call() ?? false) {
        throw _cancelledException();
      }
      accessToken = refreshed.accessToken;
      response = await _sendAuthorizedGet(uri, accessToken);
      if (isStale?.call() ?? false) {
        throw _cancelledException();
      }
      if (response.statusCode == HttpStatus.unauthorized) {
        await _tokenManager.invalidateSession(backendUrl);
        throw OrbHttpClient.mapHttpError(response);
      }
    }

    if (response.statusCode != HttpStatus.ok) {
      throw OrbHttpClient.mapHttpError(response);
    }

    return response;
  }

  Future<http.Response> _sendAuthorizedGet(Uri uri, String accessToken) {
    return _httpClient.get(
      uri,
      headers: <String, String>{
        'authorization': 'Bearer $accessToken',
        'accept': 'application/json',
      },
    );
  }

  String _requireBackendUrl() {
    final url = _backendBaseUrlProvider();
    if (url == null || url.trim().isEmpty) {
      throw const OrbException(
        code: 'backend_not_configured',
        message: 'Backend URL is not configured.',
        state: OrbPreviewState.networkError,
      );
    }
    return url;
  }

  void _completeCancelledIfOpen(
    Completer<List<ChannelMessagePreview>> completer,
  ) {
    if (identical(_activeCompleter, completer)) {
      _activeCompleter = null;
    }
    if (!completer.isCompleted) {
      completer.completeError(_cancelledException());
    }
  }

  static OrbException _cancelledException() => const OrbException(
        code: 'preview_cancelled',
        message: 'Preview request was cancelled or superseded.',
        state: OrbPreviewState.idle,
      );
}
