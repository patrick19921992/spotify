// Datenmodelle – genaue Abbildung der Server-API (server/app/schemas/*.py).

typedef Json = Map<String, dynamic>;

DateTime _date(dynamic value) => DateTime.tryParse(value?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
DateTime? _dateOrNull(dynamic value) => value == null ? null : DateTime.tryParse(value.toString());
double _double(dynamic value) => (value as num?)?.toDouble() ?? 0;
int _int(dynamic value) => (value as num?)?.toInt() ?? 0;
List<T> _list<T>(dynamic value, T Function(Json) parse) =>
    (value as List? ?? const []).map((e) => parse(e as Json)).toList();
List<String> _strings(dynamic value) => (value as List? ?? const []).map((e) => e.toString()).toList();

// ---------------------------------------------------------------- Konto

class User {
  final int id;
  final String username;
  final String displayName;
  final bool isAdmin;
  final bool isActive;
  final bool canDownload;
  final DateTime createdAt;
  final DateTime? lastLoginAt;

  const User({
    required this.id,
    required this.username,
    required this.displayName,
    required this.isAdmin,
    required this.isActive,
    required this.canDownload,
    required this.createdAt,
    this.lastLoginAt,
  });

  factory User.fromJson(Json j) => User(
        id: _int(j['id']),
        username: j['username'] as String,
        displayName: j['display_name'] as String,
        isAdmin: j['is_admin'] == true,
        isActive: j['is_active'] != false,
        canDownload: j['can_download'] == true,
        createdAt: _date(j['created_at']),
        lastLoginAt: _dateOrNull(j['last_login_at']),
      );

  Json toJson() => {
        'id': id,
        'username': username,
        'display_name': displayName,
        'is_admin': isAdmin,
        'is_active': isActive,
        'can_download': canDownload,
        'created_at': createdAt.toIso8601String(),
        'last_login_at': lastLoginAt?.toIso8601String(),
      };
}

class Tokens {
  final String accessToken;
  final String refreshToken;
  final String mediaToken;
  final DateTime accessExpiresAt;
  final DateTime mediaExpiresAt;

  const Tokens({
    required this.accessToken,
    required this.refreshToken,
    required this.mediaToken,
    required this.accessExpiresAt,
    required this.mediaExpiresAt,
  });

  factory Tokens.fromResponse(Json j) {
    final now = DateTime.now();
    return Tokens(
      accessToken: j['access_token'] as String,
      refreshToken: j['refresh_token'] as String,
      mediaToken: j['media_token'] as String,
      accessExpiresAt: now.add(Duration(seconds: _int(j['expires_in']))),
      mediaExpiresAt: now.add(Duration(seconds: _int(j['media_expires_in']))),
    );
  }

  factory Tokens.fromJson(Json j) => Tokens(
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        mediaToken: j['media_token'] as String,
        accessExpiresAt: _date(j['access_expires_at']),
        mediaExpiresAt: _date(j['media_expires_at']),
      );

  Json toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'media_token': mediaToken,
        'access_expires_at': accessExpiresAt.toIso8601String(),
        'media_expires_at': mediaExpiresAt.toIso8601String(),
      };

  bool get accessExpiringSoon => DateTime.now().isAfter(accessExpiresAt.subtract(const Duration(minutes: 2)));
}

class ServerInfo {
  final String name;
  final String version;
  final int apiVersion;
  final String publicUrl;

  const ServerInfo({required this.name, required this.version, required this.apiVersion, required this.publicUrl});

  factory ServerInfo.fromJson(Json j) => ServerInfo(
        name: j['name'] as String? ?? 'Selfify',
        version: j['version'] as String? ?? '?',
        apiVersion: _int(j['api_version']),
        publicUrl: j['public_url'] as String? ?? '',
      );
}

class DeviceSession {
  final int id;
  final String deviceName;
  final String userAgent;
  final String ipAddress;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final bool current;

  const DeviceSession({
    required this.id,
    required this.deviceName,
    required this.userAgent,
    required this.ipAddress,
    required this.createdAt,
    required this.lastUsedAt,
    required this.current,
  });

  factory DeviceSession.fromJson(Json j) => DeviceSession(
        id: _int(j['id']),
        deviceName: j['device_name'] as String? ?? '',
        userAgent: j['user_agent'] as String? ?? '',
        ipAddress: j['ip_address'] as String? ?? '',
        createdAt: _date(j['created_at']),
        lastUsedAt: _date(j['last_used_at']),
        current: j['current'] == true,
      );
}

