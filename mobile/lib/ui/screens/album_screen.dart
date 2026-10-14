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
import '../widgets/playlist_picker.dart';
import 'detail_widgets.dart';

/// Weitere Alben des Künstlers (neueste zuerst) für „Mehr von …“.
final _moreAlbumsProvider = FutureProvider.autoDispose.family<List<Album>, int>((ref, artistId) async {
  final page = await requireApi(ref).albums(artistId: artistId, sort: 'year', limit: 50);
  return page.items;
});

/// Was die Albumseite zeigt – vom Server oder (ohne Verbindung) aus dem Offline-Speicher.
class _AlbumInfo {
  final String title;
  final ArtistRef? artist;
  final int? year;
  final String? genre;
  final String? coverId;
  final String? coverColor;
  final List<Track> tracks;
  final double duration;
  final DateTime? addedAt;

  /// Heruntergeladene Version (Server nicht erreichbar).
  final bool fromDevice;

  /// Songs des Albums insgesamt (offline sind evtl. noch nicht alle auf dem Handy).
  final int totalTracks;

  const _AlbumInfo({
    required this.title,
    required this.artist,
    required this.year,
    required this.genre,
    required this.coverId,
    required this.coverColor,
    required this.tracks,
    required this.duration,
    required this.addedAt,
    required this.fromDevice,
    required this.totalTracks,
  });

  factory _AlbumInfo.online(AlbumDetail detail) {
    final album = detail.album;
    final tracks = detail.tracks;
    final sum = tracks.fold<double>(0, (total, t) => total + t.duration);
    return _AlbumInfo(
      title: album.title,
      artist: album.artist,
      year: album.year,
      genre: album.genre,
      coverId: album.coverId,
      coverColor: album.coverColor,
      tracks: tracks,
      duration: tracks.isEmpty ? album.duration : sum,
      addedAt: album.addedAt.year > 1970 ? album.addedAt : null,
      fromDevice: false,
      totalTracks: tracks.length,
    );
  }

  factory _AlbumInfo.device(OfflineState offline, String key) {
    final ids = offline.collections[key] ?? const <int>[];
    final tracks = [
      for (final id in ids)
        if (offline.tracks[id] != null) offline.tracks[id]!.track,
    ];
    T? first<T>(T? Function(Track track) pick) {
      for (final track in tracks) {
        final value = pick(track);
        if (value != null) return value;
      }
      return null;
    }

    // Albumkünstler ist offline nicht gespeichert: der häufigste (erste) Künstler der Songs
    final counts = <int, int>{};
    final refs = <int, ArtistRef>{};
    for (final track in tracks) {
      final artist = track.artists.firstOrNull;
      if (artist == null) continue;
      counts[artist.id] = (counts[artist.id] ?? 0) + 1;
      refs[artist.id] = artist;
    }
    ArtistRef? artist;
    if (counts.isNotEmpty) {
      artist = refs[counts.entries.reduce((a, b) => b.value > a.value ? b : a).key];
    }
    return _AlbumInfo(
      title: offline.collectionNames[key] ?? first((t) => t.album?.title) ?? 'Album',
      artist: artist,
      year: first((t) => t.year),
      genre: first((t) => t.genre),
      coverId: first((t) => t.coverId),
      coverColor: first((t) => t.coverColor),
      tracks: tracks,
      duration: tracks.fold<double>(0, (total, t) => total + t.duration),
      addedAt: null,
      fromDevice: true,
      totalTracks: ids.length,
    );
  }
}

/// Albumseite wie bei Spotify: großes Cover, Aktionen, Titelliste (mit CDs), Infos und „Mehr von …“.
class AlbumScreen extends ConsumerStatefulWidget {
  final int albumId;
  const AlbumScreen({super.key, required this.albumId});

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  int get _id => widget.albumId;
  String get _key => albumKey(_id);

  AlbumDetail? _synced;

  @override
  void initState() {
    super.initState();
    // Offline gehaltenes Album nach jedem Laden abgleichen (neu hinzugekommene Songs nachladen)
    ref.listenManual(albumProvider(_id), (_, next) => _maybeSync(next), fireImmediately: true);
    ref.listenManual(offlineProvider.select((s) => s.loaded), (_, loaded) {
      if (loaded) _maybeSync(ref.read(albumProvider(_id)));
    });
    // Wieder online: fehlgeschlagenes Laden automatisch wiederholen
    ref.listenManual(isOfflineProvider, (previous, next) {
      if (previous == true && !next && ref.read(albumProvider(_id)).hasError) ref.invalidate(albumProvider(_id));
    });
  }

