// Testdaten und nachgestellte Server-/Plugin-Teile für Bildschirm-Tests.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:selfify/core/theme.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/app_update.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/downloads.dart';
import 'package:selfify/state/offline.dart';
import 'package:shared_preferences/shared_preferences.dart';

const coverA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const coverB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const now = '2026-10-10T11:00:00Z';

Json userJson({int id = 1, bool admin = true}) => {
      'id': id,
      'username': admin ? 'papa' : 'lena',
      'display_name': admin ? 'Papa' : 'Lena',
      'is_admin': admin,
      'is_active': true,
      'can_download': true,
      'created_at': now,
      'last_login_at': now,
    };

Json trackJson(int id, {String title = 'Bohemian Rhapsody', String mediaType = 'audio', int? albumId = 7}) => {
      'id': id,
      'title': '$title $id',
      'artist_display': 'Queen feat. Gast',
      'artists': [
        {'id': 3, 'name': 'Queen'},
        {'id': 4, 'name': 'Gast'},
      ],
      'album': albumId == null ? null : {'id': albumId, 'title': 'A Night at the Opera'},
      'category_id': mediaType == 'video' ? 2 : 1,
      'media_type': mediaType,
      'duration': 200 + id,
      'track_number': id,
      'disc_number': 1,
      'year': 1975,
      'genre': 'Rock',
      'codec': mediaType == 'video' ? 'h264' : 'opus',
      'bitrate': 160,
      'width': mediaType == 'video' ? 1920 : null,
      'height': mediaType == 'video' ? 1080 : null,
      'file_size': 4200000,
      'cover_id': id.isEven ? coverA : coverB,
      'cover_color': '#b41e28',
      'source': id == 1 ? 'youtube' : 'local',
      'added_at': now,
    };

Json albumJson(int id, {String title = 'A Night at the Opera'}) => {
      'id': id,
      'title': title,
      'artist': {'id': 3, 'name': 'Queen'},
      'year': 1975,
      'genre': 'Rock',
      'track_count': 3,
      'duration': 640,
      'cover_id': coverA,
      'cover_color': '#b41e28',
      'added_at': now,
    };

Json artistJson(int id, {String name = 'Queen'}) => {
      'id': id,
      'name': name,
      'track_count': 12,
      'album_count': 2,
      'cover_id': coverA,
      'cover_color': '#3a6ea5',
    };

Json playlistJson(int id, {bool owner = true, bool collaborative = false}) => {
      'id': id,
      'name': 'Roadtrip $id',
      'description': 'Für die lange Fahrt',
      'owner': {'id': owner ? 1 : 2, 'display_name': owner ? 'Papa' : 'Lena'},
      'is_public': collaborative,
      'is_collaborative': collaborative,
      'track_count': 3,
      'duration': 640,
      'cover_id': null,
      'mosaic': [coverA, coverB, coverA, coverB],
      'cover_color': '#2d6a4f',
      'created_at': now,
      'updated_at': now,
      'is_owner': owner,
      'is_following': !owner,
      'can_edit': owner || collaborative,
    };

Json categoryJson(int id, String name, String mediaType, String icon) => {
      'id': id,
      'name': name,
      'slug': name.toLowerCase(),
      'folder': name,
      'media_type': mediaType,
      'icon': icon,
      'sort_order': id * 10,
      'is_default': id <= 2,
      'item_count': 42,
    };

Json jobJson(int id, String status, {double progress = 0.45}) => {
      'id': id,
      'status': status,
      'media_type': id.isEven ? 'video' : 'audio',
      'video_id': 'aaaaaaaaa${id.toString().padLeft(2, '0')}',
      'title': 'Mr. Brightside $id',
      'artists': ['The Killers'],
      'album': 'Hot Fuss',
      'thumbnail_url': null,
      'category_id': 1,
      'progress': status == 'done' ? 1.0 : progress,
      'downloaded_bytes': 2000000,
      'total_bytes': 4400000,
      'speed': 1250000.0,
      'eta': 12,
      'queue_position': status == 'queued' ? 1 : null,
      'error': status == 'failed' ? 'Video unavailable. This video is private' : null,
      'track_id': status == 'done' ? 1 : null,
      'playlist_id': null,
      'user': {'id': 1, 'display_name': 'Papa'},
      'created_at': now,
      'started_at': now,
      'finished_at': status == 'done' ? now : null,
    };