// ------------------------------------------------------------- Rubriken

class Category {
  final int id;
  final String name;
  final String slug;
  final String folder;
  final String mediaType; // "audio" | "video"
  final String icon;
  final int sortOrder;
  final bool isDefault;
  final int itemCount;

  const Category({
    required this.id,
    required this.name,
    required this.slug,
    required this.folder,
    required this.mediaType,
    required this.icon,
    required this.sortOrder,
    required this.isDefault,
    required this.itemCount,
  });

  bool get isVideo => mediaType == 'video';

  factory Category.fromJson(Json j) => Category(
        id: _int(j['id']),
        name: j['name'] as String,
        slug: j['slug'] as String,
        folder: j['folder'] as String,
        mediaType: j['media_type'] as String,
        icon: j['icon'] as String? ?? 'folder',
        sortOrder: _int(j['sort_order']),
        isDefault: j['is_default'] == true,
        itemCount: _int(j['item_count']),
      );
}

// ----------------------------------------------------------- Bibliothek

class ArtistRef {
  final int id;
  final String name;
  const ArtistRef({required this.id, required this.name});
  factory ArtistRef.fromJson(Json j) => ArtistRef(id: _int(j['id']), name: j['name'] as String);
  Json toJson() => {'id': id, 'name': name};
}

class AlbumRef {
  final int id;
  final String title;
  const AlbumRef({required this.id, required this.title});
  factory AlbumRef.fromJson(Json j) => AlbumRef(id: _int(j['id']), title: j['title'] as String);
  Json toJson() => {'id': id, 'title': title};
}

class Track {
  final int id;
  final String title;
  final String artistDisplay;
  final List<ArtistRef> artists;
  final AlbumRef? album;
  final int categoryId;
  final String mediaType;
  final double duration;
  final int? trackNumber;
  final int? discNumber;
  final int? year;
  final String? genre;
  final String? codec;
  final int? bitrate;
  final int? width;
  final int? height;
  final int fileSize;
  final String? coverId;
  final String? coverColor;
  final String source;
  final DateTime addedAt;
  final Json raw;

  const Track({
    required this.id,
    required this.title,
    required this.artistDisplay,
    required this.artists,
    required this.album,
    required this.categoryId,
    required this.mediaType,
    required this.duration,
    required this.trackNumber,
    required this.discNumber,
    required this.year,
    required this.genre,
    required this.codec,
    required this.bitrate,
    required this.width,
    required this.height,
    required this.fileSize,
    required this.coverId,
    required this.coverColor,
    required this.source,
    required this.addedAt,
    required this.raw,
  });

  bool get isVideo => mediaType == 'video';
  Duration get length => Duration(milliseconds: (duration * 1000).round());

  factory Track.fromJson(Json j) => Track(
        id: _int(j['id']),
        title: j['title'] as String,
        artistDisplay: j['artist_display'] as String? ?? '',
        artists: _list(j['artists'], ArtistRef.fromJson),
        album: j['album'] == null ? null : AlbumRef.fromJson(j['album'] as Json),
        categoryId: _int(j['category_id']),
        mediaType: j['media_type'] as String? ?? 'audio',
        duration: _double(j['duration']),
        trackNumber: (j['track_number'] as num?)?.toInt(),
        discNumber: (j['disc_number'] as num?)?.toInt(),
        year: (j['year'] as num?)?.toInt(),
        genre: j['genre'] as String?,
        codec: j['codec'] as String?,
        bitrate: (j['bitrate'] as num?)?.toInt(),
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        fileSize: _int(j['file_size']),
        coverId: j['cover_id'] as String?,
        coverColor: j['cover_color'] as String?,
        source: j['source'] as String? ?? 'local',
        addedAt: _date(j['added_at']),
        raw: j,
      );