  void _maybeSync(AsyncValue<AlbumDetail> value) {
    final detail = value.value;
    if (detail == null || value.isLoading || value.hasError || identical(detail, _synced)) return;
    final offline = ref.read(offlineProvider);
    if (!offline.loaded) return;
    _synced = detail;
    if (!offline.isCollectionOffline(_key)) return;
    final key = _key;
    final title = detail.album.title;
    final renamed = offline.collectionNames[key] != title;
    final notifier = ref.read(offlineProvider.notifier);
    Future.microtask(() async {
      try {
        await notifier.syncCollection(key, detail.tracks);
        if (renamed) await notifier.keepCollection(key, title, detail.tracks);
      } catch (_) {
        // Abgleich klappt beim nächsten Öffnen
      }
    });
  }

  Future<void> _refresh() async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Du bist offline');
      return;
    }
    final artistId = ref.read(albumProvider(_id)).value?.album.artist.id;
    ref.invalidate(albumProvider(_id));
    if (artistId != null) ref.invalidate(_moreAlbumsProvider(artistId));
    try {
      await ref.read(albumProvider(_id).future);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(albumProvider(_id));
    final noNetwork = ref.watch(isOfflineProvider);
    final detail = async.value;
    if (detail != null) {
      return _AlbumPage(albumId: _id, info: _AlbumInfo.online(detail), onRefresh: _refresh);
    }

    final kept = ref.watch(offlineProvider.select((s) => s.isCollectionOffline(_key)));
    final offlineLoaded = ref.watch(offlineProvider.select((s) => s.loaded));
    if ((noNetwork || async.hasError) && kept) {
      // Nur neu aufbauen, wenn sich Titel/Sammlungen ändern (nicht bei jedem Fortschritts-Tick)
      ref.watch(offlineProvider.select((s) => (s.tracks, s.collections, s.collectionNames)));
      return _AlbumPage(
        albumId: _id,
        info: _AlbumInfo.device(ref.read(offlineProvider), _key),
        onRefresh: _refresh,
        notice: DetailNotice(
          text: noNetwork
              ? 'Keine Verbindung – du siehst die heruntergeladene Version.'
              : 'Server nicht erreichbar – du siehst die heruntergeladene Version.',
          onRetry: noNetwork ? null : () => ref.invalidate(albumProvider(_id)),
        ),
      );
    }

    final Widget body;
    if (noNetwork && offlineLoaded) {
      body = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Du bist offline',
        message: 'Dieses Album ist nicht auf deinem Handy. Ohne Verbindung kannst du nur heruntergeladene Musik hören.',
        action: OutlinedButton(onPressed: () => Nav.offline(context), child: const Text('Heruntergeladene Musik')),
      );
    } else if (async.hasError && !noNetwork) {
      body = ErrorView(message: errorText(async.error!), onRetry: () => ref.invalidate(albumProvider(_id)));
    } else {
      body = const Center(child: CircularProgressIndicator());
    }
    return Scaffold(appBar: AppBar(), body: body);
  }
}

// ------------------------------------------------------------------ Seite

class _AlbumPage extends StatelessWidget {
  final int albumId;
  final _AlbumInfo info;
  final Future<void> Function() onRefresh;
  final Widget? notice;

  const _AlbumPage({required this.albumId, required this.info, required this.onRefresh, this.notice});

  PlayContext get _playContext => PlayContext('album', id: albumId, title: info.title);

