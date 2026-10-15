import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';

Map<String, dynamic> trackJson({int id = 1, String mediaType = 'audio'}) => {
      'id': id,
      'title': 'Bohemian Rhapsody',
      'artist_display': 'Queen',
      'artists': [
        {'id': 3, 'name': 'Queen'}
      ],
      'album': {'id': 7, 'title': 'A Night at the Opera'},
      'category_id': 1,
      'media_type': mediaType,
      'duration': 354.32,
      'track_number': 11,
      'disc_number': null,
      'year': 1975,
      'genre': 'Rock',
      'codec': 'opus',
      'bitrate': 160,
      'width': null,
      'height': null,
      'file_size': 4200000,
      'cover_id': 'a' * 40,
      'cover_color': '#b41e28',
      'source': 'youtube',
      'added_at': '2026-10-10T11:00:00Z',
    };

void main() {
  test('Track wird vollständig gelesen', () {
    final track = Track.fromJson(trackJson());
    expect(track.title, 'Bohemian Rhapsody');
    expect(track.artists.single.name, 'Queen');
    expect(track.album?.id, 7);
    expect(track.length, const Duration(milliseconds: 354320));
    expect(track.isVideo, isFalse);
    expect(track.addedAt.toUtc(), DateTime.utc(2026, 10, 10, 11));
    // Für den Offline-Speicher wird das Original-JSON wiederverwendet
    expect(Track.fromJson(track.toJson()).title, track.title);
  });

  test('Titel sind über die ID gleich', () {
    expect(Track.fromJson(trackJson()), Track.fromJson(trackJson()));
    expect(Track.fromJson(trackJson()) == Track.fromJson(trackJson(id: 2)), isFalse);
  });

  test('Download-Auftrag mit deutscher Statusanzeige', () {
    final job = DownloadJob.fromJson({
      'id': 5,
      'status': 'queued',
      'media_type': 'audio',
      'video_id': 'aaaaaaaaaa1',
      'title': 'Mr. Brightside',
      'artists': ['The Killers'],
      'album': 'Hot Fuss',
      'thumbnail_url': null,
      'category_id': 1,
      'progress': 0,
      'downloaded_bytes': 0,
      'total_bytes': null,
      'speed': null,
      'eta': null,
      'queue_position': 2,
      'error': null,
      'track_id': null,
      'playlist_id': null,
      'user': {'id': 1, 'display_name': 'Papa'},
      'created_at': '2026-10-10T11:00:00Z',
      'started_at': null,
      'finished_at': null,
    });
    expect(job.isActive, isTrue);
    expect(job.statusLabel, 'Wartet (Platz 3)');
    expect(job.artistDisplay, 'The Killers');
    expect(job.user?.displayName, 'Papa');
  });

  test('Startseite mit Abschnitten', () {
    final home = HomeData.fromJson({
      'quick_access': [
        {'type': 'liked', 'id': 'liked', 'title': 'Lieblingssongs', 'subtitle': '3 Songs', 'cover_id': null, 'mosaic': [], 'cover_color': '#4b2bd6'}
      ],
      'sections': [
        {'key': 'top_tracks', 'title': 'Deine Top-Songs', 'kind': 'tracks', 'contexts': [], 'tracks': [trackJson()], 'albums': [], 'artists': []}
      ],
    });
    expect(home.quickAccess.single.type, 'liked');
    expect(home.sections.single.tracks.single.title, 'Bohemian Rhapsody');
  });

  test('Token-Antwort berechnet Ablaufzeiten', () {
    final tokens = Tokens.fromResponse({
      'access_token': 'a',
      'refresh_token': 'r',
      'media_token': 'm',
      'expires_in': 1800,
      'media_expires_in': 604800,
    });
    expect(tokens.accessExpiringSoon, isFalse);
    final restored = Tokens.fromJson(tokens.toJson());
    expect(restored.mediaToken, 'm');
    expect(restored.accessExpiresAt.difference(tokens.accessExpiresAt).inSeconds.abs(), lessThan(1));
  });

  test('Gespeicherte IDs (Herzen) als Mengen', () {
    final ids = LikedIds.fromJson({'tracks': [1, 2], 'albums': [3], 'artists': [], 'playlists': [9]});
    expect(ids.tracks, {1, 2});
    expect(ids.copyWith(tracks: {5}).albums, {3});
  });
}