  /// Für die Offline-Ablage wird das Original-JSON gespeichert.
  Json toJson() => raw;

  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class Album {
  final int id;
  final String title;
  final ArtistRef artist;
  final int? year;
  final String? genre;
  final int trackCount;
  final double duration;
  final String? coverId;
  final String? coverColor;
  final DateTime addedAt;

  const Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.year,
    required this.genre,
    required this.trackCount,
    required this.duration,
    required this.coverId,
    required this.coverColor,
    required this.addedAt,
  });

  factory Album.fromJson(Json j) => Album(
        id: _int(j['id']),
        title: j['title'] as String,
        artist: ArtistRef.fromJson(j['artist'] as Json),
        year: (j['year'] as num?)?.toInt(),
        genre: j['genre'] as String?,
        trackCount: _int(j['track_count']),
        duration: _double(j['duration']),
        coverId: j['cover_id'] as String?,
        coverColor: j['cover_color'] as String?,
        addedAt: _date(j['added_at']),
      );
}

class AlbumDetail {
  final Album album;
  final List<Track> tracks;
  const AlbumDetail({required this.album, required this.tracks});
  factory AlbumDetail.fromJson(Json j) => AlbumDetail(album: Album.fromJson(j), tracks: _list(j['tracks'], Track.fromJson));
}

class Artist {
  final int id;
  final String name;
  final int trackCount;
  final int albumCount;
  final String? coverId;
  final String? coverColor;

  const Artist({
    required this.id,
    required this.name,
    required this.trackCount,
    required this.albumCount,
    required this.coverId,
    required this.coverColor,
  });

  factory Artist.fromJson(Json j) => Artist(
        id: _int(j['id']),
        name: j['name'] as String,
        trackCount: _int(j['track_count']),
        albumCount: _int(j['album_count']),
        coverId: j['cover_id'] as String?,
        coverColor: j['cover_color'] as String?,
      );
}

class ArtistDetail {
  final Artist artist;
  final List<Track> topTracks;
  final List<Album> albums;
  final List<Album> appearsOn;
  final List<Track> videos;

  const ArtistDetail({
    required this.artist,
    required this.topTracks,
    required this.albums,
    required this.appearsOn,
    required this.videos,
  });

  factory ArtistDetail.fromJson(Json j) => ArtistDetail(
        artist: Artist.fromJson(j),
        topTracks: _list(j['top_tracks'], Track.fromJson),
        albums: _list(j['albums'], Album.fromJson),
        appearsOn: _list(j['appears_on'], Album.fromJson),
        videos: _list(j['videos'], Track.fromJson),
      );
}

class PageResult<T> {
  final List<T> items;
  final int total;
  final int limit;
  final int offset;

  const PageResult({required this.items, required this.total, required this.limit, required this.offset});

  bool get hasMore => offset + items.length < total;

  factory PageResult.fromJson(Json j, T Function(Json) parse) => PageResult(
        items: _list(j['items'], parse),
        total: _int(j['total']),
        limit: _int(j['limit']),
        offset: _int(j['offset']),
      );
}

class TopResult {
  final String type; // artist | album | track | video
  final Artist? artist;
  final Album? album;
  final Track? track;

  const TopResult({required this.type, this.artist, this.album, this.track});

  factory TopResult.fromJson(Json j) => TopResult(
        type: j['type'] as String,
        artist: j['artist'] == null ? null : Artist.fromJson(j['artist'] as Json),
        album: j['album'] == null ? null : Album.fromJson(j['album'] as Json),
        track: j['track'] == null ? null : Track.fromJson(j['track'] as Json),
      );
}

class SearchResult {
  final String query;
  final TopResult? topResult;
  final List<Track> tracks;
  final List<Artist> artists;
  final List<Album> albums;
  final List<Track> videos;

  const SearchResult({
    required this.query,
    required this.topResult,
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.videos,
  });

  bool get isEmpty => tracks.isEmpty && artists.isEmpty && albums.isEmpty && videos.isEmpty;

  factory SearchResult.fromJson(Json j) => SearchResult(
        query: j['query'] as String? ?? '',
        topResult: j['top_result'] == null ? null : TopResult.fromJson(j['top_result'] as Json),
        tracks: _list(j['tracks'], Track.fromJson),
        artists: _list(j['artists'], Artist.fromJson),
        albums: _list(j['albums'], Album.fromJson),
        videos: _list(j['videos'], Track.fromJson),
      );
}

class ScanStatus {
  final bool running;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int filesSeen;
  final int added;
  final int updated;
  final int removed;
  final int errors;
  final String? lastError;
  final List<String> errorFiles;

