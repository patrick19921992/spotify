import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'auth.dart';
import 'library.dart';

/// Herzen (Lieblingssongs), gespeicherte Alben und gefolgte Künstler – sofort sichtbar, dann gespeichert.
class LikesController extends AsyncNotifier<LikedIds> {
  @override
  Future<LikedIds> build() async {
    final api = ref.watch(apiProvider);
    if (api == null) return LikedIds.empty;
    return api.likedIds();
  }

  LikedIds get _current => state.value ?? LikedIds.empty;

  Future<void> _optimistic(LikedIds next, Future<void> Function() action) async {
    final previous = _current;
    state = AsyncData(next);
    try {
      await action();
    } catch (e) {
      state = AsyncData(previous);
      rethrow;
    }
  }

  Future<void> toggleTrack(int trackId) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final liked = !_current.tracks.contains(trackId);
    final tracks = {..._current.tracks};
    liked ? tracks.add(trackId) : tracks.remove(trackId);
    await _optimistic(_current.copyWith(tracks: tracks), () => api.setLiked(trackId, liked));
    ref.invalidate(likedTracksProvider);
    ref.invalidate(libraryOverviewProvider);
  }

  Future<void> toggleAlbum(int albumId) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final saved = !_current.albums.contains(albumId);
    final albums = {..._current.albums};
    saved ? albums.add(albumId) : albums.remove(albumId);
    await _optimistic(_current.copyWith(albums: albums), () => api.setAlbumSaved(albumId, saved));
    ref.invalidate(libraryOverviewProvider);
  }

  Future<void> toggleArtist(int artistId) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final followed = !_current.artists.contains(artistId);
    final artists = {..._current.artists};
    followed ? artists.add(artistId) : artists.remove(artistId);
    await _optimistic(_current.copyWith(artists: artists), () => api.setArtistFollowed(artistId, followed));
    ref.invalidate(libraryOverviewProvider);
  }

  Future<void> togglePlaylistFollow(int playlistId) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final following = !_current.playlists.contains(playlistId);
    final playlists = {..._current.playlists};
    following ? playlists.add(playlistId) : playlists.remove(playlistId);
    await _optimistic(
      _current.copyWith(playlists: playlists),
      () => following ? api.followPlaylist(playlistId) : api.unfollowPlaylist(playlistId),
    );
    ref.invalidate(libraryOverviewProvider);
    ref.invalidate(playlistProvider(playlistId));
  }
}

final likesProvider = AsyncNotifierProvider<LikesController, LikedIds>(LikesController.new);

final isTrackLikedProvider =
    Provider.family<bool, int>((ref, id) => ref.watch(likesProvider).value?.tracks.contains(id) ?? false);
final isAlbumSavedProvider =
    Provider.family<bool, int>((ref, id) => ref.watch(likesProvider).value?.albums.contains(id) ?? false);
final isArtistFollowedProvider =
    Provider.family<bool, int>((ref, id) => ref.watch(likesProvider).value?.artists.contains(id) ?? false);