Json ytItemJson(int n, {String type = 'song'}) => {
      'type': type,
      'title': 'YouTube Song $n',
      'artists': ['The Killers'],
      'video_id': type == 'album' ? null : 'yyyyyyyyy${n.toString().padLeft(2, '0')}',
      'browse_id': type == 'album' ? 'MPREb_album$n' : null,
      'album': type == 'song' ? 'Hot Fuss' : null,
      'album_browse_id': null,
      'duration': 222,
      'year': 2004,
      'thumbnail_url': null,
      'explicit': n == 2,
      'track_number': n,
      'in_library_track_id': n == 1 ? 1 : null,
      'active_job_id': null,
    };

List<Track> sampleTracks(int count, {String mediaType = 'audio'}) =>
    [for (var i = 1; i <= count; i++) Track.fromJson(trackJson(i, mediaType: mediaType))];

Tokens get fakeTokens => Tokens(
      accessToken: 'acc',
      refreshToken: 'ref',
      mediaToken: 'med',
      accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      mediaExpiresAt: DateTime.now().add(const Duration(days: 7)),
    );

/// Nachgestellter Server: liefert feste Testdaten, merkt sich Aufrufe.
class FakeApi extends ApiClient {
  final calls = <String>[];
  final bool admin;
  /// Antwortzeit für Änderungen (langsamer Server/Mobilfunk)
  Duration writeDelay = Duration.zero;

  FakeApi({this.admin = true})
      : super(baseUrl: 'https://musik.test', tokens: fakeTokens, onTokens: (_) {}, onSessionExpired: () {});

  T _log<T>(String name, T value) {
    calls.add(name);
    return value;
  }

  @override
  Future<ServerInfo> serverInfo() async =>
      _log('serverInfo', const ServerInfo(name: 'Selfify', version: '0.1.0', apiVersion: 1, publicUrl: ''));
  @override
  Future<User> me() async => _log('me', User.fromJson(userJson(admin: admin)));
  @override
  Future<List<DeviceSession>> sessions() async => _log('sessions', [
        DeviceSession.fromJson({
          'id': 1, 'device_name': 'Android · Pixel', 'user_agent': 'Dart/3.12 (dart:io)', 'ip_address': '1.2.3.4',
          'created_at': now, 'last_used_at': now, 'expires_at': now, 'current': true,
        }),
        DeviceSession.fromJson({
          'id': 2, 'device_name': 'iPhone/iPad · Lenas-iPhone', 'user_agent': 'Dart/3.12', 'ip_address': '5.6.7.8',
          'created_at': now, 'last_used_at': now, 'expires_at': now, 'current': false,
        }),
      ]);
  @override
  Future<List<User>> users() async =>
      _log('users', [User.fromJson(userJson()), User.fromJson(userJson(id: 2, admin: false))]);
  @override
  Future<List<Category>> categories() async => _log('categories', [
        Category.fromJson(categoryJson(1, 'Musik', 'audio', 'music_note')),
        Category.fromJson(categoryJson(2, 'Musikvideos', 'video', 'music_video')),
        Category.fromJson(categoryJson(3, 'Hörspiele & Hörbücher', 'audio', 'auto_stories')),
        Category.fromJson(categoryJson(4, 'Videos', 'video', 'movie')),
      ]);