  List<Widget> _trackRows() {
    final tracks = info.tracks;
    final playContext = _playContext;
    final multiDisc = {for (final t in tracks) t.discNumber ?? 1}.length > 1;
    final rows = <Widget>[];
    int? lastDisc;
    for (final track in tracks) {
      final disc = track.discNumber ?? 1;
      if (multiDisc && disc != lastDisc) {
        rows.add(_DiscHeader(disc: disc, first: lastDisc == null));
        lastDisc = disc;
      }
      rows.add(DetailTrackTile(
        track: track,
        queue: tracks,
        playContext: playContext,
        showNumber: true,
        showCover: false,
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = info.tracks;
    final artist = info.artist;
    return DetailScaffold(
      title: info.title,
      color: parseHexColor(info.coverColor) ?? AppColors.surfaceHighest,
      collapseOffset: 300,
      bodyBuilder: (context, topInset) => RefreshIndicator(
        color: AppColors.accent,
        edgeOffset: topInset,
        onRefresh: onRefresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _AlbumHeader(
                albumId: albumId,
                info: info,
                topInset: topInset,
                playContext: _playContext,
                notice: notice,
              ),
            ),
            if (tracks.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: info.fromDevice
                      ? const EmptyState(
                          icon: Icons.downloading_rounded,
                          title: 'Noch nichts auf dem Handy',
                          message: 'Die Songs dieses Albums werden geladen, sobald du wieder online bist.',
                        )
                      : const EmptyState(
                          icon: Icons.album_rounded,
                          title: 'Dieses Album ist leer',
                          message: 'Sobald Songs dazukommen, findest du sie hier.',
                        ),
                ),
              )
            else
              SliverList.list(children: _trackRows()),
            if (tracks.isNotEmpty) SliverToBoxAdapter(child: _AlbumFooter(info: info)),
            if (!info.fromDevice && artist != null)
              SliverToBoxAdapter(child: _MoreFromArtist(artist: artist, albumId: albumId)),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }
}

/// Kopfbereich: großes Cover, Titel, Künstler, „Album · Jahr“ und Aktionen.
class _AlbumHeader extends ConsumerWidget {
  final int albumId;
  final _AlbumInfo info;
  final double topInset;
  final PlayContext playContext;
  final Widget? notice;

  const _AlbumHeader({
    required this.albumId,
    required this.info,
    required this.topInset,
    required this.playContext,
    this.notice,
  });

  String get _meta {
    final parts = <String>['Album', if (info.year != null) '${info.year}'];
    if (info.fromDevice && info.tracks.length < info.totalTracks) {
      parts.add('${info.tracks.length} von ${pluralSongs(info.totalTracks)} auf dem Handy');
    }
    return parts.join(' · ');
  }

  void _showMenu(BuildContext context, WidgetRef ref) {
    final tracks = info.tracks;
    final artist = info.artist;
    final hasAudio = tracks.any((t) => !t.isVideo);
    showDetailSheet(
      context,
      header: ListTile(
        leading: CoverImage(coverId: info.coverId, size: 48, placeholderIcon: Icons.album_rounded),
        title: Text(info.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
        subtitle: Text(
          [if (artist != null) artist.name, 'Album'].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.tileSubtitle,
        ),
      ),
      builder: (sheetContext) {
        void close() => Navigator.of(sheetContext).pop();
        return [
          if (!info.fromDevice && tracks.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('Zu Playlist hinzufügen'),
              onTap: () {
                close();
                showAddToPlaylist(context, ref, tracks);
              },
            ),
          if (hasAudio) ...[
            ListTile(
              leading: const Icon(Icons.queue_play_next_rounded),
              title: const Text('Als Nächstes spielen'),
              onTap: () {
                close();
                detailEnqueue(context, ref, tracks, next: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Zur Warteschlange hinzufügen'),
              onTap: () {
                close();
                detailEnqueue(context, ref, tracks);
              },
            ),
          ],
          if (artist != null)
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: const Text('Zum Künstler'),
              onTap: () {
                close();
                Nav.artist(context, artist.id);
              },
            ),
        ];
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final coverSize = math.max(160.0, math.min(240.0, width - 120));
    final artist = info.artist;
    return CoverGradient(
      colorHex: info.coverColor,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset + 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  boxShadow: [BoxShadow(color: Color(0x99000000), blurRadius: 36, offset: Offset(0, 12))],
                ),
                child: CoverImage(
                  coverId: info.coverId,
                  size: coverSize,
                  radius: 4,
                  requestSize: 600,
                  placeholderIcon: Icons.album_rounded,
                ),
              ),
            ),
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                info.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white, height: 1.15),
              ),
            ),
            if (artist != null) ...[
              const SizedBox(height: 10),
              _ArtistLink(artist: artist),
            ],
            const SizedBox(height: 6),
            Text(_meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
            if (notice != null) ...[const SizedBox(height: 6), notice!],
            const SizedBox(height: 4),
            Row(
              children: [
                if (!info.fromDevice) _SaveAlbumButton(albumId: albumId),
                DetailOfflineButton(
                  collectionKey: albumKey(albumId),
                  name: info.title,
                  tracks: info.tracks,
                  canKeep: !info.fromDevice,
                ),
                IconButton(
                  tooltip: 'Mehr',
                  iconSize: 26,
                  icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
                  onPressed: () => _showMenu(context, ref),
                ),
                const Spacer(),
                DetailPlayControls(tracks: info.tracks, playContext: playContext),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Künstler unter dem Albumtitel – Tippen öffnet die Künstlerseite.
class _ArtistLink extends StatelessWidget {
  final ArtistRef artist;
  const _ArtistLink({required this.artist});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Nav.artist(context, artist.id),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(color: AppColors.surfaceHighest, shape: BoxShape.circle),
              child: const Icon(Icons.person_rounded, size: 15, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// Herz: Album in der eigenen Bibliothek speichern.
class _SaveAlbumButton extends ConsumerWidget {
  final int albumId;
  const _SaveAlbumButton({required this.albumId});

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool saved) async {
    try {
      await ref.read(likesProvider.notifier).toggleAlbum(albumId);
      if (context.mounted) {
        showMessage(context, saved ? 'Aus deiner Bibliothek entfernt' : 'Zu deiner Bibliothek hinzugefügt');
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(isAlbumSavedProvider(albumId));
    return IconButton(
      tooltip: saved ? 'Aus deiner Bibliothek entfernen' : 'Zu deiner Bibliothek hinzufügen',
      iconSize: 28,
      icon: Icon(
        saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: saved ? AppColors.accent : AppColors.textSecondary,
      ),
      onPressed: () => _toggle(context, ref, saved),
    );
  }
}

/// Zwischenüberschrift „CD 1“, „CD 2“ … bei Alben mit mehreren CDs.
class _DiscHeader extends StatelessWidget {
  final int disc;
  final bool first;
  const _DiscHeader({required this.disc, required this.first});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, first ? 8 : 20, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.album_outlined, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Text('CD $disc', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
        ],
      ),
    );
  }
}

/// Infos unter der Titelliste: Jahr, Anzahl/Länge, Genre, seit wann in der Bibliothek.
class _AlbumFooter extends StatelessWidget {
  final _AlbumInfo info;
  const _AlbumFooter({required this.info});

  @override
  Widget build(BuildContext context) {
    final count = info.fromDevice ? info.totalTracks : info.tracks.length;
    final genre = info.genre?.trim();
    final addedAt = info.addedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info.year != null) ...[
            Text('${info.year}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(height: 4),
          ],
          Text(
            info.fromDevice && info.tracks.length < count
                ? '${pluralSongs(count)} · ${info.tracks.length} auf dem Handy'
                : '${pluralSongs(count)}, ${formatLongDuration(info.duration)}',
            style: AppText.tileSubtitle,
          ),
          if (genre != null && genre.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(genre, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
          ],
          if (addedAt != null) ...[
            const SizedBox(height: 2),
            Text('In der Bibliothek seit ${formatDate(addedAt)}', style: AppText.caption),
          ],
        ],
      ),
    );
  }
}

/// „Mehr von …“ – die anderen Alben des Künstlers.
class _MoreFromArtist extends ConsumerWidget {
  final ArtistRef artist;
  final int albumId;

  const _MoreFromArtist({required this.artist, required this.albumId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(_moreAlbumsProvider(artist.id));
    return albums.when(
      data: (items) {
        final others = items.where((a) => a.id != albumId).toList();
        if (others.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('Mehr von ${artist.name}', onMore: () => Nav.artist(context, artist.id)),
            CardRow(children: [for (final album in others) MediaCard.album(context, album)]),
          ],
        );
      },
      loading: () => const SizedBox(
        height: 120,
        child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: DetailInlineError(
          message: 'Weitere Alben konnten nicht geladen werden: ${errorText(error)}',
          onRetry: () => ref.invalidate(_moreAlbumsProvider(artist.id)),
        ),
      ),
    );
  }
}
