import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'models.dart';

/// Fehler vom Server oder Netzwerk – [message] ist immer eine verständliche deutsche Meldung.
class ApiException implements Exception {
  final int? statusCode;
  final String message;
  const ApiException(this.message, {this.statusCode});

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isNetwork => statusCode == null;

  @override
  String toString() => message;
}

/// Wandelt Dio-Fehler in [ApiException] um ({"detail": "..."} vom Server).
ApiException toApiException(Object error) {
  if (error is ApiException) return error;
  if (error is DioException) {
    final response = error.response;
    if (response == null) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout =>
          const ApiException('Der Server antwortet nicht (Zeitüberschreitung).'),
        DioExceptionType.badCertificate => const ApiException('Das HTTPS-Zertifikat des Servers ist ungültig.'),
        DioExceptionType.cancel => const ApiException('Abgebrochen.'),
        _ => const ApiException('Server nicht erreichbar. Bist du online?'),
      };
    }
    final data = response.data;
    String? detail;
    if (data is Map && data['detail'] != null) {
      final raw = data['detail'];
      if (raw is String) {
        detail = raw;
      } else if (raw is List && raw.isNotEmpty) {
        // Pydantic-Validierungsfehler
        final first = raw.first;
        detail = first is Map ? 'Ungültige Eingabe: ${first['msg'] ?? first}' : raw.first.toString();
      }
    }
    final status = response.statusCode;
    detail ??= switch (status) {
      401 => 'Bitte neu anmelden.',
      403 => 'Dafür fehlen dir die Rechte.',
      404 => 'Nicht gefunden.',
      413 => 'Die Datei ist zu groß.',
      429 => 'Zu viele Versuche – bitte kurz warten.',
      502 || 503 || 504 => 'Der Server ist gerade nicht erreichbar.',
      _ => 'Fehler $status',
    };
    return ApiException(detail, statusCode: status);
  }
  return ApiException(error.toString());
}

/// Ergebnis einer Anmeldung.
class LoginResult {
  final Tokens tokens;
  final User user;
  const LoginResult(this.tokens, this.user);
}

String normalizeBaseUrl(String input) {
  var url = input.trim();
  if (url.isEmpty) return url;
  final scheme = RegExp(r'^(https?)://', caseSensitive: false).firstMatch(url);
  if (scheme == null) {
    url = 'https://$url';
  } else {
    url = '${scheme.group(1)!.toLowerCase()}://${url.substring(scheme.end)}';
  }
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  if (url.endsWith('/api')) url = url.substring(0, url.length - 4);
  return url;
}

String defaultDeviceName() {
  final system = Platform.isIOS ? 'iPhone/iPad' : (Platform.isAndroid ? 'Android' : Platform.operatingSystem);
  String host = '';
  try {
    host = Platform.localHostname;
  } catch (_) {}
  return host.isEmpty || host == 'localhost' ? '$system-App' : '$system · $host';
}

Dio _plainDio(String baseUrl) => Dio(BaseOptions(
      baseUrl: '$baseUrl/api',
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept': 'application/json'},
    ));

/// Zugriff auf den Selfify-Server. Erneuert abgelaufene Anmeldungen automatisch.
class ApiClient {
  final String baseUrl;
  Tokens _tokens;
  final void Function(Tokens tokens) onTokens;
  final void Function() onSessionExpired;
  late final Dio _dio;
  late final Dio _refreshDio;
  Completer<Tokens>? _refreshing;