  @override
  Future<HomeData> home() async => _log(
      'home',
      HomeData.fromJson({
        'quick_access': [
          {'type': 'liked', 'id': 'liked', 'title': 'Lieblingssongs', 'subtitle': '3 Songs', 'cover_id': null, 'mosaic': [], 'cover_color': '#4b2bd6'},
          {'type': 'album', 'id': '7', 'title': 'A Night at the Opera mit einem sehr langen Namen', 'subtitle': 'Queen', 'cover_id': coverA, 'mosaic': [], 'cover_color': null},
          {'type': 'playlist', 'id': '5', 'title': 'Roadtrip', 'subtitle': 'Playlist', 'cover_id': null, 'mosaic': [coverA, coverB, coverA, coverB], 'cover_color': null},
          {'type': 'artist', 'id': '3', 'title': 'Queen', 'subtitle': 'Künstler', 'cover_id': coverA, 'mosaic': [], 'cover_color': null},
        ],
        'sections': [
          {'key': 'recent', 'title': 'Zuletzt gehört', 'kind': 'contexts', 'contexts': [
            {'type': 'album', 'id': '7', 'title': 'A Night at the Opera', 'subtitle': 'Queen', 'cover_id': coverA, 'mosaic': [], 'cover_color': null},
            {'type': 'mix', 'id': 'genre:Rock', 'title': 'Rock-Mix', 'subtitle': 'Rock aus deiner Bibliothek', 'cover_id': null, 'mosaic': [coverA], 'cover_color': null},
          ], 'tracks': [], 'albums': [], 'artists': []},
          {'key': 'top_tracks', 'title': 'Deine Top-Songs', 'kind': 'tracks', 'contexts': [], 'tracks': [trackJson(1), trackJson(2)], 'albums': [], 'artists': []},
          {'key': 'new_albums', 'title': 'Neu in der Bibliothek', 'kind': 'albums', 'contexts': [], 'tracks': [], 'albums': [albumJson(7)], 'artists': []},
          {'key': 'artists', 'title': 'Deine Künstler', 'kind': 'artists', 'contexts': [], 'tracks': [], 'albums': [], 'artists': [artistJson(3)]},
          {'key': 'videos', 'title': 'Neue Videos', 'kind': 'videos', 'contexts': [], 'tracks': [trackJson(9, mediaType: 'video')], 'albums': [], 'artists': []},
        ],
      }));