  const ScanStatus({
    required this.running,
    required this.startedAt,
    required this.finishedAt,
    required this.filesSeen,
    required this.added,
    required this.updated,
    required this.removed,
    required this.errors,
    required this.lastError,
    required this.errorFiles,
  });

  factory ScanStatus.fromJson(Json j) => ScanStatus(
        running: j['running'] == true,
        startedAt: _dateOrNull(j['started_at']),
        finishedAt: _dateOrNull(j['finished_at']),
        filesSeen: _int(j['files_seen']),
        added: _int(j['added']),
        updated: _int(j['updated']),
        removed: _int(j['removed']),
        errors: _int(j['errors']),
        lastError: j['last_error'] as String?,
        errorFiles: _strings(j['error_files']),
      );
}

class LibraryStats {
  final int tracks;
  final int videos;
  final int artists;
  final int albums;
  final double totalDuration;
  final int totalSize;
  final ScanStatus scan;

  const LibraryStats({
    required this.tracks,
    required this.videos,
    required this.artists,
    required this.albums,
    required this.totalDuration,
    required this.totalSize,
    required this.scan,
  });

  factory LibraryStats.fromJson(Json j) => LibraryStats(
        tracks: _int(j['tracks']),
        videos: _int(j['videos']),
        artists: _int(j['artists']),
        albums: _int(j['albums']),
        totalDuration: _double(j['total_duration']),
        totalSize: _int(j['total_size']),
        scan: ScanStatus.fromJson(j['scan'] as Json),
      );
}

class LyricsLine {
  final int? timeMs;
  final String text;
  const LyricsLine({required this.timeMs, required this.text});
  factory LyricsLine.fromJson(Json j) => LyricsLine(timeMs: (j['time_ms'] as num?)?.toInt(), text: j['text'] as String? ?? '');
}

class Lyrics {
  final bool synced;
  final String? source;
  final List<LyricsLine> lines;
  const Lyrics({required this.synced, required this.source, required this.lines});
  factory Lyrics.fromJson(Json j) =>
      Lyrics(synced: j['synced'] == true, source: j['source'] as String?, lines: _list(j['lines'], LyricsLine.fromJson));
}

// ------------------------------------------------------------ Persönlich

class UserRef {
  final int id;
  final String displayName;
  const UserRef({required this.id, required this.displayName});
  factory UserRef.fromJson(Json j) => UserRef(id: _int(j['id']), displayName: j['display_name'] as String? ?? '');
}

class Playlist {
  final int id;
  final String name;
  final String description;
  final UserRef owner;
  final bool isPublic;
  final bool isCollaborative;
  final int trackCount;
  final double duration;
  final String? coverId;
  final List<String> mosaic;
  final String? coverColor;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isOwner;
  final bool isFollowing;
  final bool canEdit;

  const Playlist({
    required this.id,
    required this.name,
    required this.description,
    required this.owner,
    required this.isPublic,
    required this.isCollaborative,
    required this.trackCount,
    required this.duration,
    required this.coverId,
    required this.mosaic,
    required this.coverColor,
    required this.createdAt,
    required this.updatedAt,
    required this.isOwner,
    required this.isFollowing,
    required this.canEdit,
  });

  factory Playlist.fromJson(Json j) => Playlist(
        id: _int(j['id']),
        name: j['name'] as String,
        description: j['description'] as String? ?? '',
        owner: UserRef.fromJson(j['owner'] as Json),
        isPublic: j['is_public'] == true,
        isCollaborative: j['is_collaborative'] == true,
        trackCount: _int(j['track_count']),
        duration: _double(j['duration']),
        coverId: j['cover_id'] as String?,
        mosaic: _strings(j['mosaic']),
        coverColor: j['cover_color'] as String?,
        createdAt: _date(j['created_at']),
        updatedAt: _date(j['updated_at']),
        isOwner: j['is_owner'] == true,
        isFollowing: j['is_following'] == true,
        canEdit: j['can_edit'] == true,
      );
}

class PlaylistItem {
  final int itemId;
  final int position;
  final DateTime addedAt;
  final UserRef? addedBy;
  final Track track;

  const PlaylistItem({
    required this.itemId,
    required this.position,
    required this.addedAt,
    required this.addedBy,
    required this.track,
  });

