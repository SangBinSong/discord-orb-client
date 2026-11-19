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
  Object? _activeRequestToken;
  Completer<List<ChannelMessagePreview>>? _activeCompleter;
  List<EligibleGuild>? _cachedGuilds;
  List<ChannelMessagePreview>? _cachedMessages;

  Object? get activeRequestToken => _activeRequestToken;
  List<EligibleGuild>? get cachedGuilds => _cachedGuilds;
  List<ChannelMessagePreview>? get cachedMessages => _cachedMessages;
  bool get hasInFlightPreview =>
      _activeCompleter != null && !_activeCompleter!.isCompleted;

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
  void cancelActivePreview() {
    _previewEpoch++;
    _activeRequestToken = null;
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