  @override
  Future<LibraryOverview> library() async => _log(
      'library',
      LibraryOverview.fromJson({
        'liked_count': 3,
        'playlists': [playlistJson(5), playlistJson(6, owner: false, collaborative: true)],
        'albums': [albumJson(7)],
        'artists': [artistJson(3)],
      }));
  @override
  Future<List<Playlist>> playlists({String scope = 'library'}) async =>
      _log('playlists:$scope', [Playlist.fromJson(playlistJson(scope == 'family' ? 8 : 5, owner: scope != 'family'))]);
  @override
  Future<PlaylistDetail> playlist(int id) async => _log(
      'playlist',
      PlaylistDetail.fromJson({
        ...playlistJson(id, collaborative: id == 6),
        'items': [
          for (var i = 1; i <= 3; i++)
            {'item_id': 100 + i, 'position': i - 1, 'added_at': now, 'added_by': {'id': 1, 'display_name': 'Papa'}, 'track': trackJson(i)},
        ],
      }));
  @override
  Future<AlbumDetail> album(int id) async =>
      _log('album', AlbumDetail.fromJson({...albumJson(id), 'tracks': [trackJson(1), trackJson(2), trackJson(3)]}));
  @override
  Future<PageResult<Album>> albums(
          {int limit = 50, int offset = 0, String sort = 'title', int? categoryId, int? artistId, String? q}) async =>
      _log('albums', PageResult(items: [Album.fromJson(albumJson(7)), Album.fromJson(albumJson(8, title: 'Jazz'))], total: 2, limit: limit, offset: offset));
  @override
  Future<ArtistDetail> artist(int id) async => _log(
      'artist',
      ArtistDetail.fromJson({
        ...artistJson(id),
        'top_tracks': [for (var i = 1; i <= 7; i++) trackJson(i)],
        'albums': [albumJson(7)],
        'appears_on': [albumJson(8, title: 'Sampler')],
        'videos': [trackJson(9, mediaType: 'video')],
      }));
  @override
  Future<PageResult<Artist>> artists({int limit = 50, int offset = 0, String sort = 'name', int? categoryId, String? q}) async =>
      _log('artists', PageResult(items: [Artist.fromJson(artistJson(3))], total: 1, limit: limit, offset: offset));
  @override
  Future<PageResult<Track>> tracks({
    int limit = 50,
    int offset = 0,
    String sort = 'title',
    int? categoryId,
    String? mediaType,
    int? artistId,
    int? albumId,
    String? q,
  }) async =>
      _log('tracks', PageResult(items: offset > 0 ? <Track>[] : tracks_(mediaType ?? 'audio'), total: 3, limit: limit, offset: offset));
  List<Track> tracks_(String mediaType) => sampleTracks(3, mediaType: mediaType);
  @override
  Future<Track> track(int id) async => _log('track', Track.fromJson(trackJson(id)));
  @override
  Future<Lyrics?> lyrics(int trackId) async => _log(
      'lyrics',
      Lyrics.fromJson({'synced': true, 'source': 'lrc', 'lines': [
        {'time_ms': 0, 'text': 'Is this the real life?'},
        {'time_ms': 4000, 'text': 'Is this just fantasy?'},
      ]}));
  @override
  Future<List<Track>> radio(int trackId, {int limit = 50}) async => _log('radio', sampleTracks(3));
  @override
  Future<SearchResult> search(String q, {int limit = 10, int? categoryId}) async => _log(
      'search',
      SearchResult.fromJson({
        'query': q,
        'top_result': {'type': 'artist', 'artist': artistJson(3)},
        'tracks': [trackJson(1), trackJson(2)],
        'artists': [artistJson(3)],
        'albums': [albumJson(7)],
        'videos': [trackJson(9, mediaType: 'video')],
      }));
  @override
  Future<PageResult<LikedTrack>> likes({int limit = 500, int offset = 0}) async => _log(
      'likes',
      PageResult(
        items: [for (final t in sampleTracks(3)) LikedTrack(likedAt: DateTime.utc(2026, 10, 10), track: t)],
        total: 3,
        limit: limit,
        offset: offset,
      ));
  @override
  Future<LikedIds> likedIds() async =>
      _log('likedIds', const LikedIds(tracks: {1}, albums: {7}, artists: {3}, playlists: {6}));
  @override
  Future<List<ContextItem>> recent({int limit = 20}) async => _log('recent', const []);
  @override
  Future<List<HistoryEntry>> history({int limit = 50}) async => _log('history', const []);
  @override
  Future<Mix> mix(String key) async => _log(
      'mix',
      Mix.fromJson({'key': key, 'title': 'Rock-Mix', 'subtitle': 'Rock aus deiner Bibliothek', 'mosaic': [coverA, coverB, coverA, coverB], 'cover_color': '#b41e28', 'tracks': [trackJson(1), trackJson(2), trackJson(3)]}));
  @override
  Future<List<YouTubeItem>> youtubeSearch(String q, {String type = 'songs', int limit = 20}) async => _log('youtubeSearch', [
        for (var n = 1; n <= 3; n++) YouTubeItem.fromJson(ytItemJson(n, type: type == 'albums' ? 'album' : (type == 'videos' ? 'video' : 'song'))),
      ]);
  @override
  Future<YouTubeAlbum> youtubeAlbum(String browseId) async => _log(
      'youtubeAlbum',
      YouTubeAlbum.fromJson({
        'browse_id': browseId, 'title': 'Hot Fuss', 'artists': ['The Killers'], 'year': 2004, 'thumbnail_url': null,
        'tracks': [for (var n = 1; n <= 3; n++) ytItemJson(n)],
      }));
  @override
  Future<List<DownloadJob>> downloads({String scope = 'mine', String state = 'all', int limit = 100}) async =>
      _log('downloads', [DownloadJob.fromJson(jobJson(1, 'downloading')), DownloadJob.fromJson(jobJson(2, 'done'))]);
  @override
  Future<LibraryStats> libraryStats() async => _log(
      'libraryStats',
      LibraryStats.fromJson({
        'tracks': 1234, 'videos': 56, 'artists': 210, 'albums': 180, 'total_duration': 360000, 'total_size': 12000000000,
        'scan': {'running': false, 'started_at': now, 'finished_at': now, 'files_seen': 1290, 'added': 3, 'updated': 1,
          'removed': 0, 'errors': 1, 'last_error': 'Musik/kaputt.mp3: defekt', 'error_files': ['Musik/kaputt.mp3']},
      }));
  @override
  Future<ScanStatus> scanStatus() async => (await libraryStats()).scan;
  @override
  Future<void> deleteTrack(int id, {bool deleteFile = false}) async {
    await Future<void>.delayed(writeDelay);
    _log('deleteTrack:$id', null);
  }
  @override
  Future<PlaylistDetail> addToPlaylist(int id, List<int> trackIds, {int? position}) async {
    await Future<void>.delayed(writeDelay);
    _log('addToPlaylist:$id:$trackIds', null);
    return playlist(id);
  }
  @override
  Future<DownloaderStatus> downloaderStatus() async => _log(
      'downloaderStatus',
      DownloaderStatus.fromJson({
        'ytdlp_version': '2026.08.19', 'deno_available': true, 'ffmpeg_available': true, 'cookies_configured': false,
        'auto_update': true, 'last_update': now, 'last_update_result': '2026.08.19', 'workers': 2, 'audio_format': 'best',
        'video_codec': 'compatible', 'video_max_height': 1080, 'active_jobs': 1, 'queued_jobs': 0,
      }));
}