  factory PlaylistItem.fromJson(Json j) => PlaylistItem(
        itemId: _int(j['item_id']),
        position: _int(j['position']),
        addedAt: _date(j['added_at']),
        addedBy: j['added_by'] == null ? null : UserRef.fromJson(j['added_by'] as Json),
        track: Track.fromJson(j['track'] as Json),
      );
}

class PlaylistDetail {
  final Playlist playlist;
  final List<PlaylistItem> items;
  const PlaylistDetail({required this.playlist, required this.items});
  List<Track> get tracks => items.map((i) => i.track).toList();
  factory PlaylistDetail.fromJson(Json j) =>
      PlaylistDetail(playlist: Playlist.fromJson(j), items: _list(j['items'], PlaylistItem.fromJson));
}

class LikedTrack {
  final DateTime likedAt;
  final Track track;
  const LikedTrack({required this.likedAt, required this.track});
  factory LikedTrack.fromJson(Json j) => LikedTrack(likedAt: _date(j['liked_at']), track: Track.fromJson(j['track'] as Json));
}

class LikedIds {
  final Set<int> tracks;
  final Set<int> albums;
  final Set<int> artists;
  final Set<int> playlists;

  const LikedIds({required this.tracks, required this.albums, required this.artists, required this.playlists});

  static const empty = LikedIds(tracks: {}, albums: {}, artists: {}, playlists: {});

  factory LikedIds.fromJson(Json j) => LikedIds(
        tracks: (j['tracks'] as List? ?? const []).map((e) => _int(e)).toSet(),
        albums: (j['albums'] as List? ?? const []).map((e) => _int(e)).toSet(),
        artists: (j['artists'] as List? ?? const []).map((e) => _int(e)).toSet(),
        playlists: (j['playlists'] as List? ?? const []).map((e) => _int(e)).toSet(),
      );

  LikedIds copyWith({Set<int>? tracks, Set<int>? albums, Set<int>? artists, Set<int>? playlists}) => LikedIds(
        tracks: tracks ?? this.tracks,
        albums: albums ?? this.albums,
        artists: artists ?? this.artists,
        playlists: playlists ?? this.playlists,
      );
}

class LibraryOverview {
  final int likedCount;
  final List<Playlist> playlists;
  final List<Album> albums;
  final List<Artist> artists;

  const LibraryOverview({required this.likedCount, required this.playlists, required this.albums, required this.artists});

  factory LibraryOverview.fromJson(Json j) => LibraryOverview(
        likedCount: _int(j['liked_count']),
        playlists: _list(j['playlists'], Playlist.fromJson),
        albums: _list(j['albums'], Album.fromJson),
        artists: _list(j['artists'], Artist.fromJson),
      );
}

class HistoryEntry {
  final DateTime playedAt;
  final double seconds;
  final String? contextType;
  final int? contextId;
  final Track track;

  const HistoryEntry({
    required this.playedAt,
    required this.seconds,
    required this.contextType,
    required this.contextId,
    required this.track,
  });

  factory HistoryEntry.fromJson(Json j) => HistoryEntry(
        playedAt: _date(j['played_at']),
        seconds: _double(j['seconds']),
        contextType: j['context_type'] as String?,
        contextId: (j['context_id'] as num?)?.toInt(),
        track: Track.fromJson(j['track'] as Json),
      );
}

/// Kachel auf der Startseite: Album, Playlist, Künstler, Lieblingssongs oder Mix.
class ContextItem {
  final String type; // album | playlist | artist | liked | mix
  final String id;
  final String title;
  final String subtitle;
  final String? coverId;
  final List<String> mosaic;
  final String? coverColor;

  const ContextItem({
    required this.type,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.coverId,
    required this.mosaic,
    required this.coverColor,
  });

  factory ContextItem.fromJson(Json j) => ContextItem(
        type: j['type'] as String,
        id: j['id'].toString(),
        title: j['title'] as String? ?? '',
        subtitle: j['subtitle'] as String? ?? '',
        coverId: j['cover_id'] as String?,
        mosaic: _strings(j['mosaic']),
        coverColor: j['cover_color'] as String?,
      );
}

class HomeSection {
  final String key;
  final String title;
  final String kind; // contexts | tracks | albums | artists | videos
  final List<ContextItem> contexts;
  final List<Track> tracks;
  final List<Album> albums;
  final List<Artist> artists;

