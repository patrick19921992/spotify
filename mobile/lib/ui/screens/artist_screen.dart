import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/likes.dart';
import '../../state/offline.dart';
import '../nav.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import 'detail_widgets.dart';

/// Alle Songs eines Künstlers (nach Album sortiert) für „Alle Titel“.
final _allTracksProvider = FutureProvider.autoDispose.family<List<Track>, int>((ref, artistId) async {
  final api = requireApi(ref);
  final tracks = <Track>[];
  var offset = 0;
  while (true) {
    final page = await api.tracks(artistId: artistId, mediaType: 'audio', sort: 'album', limit: 500, offset: offset);
    tracks.addAll(page.items);
    if (!page.hasMore || page.items.isEmpty || tracks.length >= 5000) break;
    offset += page.items.length;
  }
  return tracks;
});

/// Höhe des aufgeklappten Kopfbereichs (ohne Statusleiste).
const _headerHeight = 300.0;

/// Alben nach Jahr (neueste zuerst, ohne Jahr am Ende) – stabil, damit gleiche Jahre ihre Reihenfolge behalten.
List<Album> _byYear(List<Album> albums) {
  final indexed = [for (var i = 0; i < albums.length; i++) (i, albums[i])];
  indexed.sort((a, b) {
    final ya = a.$2.year;
    final yb = b.$2.year;
    if (ya != yb) {
      if (ya == null) return 1;
      if (yb == null) return -1;
      return yb.compareTo(ya);
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

String _albumCount(int count) => count == 1 ? '1 Album' : '$count Alben';

/// Künstlerseite wie bei Spotify: großes Bild mit Namen, Folgen, Beliebt, Diskografie, Videos.
class ArtistScreen extends ConsumerStatefulWidget {
  final int artistId;
  const ArtistScreen({super.key, required this.artistId});

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  int get _id => widget.artistId;

  bool _showAllPopular = false;
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    // Wieder online: fehlgeschlagenes Laden automatisch wiederholen
    ref.listenManual(isOfflineProvider, (previous, next) {
      if (previous == true && !next && ref.read(artistProvider(_id)).hasError) ref.invalidate(artistProvider(_id));
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    final collapsed = notification.metrics.pixels > _headerHeight - kToolbarHeight - 24;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    return false;
  }

  Future<void> _refresh() async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Du bist offline');
      return;
    }
    ref.invalidate(artistProvider(_id));
    try {
      await ref.read(artistProvider(_id).future);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _toggleFollow(Artist artist, bool following) async {
    try {
      await ref.read(likesProvider.notifier).toggleArtist(artist.id);
      if (mounted) showMessage(context, following ? 'Du folgst ${artist.name} nicht mehr' : 'Du folgst jetzt ${artist.name}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _startRadio(Track track) async {
    if (readDetailRestricted(ref)) {
      showMessage(
        context,
        ref.read(isOfflineProvider) ? 'Radio gibt es nur mit Verbindung' : 'Im Offline-Modus ist Radio nicht verfügbar',
      );
      return;
    }
    try {
      await ref.read(playerProvider).startRadio(track);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _openAllTracks(Artist artist) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ArtistTracksPage(artist: artist)));
  }

  void _showMenu(ArtistDetail detail, bool following) {
    final artist = detail.artist;
    final top = detail.topTracks;
    showDetailSheet(
      context,
      header: ListTile(
        leading: CoverImage(coverId: artist.coverId, size: 48, circle: true, placeholderIcon: Icons.person_rounded),
        title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
        subtitle: const Text('Künstler', style: AppText.tileSubtitle),
      ),
      builder: (sheetContext) {
        void close() => Navigator.of(sheetContext).pop();
        return [
          ListTile(
            leading: const Icon(Icons.auto_awesome_rounded),
            title: Text('${artist.name}-Mix', maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              close();
              Nav.mix(context, 'artist:${artist.id}');
            },
          ),
          if (top.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.radio_rounded),
              title: const Text('Radio'),
              subtitle: Text(
                'Startet mit „${top.first.title}“',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tileSubtitle,
              ),
              onTap: () {
                close();
                _startRadio(top.first);
              },
            ),
          if (top.isNotEmpty) ...[
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Beliebte Songs zur Warteschlange'),
              onTap: () {
                close();
                detailEnqueue(context, ref, top);
              },
            ),
            ListTile(
              leading: const Icon(Icons.library_music_outlined),
              title: const Text('Alle Titel anzeigen'),
              onTap: () {
                close();
                _openAllTracks(artist);
              },
            ),
          ],
          ListTile(
            leading: Icon(following ? Icons.person_remove_outlined : Icons.person_add_alt_1_outlined),
            title: Text(following ? 'Nicht mehr folgen' : 'Folgen'),
            onTap: () {
              close();
              _toggleFollow(artist, following);
            },
          ),
        ];
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(artistProvider(_id));
    final noNetwork = ref.watch(isOfflineProvider);
    final detail = async.value;
    if (detail != null) return _buildArtist(detail);
    if (noNetwork) return _buildOffline();
    return Scaffold(
      appBar: AppBar(),
      body: async.hasError
          ? ErrorView(message: errorText(async.error!), onRetry: () => ref.invalidate(artistProvider(_id)))
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildArtist(ArtistDetail detail) {
    final artist = detail.artist;
    final color = parseHexColor(artist.coverColor) ?? AppColors.surfaceHighest;
    final topInset = MediaQuery.paddingOf(context).top;
    final playContext = PlayContext('artist', id: _id, title: artist.name);
    final following = ref.watch(isArtistFollowedProvider(_id));
    final top = detail.topTracks;
    final popular = top.take(_showAllPopular ? 10 : 5).toList();
    final albums = _byYear(detail.albums);
    final appearsOn = _byYear(detail.appearsOn);
    final videos = detail.videos;
    final empty = top.isEmpty && albums.isEmpty && appearsOn.isEmpty && videos.isEmpty;

    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: RefreshIndicator(
          color: AppColors.accent,
          edgeOffset: topInset + kToolbarHeight,
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar(
                pinned: true,
                stretch: true,
                expandedHeight: _headerHeight,
                backgroundColor: darken(color, 0.22),
                foregroundColor: Colors.white,
                surfaceTintColor: Colors.transparent,
                scrolledUnderElevation: 0,
                title: AnimatedOpacity(
                  opacity: _collapsed ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  stretchModes: const [StretchMode.zoomBackground],
                  background: _ArtistHero(artist: artist, color: color),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${artist.trackCount} Titel · ${_albumCount(artist.albumCount)}',
                        style: AppText.tileSubtitle,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _FollowButton(following: following, onPressed: () => _toggleFollow(artist, following)),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: 'Mehr',
                            iconSize: 26,
                            icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
                            onPressed: () => _showMenu(detail, following),
                          ),
                          const Spacer(),
                          DetailPlayControls(tracks: top, playContext: playContext),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (empty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: EmptyState(
                      icon: Icons.music_off_rounded,
                      title: 'Noch keine Musik',
                      message: 'Von ${artist.name} ist noch nichts in der Bibliothek.',
                    ),
                  ),
                ),
              if (top.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: SectionHeader('Beliebt', padding: EdgeInsets.fromLTRB(16, 20, 8, 8)),
                ),
                SliverList.builder(
                  itemCount: popular.length,
                  itemBuilder: (context, index) => DetailTrackTile(
                    track: popular[index],
                    queue: top,
                    playContext: playContext,
                    rank: index + 1,
                  ),
                ),
                if (top.length > 5)
                  SliverToBoxAdapter(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8, top: 4),
                        child: TextButton(
                          onPressed: () => setState(() => _showAllPopular = !_showAllPopular),
                          child: Text(
                            _showAllPopular ? 'Weniger anzeigen' : 'Mehr anzeigen',
                            style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
              if (albums.isNotEmpty) ...[
                SliverToBoxAdapter(child: SectionHeader(albums.length == 1 ? 'Album' : 'Diskografie')),
                SliverToBoxAdapter(
                  child: CardRow(children: [for (final album in albums) MediaCard.album(context, album)]),
                ),
              ],
              if (appearsOn.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Enthalten auf')),
                SliverToBoxAdapter(
                  child: CardRow(children: [for (final album in appearsOn) MediaCard.album(context, album)]),
                ),
              ],
              if (videos.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionHeader('Videos')),
                SliverToBoxAdapter(child: DetailVideoRow(videos: videos)),
              ],
              if (top.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: () => _openAllTracks(artist),
                        icon: const Icon(Icons.library_music_outlined, size: 20),
                        label: const Text('Alle Titel anzeigen'),
                      ),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }

  /// Ohne Verbindung: die Songs dieses Künstlers, die auf dem Handy sind.
  Widget _buildOffline() {
    final loaded = ref.watch(offlineProvider.select((s) => s.loaded));
    // Nur neu aufbauen, wenn sich die Titel ändern (nicht bei jedem Fortschritts-Tick)
    final stored = ref.watch(offlineProvider.select((s) => s.tracks));
    if (!loaded) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final tracks = [
      for (final item in stored.values)
        if (item.track.artists.any((a) => a.id == _id)) item.track,
    ]..sort(_compareForArtist);
    if (tracks.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Du bist offline',
          message:
              'Von diesem Künstler ist nichts auf deinem Handy. Ohne Verbindung kannst du nur heruntergeladene Musik hören.',
          action: OutlinedButton(onPressed: () => Nav.offline(context), child: const Text('Heruntergeladene Musik')),
        ),
      );
    }
    final name = tracks.first.artists.firstWhere((a) => a.id == _id).name;
    final playContext = PlayContext('artist', id: _id, title: name);
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20)),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const DetailNotice(text: 'Keine Verbindung – hier sind die Songs auf deinem Handy.'),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${pluralSongs(tracks.length)} auf deinem Handy',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.tileSubtitle,
                        ),
                      ),
                      DetailPlayControls(tracks: tracks, playContext: playContext),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) =>
                DetailTrackTile(track: tracks[index], queue: tracks, playContext: playContext),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

/// Sortierung offline: nach Album, CD, Tracknummer, Titel.
int _compareForArtist(Track a, Track b) {
  final album = (a.album?.title ?? '').toLowerCase().compareTo((b.album?.title ?? '').toLowerCase());
  if (album != 0) return album;
  final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
  if (disc != 0) return disc;
  final number = (a.trackNumber ?? 9999).compareTo(b.trackNumber ?? 9999);
  if (number != 0) return number;
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// Großes Künstlerbild über die ganze Breite mit dunklem Verlauf und Namen.
class _ArtistHero extends StatelessWidget {
  final Artist artist;
  final Color color;

  const _ArtistHero({required this.artist, required this.color});

  @override
  Widget build(BuildContext context) {
    final name = artist.name;
    final fontSize = name.length > 22
        ? 32.0
        : name.length > 14
        ? 40.0
        : 48.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (artist.coverId != null)
          LayoutBuilder(
            builder: (context, constraints) {
              final side = math.max(constraints.maxWidth, constraints.maxHeight);
              return ClipRect(
                child: OverflowBox(
                  minWidth: side,
                  maxWidth: side,
                  minHeight: side,
                  maxHeight: side,
                  child: CoverImage(
                    coverId: artist.coverId,
                    size: side,
                    radius: 0,
                    requestSize: 600,
                    placeholderIcon: Icons.person_rounded,
                  ),
                ),
              );
            },
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color, darken(color, 0.3)],
              ),
            ),
            child: const Center(child: Icon(Icons.person_rounded, size: 120, color: Colors.white24)),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x73000000), Color(0x00000000), Color(0x26000000), Color(0xD9000000)],
              stops: [0, 0.3, 0.6, 1],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 14,
          child: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1.05,
              letterSpacing: -0.5,
              shadows: const [Shadow(color: Color(0x8A000000), blurRadius: 16)],
            ),
          ),
        ),
      ],
    );
  }
}