class FakeAuth extends AuthController {
  final FakeApi api;
  FakeAuth(this.api);

  @override
  Future<AuthState> build() async =>
      AuthState(serverUrl: 'https://musik.test', user: User.fromJson(userJson(admin: api.admin)), api: api);
}

/// Offline-Speicher ohne Dateisystem (path_provider gibt es im Test nicht).
class FakeOffline extends OfflineController {
  final OfflineState initial;
  FakeOffline([this.initial = const OfflineState(loaded: true)]);

  @override
  OfflineState build() => initial;

  @override
  String? localPath(int trackId) => null;

  @override
  void downloadTracks(List<Track> tracks) {}

  @override
  Future<void> keepCollection(String key, String name, List<Track> tracks) async {
    state = state.copyWith(collections: {...state.collections, key: tracks.map((t) => t.id).toList()});
  }

  @override
  Future<void> syncCollection(String key, List<Track> tracks) async {}

  @override
  Future<void> releaseCollection(String key) async {
    state = state.copyWith(collections: Map.of(state.collections)..remove(key));
  }

  @override
  Future<void> removeTrack(int trackId, {bool save = true}) async {}

  @override
  Future<void> removeAll() async {}
}

/// YouTube-Downloads ohne WebSocket.
class FakeDownloads extends DownloadsController {
  @override
  DownloadsState build() => DownloadsState(
        connected: true,
        jobs: {
          for (final j in [jobJson(1, 'downloading'), jobJson(2, 'queued'), jobJson(3, 'done'), jobJson(4, 'failed')])
            j['id'] as int: DownloadJob.fromJson(j),
        },
      );
}

OfflineState offlineWithTracks() => OfflineState(
      loaded: true,
      tracks: {
        for (final t in sampleTracks(2)) t.id: OfflineTrack(track: t, fileName: '${t.id}.opus', size: 4000000, savedAt: DateTime(2026, 10, 10)),
      },
      collections: {'playlist:5': [1, 2], 'liked': [1]},
      collectionNames: {'playlist:5': 'Roadtrip', 'liked': 'Lieblingssongs'},
      progress: {3: 0.4},
      pending: [3],
    );

/// Baut einen Bildschirm mit allen nötigen Ersatzteilen und gibt ihn zurück.
Future<FakeApi> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  bool admin = true,
  bool offline = false,
  OfflineState? offlineState,
  Size size = const Size(400, 860),
  double textScale = 1.0,
  EdgeInsets padding = EdgeInsets.zero,
  FakeApi? api,
  SelfifyAudioHandler? handler,
  AppUpdateSource? updates,
}) async {
  final fakeApi = api ?? FakeApi(admin: admin);
  final audioHandler = handler ?? SelfifyAudioHandler();
  await initializeDateFormatting('de_DE');
  SharedPreferences.setMockInitialValues({'search.recent': <String>['queen', 'abba']});
  final prefs = await SharedPreferences.getInstance();
  // Bild-Zwischenspeicher braucht ein Verzeichnis (path_provider gibt es im Test nicht)
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/selfify-test',
  );
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(path: '/test', builder: (_, _) => screen),
      GoRoute(path: '/:rest(.*)', builder: (_, s) => Scaffold(body: Text('Navigiert: ${s.uri}'))),
    ],
  );

  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      audioHandlerProvider.overrideWithValue(audioHandler),
      authProvider.overrideWith(() => FakeAuth(fakeApi)),
      connectivityProvider.overrideWith(
        (ref) => Stream.value(offline ? [ConnectivityResult.none] : [ConnectivityResult.wifi]),
      ),
      offlineProvider.overrideWith(() => FakeOffline(offlineState ?? const OfflineState(loaded: true))),
      downloadsProvider.overrideWith(FakeDownloads.new),
      if (updates != null) appUpdateSourceProvider.overrideWithValue(updates),
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale), padding: padding, viewPadding: padding),
      child: MaterialApp.router(theme: buildTheme(), routerConfig: router),
    ),
  ));
  // Daten laden lassen (keine pumpAndSettle: Ladekreise drehen sich endlos)
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return fakeApi;
}

/// Prüft, dass kein Fehler (z. B. Layout-Überlauf) aufgetreten ist.
void expectNoErrors(WidgetTester tester) {
  final error = tester.takeException();
  expect(error, isNull, reason: 'Beim Aufbau ist ein Fehler aufgetreten: $error');
}