  const HomeSection({
    required this.key,
    required this.title,
    required this.kind,
    required this.contexts,
    required this.tracks,
    required this.albums,
    required this.artists,
  });

  factory HomeSection.fromJson(Json j) => HomeSection(
        key: j['key'] as String,
        title: j['title'] as String,
        kind: j['kind'] as String,
        contexts: _list(j['contexts'], ContextItem.fromJson),
        tracks: _list(j['tracks'], Track.fromJson),
        albums: _list(j['albums'], Album.fromJson),
        artists: _list(j['artists'], Artist.fromJson),
      );
}

class HomeData {
  final List<ContextItem> quickAccess;
  final List<HomeSection> sections;
  const HomeData({required this.quickAccess, required this.sections});
  factory HomeData.fromJson(Json j) => HomeData(
        quickAccess: _list(j['quick_access'], ContextItem.fromJson),
        sections: _list(j['sections'], HomeSection.fromJson),
      );
}

class Mix {
  final String key;
  final String title;
  final String subtitle;
  final List<String> mosaic;
  final String? coverColor;
  final List<Track> tracks;

  const Mix({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.mosaic,
    required this.coverColor,
    required this.tracks,
  });

  factory Mix.fromJson(Json j) => Mix(
        key: j['key'] as String,
        title: j['title'] as String,
        subtitle: j['subtitle'] as String? ?? '',
        mosaic: _strings(j['mosaic']),
        coverColor: j['cover_color'] as String?,
        tracks: _list(j['tracks'], Track.fromJson),
      );
}

// ------------------------------------------------------------- YouTube

class YouTubeItem {
  final String type; // song | video | album
  final String title;
  final List<String> artists;
  final String? videoId;
  final String? browseId;
  final String? album;
  final String? albumBrowseId;
  final double? duration;
  final int? year;
  final String? thumbnailUrl;
  final bool explicit;
  final int? trackNumber;
  final int? inLibraryTrackId;
  final int? activeJobId;

  const YouTubeItem({
    required this.type,
    required this.title,
    required this.artists,
    required this.videoId,
    required this.browseId,
    required this.album,
    required this.albumBrowseId,
    required this.duration,
    required this.year,
    required this.thumbnailUrl,
    required this.explicit,
    required this.trackNumber,
    required this.inLibraryTrackId,
    required this.activeJobId,
  });

  String get artistDisplay => artists.join(', ');
  bool get isVideo => type == 'video';
  bool get isAlbum => type == 'album';

  factory YouTubeItem.fromJson(Json j) => YouTubeItem(
        type: j['type'] as String,
        title: j['title'] as String,
        artists: _strings(j['artists']),
        videoId: j['video_id'] as String?,
        browseId: j['browse_id'] as String?,
        album: j['album'] as String?,
        albumBrowseId: j['album_browse_id'] as String?,
        duration: (j['duration'] as num?)?.toDouble(),
        year: (j['year'] as num?)?.toInt(),
        thumbnailUrl: j['thumbnail_url'] as String?,
        explicit: j['explicit'] == true,
        trackNumber: (j['track_number'] as num?)?.toInt(),
        inLibraryTrackId: (j['in_library_track_id'] as num?)?.toInt(),
        activeJobId: (j['active_job_id'] as num?)?.toInt(),
      );
}

class YouTubeAlbum {
  final String browseId;
  final String title;
  final List<String> artists;
  final int? year;
  final String? thumbnailUrl;
  final List<YouTubeItem> tracks;

  const YouTubeAlbum({
    required this.browseId,
    required this.title,
    required this.artists,
    required this.year,
    required this.thumbnailUrl,
    required this.tracks,
  });

  factory YouTubeAlbum.fromJson(Json j) => YouTubeAlbum(
        browseId: j['browse_id'] as String,
        title: j['title'] as String,
        artists: _strings(j['artists']),
        year: (j['year'] as num?)?.toInt(),
        thumbnailUrl: j['thumbnail_url'] as String?,
        tracks: _list(j['tracks'], YouTubeItem.fromJson),
      );
}