/// „Folgen“ / „Gefolgt“ – umrandeter Knopf wie bei Spotify.
class _FollowButton extends StatelessWidget {
  final bool following;
  final VoidCallback onPressed;

  const _FollowButton({required this.following, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: following ? Colors.white : AppColors.textMuted),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minimumSize: const Size(0, 34),
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.3),
      ),
      child: Text(following ? 'Gefolgt' : 'Folgen'),
    );
  }
}

// ------------------------------------------------------------------ Alle Titel

/// Alle Songs des Künstlers, nach Album gruppiert.
class _ArtistTracksPage extends ConsumerWidget {
  final Artist artist;
  const _ArtistTracksPage({required this.artist});

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Du bist offline');
      return;
    }
    ref.invalidate(_allTracksProvider(artist.id));
    try {
      await ref.read(_allTracksProvider(artist.id).future);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  List<Widget> _rows(List<Track> tracks, PlayContext playContext) {
    final rows = <Widget>[];
    var first = true;
    int? currentAlbum;
    for (final track in tracks) {
      final albumId = track.album?.id;
      if (first || albumId != currentAlbum) {
        rows.add(_AlbumGroupHeader(track: track, first: first));
        currentAlbum = albumId;
        first = false;
      }
      rows.add(DetailTrackTile(
        track: track,
        queue: tracks,
        playContext: playContext,
        showNumber: track.album != null,
        showCover: track.album == null,
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_allTracksProvider(artist.id));
    final playContext = PlayContext('artist', id: artist.id, title: artist.name);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Alle Titel', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
          ],
        ),
      ),
      body: async.when(
        data: (tracks) {
          final duration = tracks.fold<double>(0, (sum, t) => sum + t.duration);
          return RefreshIndicator(
            color: AppColors.accent,
            onRefresh: () => _refresh(context, ref),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (tracks.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.music_off_rounded,
                      title: 'Keine Songs gefunden',
                      message: 'Von diesem Künstler gibt es noch keine Songs in der Bibliothek.',
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${pluralSongs(tracks.length)} · ${formatLongDuration(duration)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.tileSubtitle,
                            ),
                          ),
                          DetailPlayControls(tracks: tracks, playContext: playContext),
                        ],
                      ),
                    ),
                  ),
                  SliverList.list(children: _rows(tracks, playContext)),
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ref.watch(isOfflineProvider)
            ? const EmptyState(
                icon: Icons.cloud_off_rounded,
                title: 'Du bist offline',
                message: 'Die vollständige Titelliste gibt es nur mit Verbindung.',
              )
            : ErrorView(message: errorText(error), onRetry: () => ref.invalidate(_allTracksProvider(artist.id))),
      ),
    );
  }
}

/// Zwischenüberschrift mit Album-Cover und -Titel – Tippen öffnet das Album.
class _AlbumGroupHeader extends StatelessWidget {
  final Track track;
  final bool first;

  const _AlbumGroupHeader({required this.track, required this.first});

  @override
  Widget build(BuildContext context) {
    final album = track.album;
    return InkWell(
      onTap: album == null ? null : () => Nav.album(context, album.id),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, first ? 8 : 20, 12, 6),
        child: Row(
          children: [
            CoverImage(
              coverId: album == null ? null : track.coverId,
              size: 40,
              placeholderIcon: album == null ? Icons.music_note_rounded : Icons.album_rounded,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album?.title ?? 'Einzelne Songs',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  if (album != null && track.year != null)
                    Text('Album · ${track.year}', style: AppText.caption)
                  else if (album != null)
                    const Text('Album', style: AppText.caption),
                ],
              ),
            ),
            if (album != null) const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