  ApiClient({
    required this.baseUrl,
    required this._tokens,
    required this.onTokens,
    required this.onSessionExpired,
  }) {
    _dio = _plainDio(baseUrl);
    _refreshDio = _plainDio(baseUrl);
    _dio.interceptors.add(QueuedInterceptorsWrapper(
      onRequest: (options, handler) async {
        if (_tokens.accessExpiringSoon) {
          try {
            await refresh();
          } catch (_) {
            // Fehler kommt gleich als 401 – dort wird es behandelt
          }
        }
        options.headers['Authorization'] = 'Bearer ${_tokens.accessToken}';
        handler.next(options);
      },
      onError: (error, handler) async {
        final request = error.requestOptions;
        if (error.response?.statusCode != 401 || request.extra['retried'] == true) {
          return handler.next(error);
        }
        try {
          await refresh();
          request.extra['retried'] = true;
          request.headers['Authorization'] = 'Bearer ${_tokens.accessToken}';
          handler.resolve(await _dio.fetch(request));
        } catch (e) {
          handler.next(error);
        }
      },
    ));
  }

  Tokens get tokens => _tokens;
  String get mediaToken => _tokens.mediaToken;

  // ------------------------------------------------------------ Anmeldung (ohne Konto)

  /// Prüft, ob unter der Adresse ein Selfify-Server läuft.
  static Future<ServerInfo> probe(String baseUrl) async {
    try {
      final response = await _plainDio(baseUrl).get('/server');
      return ServerInfo.fromJson(response.data as Json);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw const ApiException('Unter dieser Adresse läuft kein Selfify-Server.');
      }
      throw toApiException(e);
    } on FormatException {
      throw const ApiException('Unter dieser Adresse läuft kein Selfify-Server.');
    } on TypeError {
      throw const ApiException('Unter dieser Adresse läuft kein Selfify-Server.');
    }
  }

  static Future<LoginResult> login(String baseUrl, String username, String password, {String? deviceName}) async {
    try {
      final response = await _plainDio(baseUrl).post('/auth/login', data: {
        'username': username,
        'password': password,
        'device_name': deviceName ?? defaultDeviceName(),
      });
      final data = response.data as Json;
      return LoginResult(Tokens.fromResponse(data), User.fromJson(data['user'] as Json));
    } catch (e) {
      throw toApiException(e);
    }
  }

  /// Holt neue Token (mehrere gleichzeitige Aufrufe teilen sich eine Erneuerung).
  Future<Tokens> refresh() async {
    final running = _refreshing;
    if (running != null) return running.future;
    final completer = Completer<Tokens>();
    _refreshing = completer;
    completer.future.ignore();
    try {
      final response = await _refreshDio.post('/auth/refresh', data: {'refresh_token': _tokens.refreshToken});
      _tokens = Tokens.fromResponse(response.data as Json);
      onTokens(_tokens);
      completer.complete(_tokens);
      return _tokens;
    } catch (e) {
      final error = toApiException(e);
      if (error.isUnauthorized) onSessionExpired();
      completer.completeError(error);
      throw error;
    } finally {
      _refreshing = null;
    }
  }

  // ------------------------------------------------------------ Hilfen

  Future<T> _get<T>(String path, T Function(dynamic data) parse, {Map<String, dynamic>? query}) async {
    try {
      final response = await _dio.get(path, queryParameters: _clean(query));
      return parse(response.data);
    } catch (e) {
      throw toApiException(e);
    }
  }

  Future<T> _send<T>(String method, String path, T Function(dynamic data) parse,
      {Object? body, Map<String, dynamic>? query}) async {
    try {
      final response = await _dio.request(path,
          data: body, queryParameters: _clean(query), options: Options(method: method));
      return parse(response.data);
    } catch (e) {
      throw toApiException(e);
    }
  }

  Future<void> _noContent(String method, String path, {Object? body, Map<String, dynamic>? query}) =>
      _send(method, path, (_) {}, body: body, query: query);

  static Map<String, dynamic>? _clean(Map<String, dynamic>? query) =>
      query == null ? null : (Map.of(query)..removeWhere((key, value) => value == null));

  static List<T> _listOf<T>(dynamic data, T Function(Json) parse) =>
      (data as List).map((e) => parse(e as Json)).toList();

  // ------------------------------------------------------------ Links für Player/Bilder

  /// Stream-Link mit Medien-Token. [compatible] = für iPhones (Opus -> AAC).
  String streamUrl(int trackId, {String quality = 'original', bool compatible = false}) {
    final params = <String, String>{'t': _tokens.mediaToken};
    if (quality != 'original') params['quality'] = quality;
    if (compatible) params['compatible'] = 'true';
    return Uri.parse('$baseUrl/api/tracks/$trackId/stream').replace(queryParameters: params).toString();
  }

  String coverUrl(String coverId, {int size = 300}) =>
      Uri.parse('$baseUrl/api/covers/$coverId').replace(queryParameters: {'size': '$size', 't': _tokens.mediaToken}).toString();

  Uri downloadsWebSocketUri() {
    final base = Uri.parse(baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/api/downloads/ws',
      queryParameters: {'token': _tokens.accessToken},
    );
  }

  /// Datei (Stream) direkt herunterladen – für den Offline-Modus.
  Future<Response<dynamic>> downloadFile(String url, String savePath,
      {void Function(int received, int total)? onProgress, CancelToken? cancelToken}) async {
    try {
      return await _dio.download(url, savePath, onReceiveProgress: onProgress, cancelToken: cancelToken);
    } catch (e) {
      throw toApiException(e);
    }
  }

  // ------------------------------------------------------------ Konto

  Future<ServerInfo> serverInfo() => _get('/server', (d) => ServerInfo.fromJson(d as Json));
  Future<User> me() => _get('/me', (d) => User.fromJson(d as Json));
  Future<User> updateMe({required String displayName}) =>
      _send('PATCH', '/me', (d) => User.fromJson(d as Json), body: {'display_name': displayName});

  Future<Tokens> changePassword(String current, String newPassword) async {
    final tokens = await _send('POST', '/me/password', (d) => Tokens.fromResponse(d as Json),
        body: {'current_password': current, 'new_password': newPassword});
    _tokens = tokens;
    onTokens(tokens);
    return tokens;
  }

  Future<List<DeviceSession>> sessions() => _get('/me/sessions', (d) => _listOf(d, DeviceSession.fromJson));
  Future<void> deleteSession(int id) => _noContent('DELETE', '/me/sessions/$id');
  Future<void> logout() => _noContent('POST', '/auth/logout');

  // ------------------------------------------------------------ Benutzer (Admin)

  Future<List<User>> users() => _get('/users', (d) => _listOf(d, User.fromJson));
  Future<User> createUser({
    required String username,
    required String password,
    String? displayName,
    bool isAdmin = false,
    bool canDownload = true,
  }) =>
      _send('POST', '/users', (d) => User.fromJson(d as Json), body: {
        'username': username,
        'password': password,
        'display_name': displayName,
        'is_admin': isAdmin,
        'can_download': canDownload,
      });
  Future<User> updateUser(int id,
          {String? displayName, String? password, bool? isAdmin, bool? isActive, bool? canDownload}) =>
      _send('PATCH', '/users/$id', (d) => User.fromJson(d as Json), body: _clean({
        'display_name': displayName,
        'password': password,
        'is_admin': isAdmin,
        'is_active': isActive,
        'can_download': canDownload,
      }));
  Future<void> deleteUser(int id) => _noContent('DELETE', '/users/$id');

  // ------------------------------------------------------------ Rubriken

  Future<List<Category>> categories() => _get('/categories', (d) => _listOf(d, Category.fromJson));
  Future<Category> createCategory({required String name, required String mediaType, String? folder, String? icon}) =>
      _send('POST', '/categories', (d) => Category.fromJson(d as Json),
          body: _clean({'name': name, 'media_type': mediaType, 'folder': folder, 'icon': icon}));
  Future<Category> updateCategory(int id, {String? name, String? icon, int? sortOrder, bool? isDefault}) =>
      _send('PATCH', '/categories/$id', (d) => Category.fromJson(d as Json),
          body: _clean({'name': name, 'icon': icon, 'sort_order': sortOrder, 'is_default': isDefault}));
  Future<void> deleteCategory(int id) => _noContent('DELETE', '/categories/$id');

  // ------------------------------------------------------------ Bibliothek

  Future<PageResult<Artist>> artists({int limit = 50, int offset = 0, String sort = 'name', int? categoryId, String? q}) =>
      _get('/artists', (d) => PageResult.fromJson(d as Json, Artist.fromJson),
          query: {'limit': limit, 'offset': offset, 'sort': sort, 'category_id': categoryId, 'q': q});
  Future<ArtistDetail> artist(int id) => _get('/artists/$id', (d) => ArtistDetail.fromJson(d as Json));

  Future<PageResult<Album>> albums(
          {int limit = 50, int offset = 0, String sort = 'title', int? categoryId, int? artistId, String? q}) =>
      _get('/albums', (d) => PageResult.fromJson(d as Json, Album.fromJson), query: {
        'limit': limit,
        'offset': offset,
        'sort': sort,
        'category_id': categoryId,
        'artist_id': artistId,
        'q': q,
      });
  Future<AlbumDetail> album(int id) => _get('/albums/$id', (d) => AlbumDetail.fromJson(d as Json));

  Future<PageResult<Track>> tracks({
    int limit = 50,
    int offset = 0,
    String sort = 'title',
    int? categoryId,
    String? mediaType,
    int? artistId,
    int? albumId,
    String? q,
  }) =>
      _get('/tracks', (d) => PageResult.fromJson(d as Json, Track.fromJson), query: {
        'limit': limit,
        'offset': offset,
        'sort': sort,
        'category_id': categoryId,
        'media_type': mediaType,
        'artist_id': artistId,
        'album_id': albumId,
        'q': q,
      });
  Future<Track> track(int id) => _get('/tracks/$id', (d) => Track.fromJson(d as Json));
  Future<void> deleteTrack(int id, {bool deleteFile = false}) =>
      _noContent('DELETE', '/tracks/$id', query: {'delete_file': deleteFile});

  /// Songtext – null, wenn es keinen gibt.
  Future<Lyrics?> lyrics(int trackId) async {
    try {
      return await _get('/tracks/$trackId/lyrics', (d) => Lyrics.fromJson(d as Json));
    } on ApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  Future<List<Track>> radio(int trackId, {int limit = 50}) =>
      _get('/tracks/$trackId/radio', (d) => _listOf(d, Track.fromJson), query: {'limit': limit});

  Future<SearchResult> search(String q, {int limit = 10, int? categoryId}) =>
      _get('/search', (d) => SearchResult.fromJson(d as Json), query: {'q': q, 'limit': limit, 'category_id': categoryId});

  Future<LibraryStats> libraryStats() => _get('/library', (d) => LibraryStats.fromJson(d as Json));
  Future<ScanStatus> scanStatus() => _get('/library/scan', (d) => ScanStatus.fromJson(d as Json));
  Future<ScanStatus> startScan({int? categoryId}) =>
      _send('POST', '/library/scan', (d) => ScanStatus.fromJson(d as Json), body: {'category_id': categoryId});

  // ------------------------------------------------------------ Playlists

  Future<List<Playlist>> playlists({String scope = 'library'}) =>
      _get('/playlists', (d) => _listOf(d, Playlist.fromJson), query: {'scope': scope});
  Future<PlaylistDetail> playlist(int id) => _get('/playlists/$id', (d) => PlaylistDetail.fromJson(d as Json));
  Future<PlaylistDetail> createPlaylist({
    required String name,
    String description = '',
    bool isPublic = false,
    bool isCollaborative = false,
    List<int> trackIds = const [],
  }) =>
      _send('POST', '/playlists', (d) => PlaylistDetail.fromJson(d as Json), body: {
        'name': name,
        'description': description,
        'is_public': isPublic,
        'is_collaborative': isCollaborative,
        'track_ids': trackIds,
      });
  Future<Playlist> updatePlaylist(int id, {String? name, String? description, bool? isPublic, bool? isCollaborative}) =>
      _send('PATCH', '/playlists/$id', (d) => Playlist.fromJson(d as Json), body: _clean({
        'name': name,
        'description': description,
        'is_public': isPublic,
        'is_collaborative': isCollaborative,
      }));
  Future<void> deletePlaylist(int id) => _noContent('DELETE', '/playlists/$id');
  Future<PlaylistDetail> addToPlaylist(int id, List<int> trackIds, {int? position}) =>
      _send('POST', '/playlists/$id/items', (d) => PlaylistDetail.fromJson(d as Json),
          body: _clean({'track_ids': trackIds, 'position': position}));
  Future<PlaylistDetail> removeFromPlaylist(int id, List<int> itemIds) =>
      _send('POST', '/playlists/$id/items/remove', (d) => PlaylistDetail.fromJson(d as Json), body: {'item_ids': itemIds});
  Future<PlaylistDetail> movePlaylistItem(int id, int itemId, int position) =>
      _send('POST', '/playlists/$id/items/move', (d) => PlaylistDetail.fromJson(d as Json),
          body: {'item_id': itemId, 'position': position});
  Future<Playlist> uploadPlaylistCover(int id, String filePath) async {
    final form = FormData.fromMap({'file': await MultipartFile.fromFile(filePath)});
    return _send('PUT', '/playlists/$id/cover', (d) => Playlist.fromJson(d as Json), body: form);
  }

  Future<Playlist> removePlaylistCover(int id) =>
      _send('DELETE', '/playlists/$id/cover', (d) => Playlist.fromJson(d as Json));
  Future<void> followPlaylist(int id) => _noContent('PUT', '/playlists/$id/follow');
  Future<void> unfollowPlaylist(int id) => _noContent('DELETE', '/playlists/$id/follow');

  // ------------------------------------------------------------ Persönlich

  Future<HomeData> home() => _get('/home', (d) => HomeData.fromJson(d as Json));
  Future<LibraryOverview> library() => _get('/me/library', (d) => LibraryOverview.fromJson(d as Json));
  Future<PageResult<LikedTrack>> likes({int limit = 500, int offset = 0}) =>
      _get('/me/likes', (d) => PageResult.fromJson(d as Json, LikedTrack.fromJson), query: {'limit': limit, 'offset': offset});
  Future<LikedIds> likedIds() => _get('/me/likes/ids', (d) => LikedIds.fromJson(d as Json));
  Future<void> setLiked(int trackId, bool liked) => _noContent(liked ? 'PUT' : 'DELETE', '/me/likes/$trackId');
  Future<void> setAlbumSaved(int albumId, bool saved) => _noContent(saved ? 'PUT' : 'DELETE', '/me/albums/$albumId');
  Future<void> setArtistFollowed(int artistId, bool followed) =>
      _noContent(followed ? 'PUT' : 'DELETE', '/me/artists/$artistId');

  Future<void> addHistory(int trackId, double seconds, {String? contextType, int? contextId}) =>
      _noContent('POST', '/me/history', body: _clean({
        'track_id': trackId,
        'seconds': seconds,
        'context_type': contextType,
        'context_id': contextId,
      }));
  Future<List<HistoryEntry>> history({int limit = 50}) =>
      _get('/me/history', (d) => _listOf(d, HistoryEntry.fromJson), query: {'limit': limit});
  Future<void> clearHistory() => _noContent('DELETE', '/me/history');
  Future<List<ContextItem>> recent({int limit = 20}) =>
      _get('/me/recent', (d) => _listOf(d, ContextItem.fromJson), query: {'limit': limit});
  Future<List<Track>> topTracks({int limit = 50}) =>
      _get('/me/top-tracks', (d) => _listOf(d, Track.fromJson), query: {'limit': limit});
  Future<Mix> mix(String key) => _get('/mixes/${Uri.encodeComponent(key).replaceAll('%3A', ':')}', (d) => Mix.fromJson(d as Json));

  // ------------------------------------------------------------ YouTube & Downloads

  Future<List<YouTubeItem>> youtubeSearch(String q, {String type = 'songs', int limit = 20}) => _get(
      '/youtube/search', (d) => _listOf((d as Json)['results'], YouTubeItem.fromJson),
      query: {'q': q, 'type': type, 'limit': limit});
  Future<YouTubeAlbum> youtubeAlbum(String browseId) =>
      _get('/youtube/albums/$browseId', (d) => YouTubeAlbum.fromJson(d as Json));

  Future<DownloadJob> startDownload({
    required String videoId,
    String mediaType = 'audio',
    int? categoryId,
    int? playlistId,
    String? title,
    List<String> artists = const [],
    String? album,
    int? trackNumber,
    int? year,
    String? thumbnailUrl,
  }) =>
      _send('POST', '/downloads', (d) => DownloadJob.fromJson(d as Json), body: _clean({
        'video_id': videoId,
        'media_type': mediaType,
        'category_id': categoryId,
        'playlist_id': playlistId,
        'title': title,
        'artists': artists,
        'album': album,
        'track_number': trackNumber,
        'year': year,
        'thumbnail_url': thumbnailUrl,
      }));

  /// Einen YouTube-Music-Treffer holen (Song/Video).
  Future<DownloadJob> downloadItem(YouTubeItem item, {int? categoryId, int? playlistId}) => startDownload(
        videoId: item.videoId!,
        mediaType: item.isVideo ? 'video' : 'audio',
        categoryId: categoryId,
        playlistId: playlistId,
        title: item.title,
        artists: item.artists,
        album: item.isVideo ? null : item.album,
        trackNumber: item.trackNumber,
        year: item.year,
        thumbnailUrl: item.thumbnailUrl,
      );

  Future<List<DownloadJob>> downloadAlbum(String browseId, {int? categoryId, int? playlistId}) => _send(
      'POST', '/downloads/album', (d) => _listOf(d, DownloadJob.fromJson),
      body: _clean({'browse_id': browseId, 'category_id': categoryId, 'playlist_id': playlistId}));
  Future<List<DownloadJob>> downloadUrl(String url, {String mediaType = 'audio', int? categoryId, int? playlistId}) =>
      _send('POST', '/downloads/url', (d) => _listOf(d, DownloadJob.fromJson),
          body: _clean({'url': url, 'media_type': mediaType, 'category_id': categoryId, 'playlist_id': playlistId}));
  Future<List<DownloadJob>> downloads({String scope = 'mine', String state = 'all', int limit = 100}) =>
      _get('/downloads', (d) => _listOf(d, DownloadJob.fromJson), query: {'scope': scope, 'state': state, 'limit': limit});
  Future<DownloadJob> download(int id) => _get('/downloads/$id', (d) => DownloadJob.fromJson(d as Json));
  Future<DownloadJob> cancelDownload(int id) =>
      _send('POST', '/downloads/$id/cancel', (d) => DownloadJob.fromJson(d as Json));
  Future<DownloadJob> retryDownload(int id) =>
      _send('POST', '/downloads/$id/retry', (d) => DownloadJob.fromJson(d as Json));
  Future<void> removeDownload(int id) => _noContent('DELETE', '/downloads/$id');
  Future<void> clearFinishedDownloads() => _noContent('DELETE', '/downloads');
  Future<DownloaderStatus> downloaderStatus() =>
      _get('/downloads-system', (d) => DownloaderStatus.fromJson(d as Json));
  Future<DownloaderStatus> updateYtdlp() =>
      _send('POST', '/downloads-system/update', (d) => DownloaderStatus.fromJson(d as Json));
}