/// Ein Download-Auftrag mit Live-Fortschritt.
class DownloadJob {
  final int id;
  final String status; // queued | downloading | processing | done | failed | cancelled
  final String mediaType;
  final String videoId;
  final String title;
  final List<String> artists;
  final String? album;
  final String? thumbnailUrl;
  final int categoryId;
  final double progress;
  final int downloadedBytes;
  final int? totalBytes;
  final double? speed;
  final int? eta;
  final int? queuePosition;
  final String? error;
  final int? trackId;
  final int? playlistId;
  final UserRef? user;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  const DownloadJob({
    required this.id,
    required this.status,
    required this.mediaType,
    required this.videoId,
    required this.title,
    required this.artists,
    required this.album,
    required this.thumbnailUrl,
    required this.categoryId,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speed,
    required this.eta,
    required this.queuePosition,
    required this.error,
    required this.trackId,
    required this.playlistId,
    required this.user,
    required this.createdAt,
    required this.startedAt,
    required this.finishedAt,
  });

  bool get isActive => status == 'queued' || status == 'downloading' || status == 'processing';
  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  String get artistDisplay => artists.join(', ');

  /// Deutsche Statusbeschreibung für die Anzeige.
  String get statusLabel => switch (status) {
        'queued' => queuePosition != null && queuePosition! > 0 ? 'Wartet (Platz ${queuePosition! + 1})' : 'Wartet',
        'downloading' => 'Wird geladen',
        'processing' => 'Wird verarbeitet',
        'done' => 'Fertig',
        'failed' => 'Fehlgeschlagen',
        'cancelled' => 'Abgebrochen',
        _ => status,
      };

  factory DownloadJob.fromJson(Json j) => DownloadJob(
        id: _int(j['id']),
        status: j['status'] as String,
        mediaType: j['media_type'] as String? ?? 'audio',
        videoId: j['video_id'] as String,
        title: j['title'] as String? ?? '',
        artists: _strings(j['artists']),
        album: j['album'] as String?,
        thumbnailUrl: j['thumbnail_url'] as String?,
        categoryId: _int(j['category_id']),
        progress: _double(j['progress']),
        downloadedBytes: _int(j['downloaded_bytes']),
        totalBytes: (j['total_bytes'] as num?)?.toInt(),
        speed: (j['speed'] as num?)?.toDouble(),
        eta: (j['eta'] as num?)?.toInt(),
        queuePosition: (j['queue_position'] as num?)?.toInt(),
        error: j['error'] as String?,
        trackId: (j['track_id'] as num?)?.toInt(),
        playlistId: (j['playlist_id'] as num?)?.toInt(),
        user: j['user'] == null ? null : UserRef.fromJson(j['user'] as Json),
        createdAt: _date(j['created_at']),
        startedAt: _dateOrNull(j['started_at']),
        finishedAt: _dateOrNull(j['finished_at']),
      );
}

class DownloaderStatus {
  final String? ytdlpVersion;
  final bool denoAvailable;
  final bool ffmpegAvailable;
  final bool cookiesConfigured;
  final bool autoUpdate;
  final DateTime? lastUpdate;
  final String? lastUpdateResult;
  final int workers;
  final String audioFormat;
  final String videoCodec;
  final int videoMaxHeight;
  final int activeJobs;
  final int queuedJobs;

  const DownloaderStatus({
    required this.ytdlpVersion,
    required this.denoAvailable,
    required this.ffmpegAvailable,
    required this.cookiesConfigured,
    required this.autoUpdate,
    required this.lastUpdate,
    required this.lastUpdateResult,
    required this.workers,
    required this.audioFormat,
    required this.videoCodec,
    required this.videoMaxHeight,
    required this.activeJobs,
    required this.queuedJobs,
  });

  factory DownloaderStatus.fromJson(Json j) => DownloaderStatus(
        ytdlpVersion: j['ytdlp_version'] as String?,
        denoAvailable: j['deno_available'] == true,
        ffmpegAvailable: j['ffmpeg_available'] == true,
        cookiesConfigured: j['cookies_configured'] == true,
        autoUpdate: j['auto_update'] == true,
        lastUpdate: _dateOrNull(j['last_update']),
        lastUpdateResult: j['last_update_result'] as String?,
        workers: _int(j['workers']),
        audioFormat: j['audio_format'] as String? ?? 'best',
        videoCodec: j['video_codec'] as String? ?? 'compatible',
        videoMaxHeight: _int(j['video_max_height']),
        activeJobs: _int(j['active_jobs']),
        queuedJobs: _int(j['queued_jobs']),
      );
}
