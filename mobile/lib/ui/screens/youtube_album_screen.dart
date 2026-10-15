import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/downloads.dart';
import '../../state/library.dart';
import '../nav.dart';
import '../shell.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import '../widgets/download_widgets.dart';
import 'search_youtube.dart';

/// Album von YouTube Music (Titelliste mit "Schon da?"-Angabe).
final _youtubeAlbumProvider = FutureProvider.autoDispose.family<YouTubeAlbum, String>(
  (ref, browseId) => requireApi(ref).youtubeAlbum(browseId),
  // Fehler sofort zeigen (mit "Erneut versuchen") statt still im Hintergrund neu zu versuchen
  retry: (_, _) => null,
);

/// Ab dieser Scrollhöhe erscheint der Albumtitel in der oberen Leiste.
const _collapseOffset = 250.0;

/// Ein Album von YouTube Music – ganz oder einzeln holen.
class YouTubeAlbumScreen extends ConsumerStatefulWidget {
  final String browseId;
  const YouTubeAlbumScreen({super.key, required this.browseId});

  @override
  ConsumerState<YouTubeAlbumScreen> createState() => _YouTubeAlbumScreenState();
}

class _YouTubeAlbumScreenState extends ConsumerState<YouTubeAlbumScreen> {
  final _scroll = ScrollController();
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final collapsed = _scroll.hasClients && _scroll.offset > _collapseOffset;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  void _retry() => ref.invalidate(_youtubeAlbumProvider(widget.browseId));

  Future<void> _refresh() async {
    ref.invalidate(_youtubeAlbumProvider(widget.browseId));
    try {
      await ref.read(_youtubeAlbumProvider(widget.browseId).future);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = ref.watch(_youtubeAlbumProvider(widget.browseId));
    final data = album.value;
    final failed = album.hasError && !album.isLoading;
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;

    Widget body;
    if (data != null) {
      body = RefreshIndicator(
        color: AppColors.accent,
        edgeOffset: topInset,
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _AlbumHeader(album: data, topInset: topInset),
            ),
            SliverToBoxAdapter(
              child: _AlbumActions(album: data, browseId: widget.browseId),
            ),
            if (data.tracks.isEmpty)
              const SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.album_rounded,
                  title: 'Keine Titel verfügbar',
                  message: 'Bei diesem Album sind gerade keine Songs abrufbar.',
                ),
              )
            else
              SliverList.builder(
                itemCount: data.tracks.length,
                itemBuilder: (context, index) {
                  final track = data.tracks[index];
                  return YouTubeItemTile(item: track, number: track.trackNumber ?? index + 1, showAlbumLink: false);
                },
              ),
            SliverToBoxAdapter(child: _AlbumFooter(album: data)),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      );
    } else if (failed) {
      final error = album.error!;
      body = SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: isYouTubeOutage(error)
                ? YouTubeUnavailableView(error: error, onRetry: _retry)
                : ErrorView(message: errorText(error), onRetry: _retry),
          ),
        ),
      );
    } else {
      body = const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: _collapsed && data != null ? AppColors.surfaceHighest : Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        title: AnimatedOpacity(
          opacity: _collapsed && data != null ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Text(
            data?.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
        actions: const [DownloadsAction()],
      ),
      body: body,
    );
  }
}

/// Kopfbereich: großes Vorschaubild, Titel, Künstler, "Album · Jahr · N Songs".
class _AlbumHeader extends StatelessWidget {
  final YouTubeAlbum album;
  final double topInset;

  const _AlbumHeader({required this.album, required this.topInset});

  @override
  Widget build(BuildContext context) {
    final meta = ['Album', if (album.year != null) '${album.year}', pluralSongs(album.tracks.length)].join(' · ');
    return CoverGradient(
      colorHex: null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 32, offset: Offset(0, 10))],
                ),
                child: ThumbnailImage(url: album.thumbnailUrl, size: 220),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              album.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
            ),
            if (album.artists.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                album.artists.join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.smart_display_rounded, size: 14, color: Color(0xFFFF0033)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Fortschritt ("3 von 12 in deiner Bibliothek") und "Ganzes Album holen" bzw. "In der Bibliothek ansehen".
class _AlbumActions extends ConsumerStatefulWidget {
  final YouTubeAlbum album;
  final String browseId;

  const _AlbumActions({required this.album, required this.browseId});

  @override
  ConsumerState<_AlbumActions> createState() => _AlbumActionsState();
}

class _AlbumActionsState extends ConsumerState<_AlbumActions> {
  bool _starting = false;
  bool _opening = false;

  Future<void> _startAlbum() async {
    setState(() => _starting = true);
    try {
      final jobs = await ref.read(downloadsProvider.notifier).startAlbum(widget.browseId);
      if (!mounted) return;
      final queued = jobs.where((j) => j.isActive).length;
      showMessage(context, switch (queued) {
        0 => 'Alle Songs sind schon in deiner Bibliothek',
        1 => '1 Titel wird geholt',
        _ => '$queued Titel werden geholt',
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Öffnet das Album in der eigenen Bibliothek (über den ersten Titel).
  Future<void> _openInLibrary(int trackId) async {
    setState(() => _opening = true);
    try {
      final track = await ref.read(apiProvider)!.track(trackId);
      if (!mounted) return;
      final album = track.album;
      if (album == null) {
        showMessage(context, 'Das Album ist in deiner Bibliothek nicht zu finden');
        return;
      }
      Nav.album(context, album.id);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadsProvider);
    final canDownload = ref.watch(currentUserProvider)?.canDownload ?? false;

    var total = 0;
    var inLibrary = 0;
    var active = 0;
    var missing = 0;
    var activeProgress = 0.0;
    int? firstTrackId;
    for (final track in widget.album.tracks) {
      final job = track.videoId == null
          ? null
          : downloads.forVideo(track.videoId!, mediaType: track.isVideo ? 'video' : 'audio');
      final done = job != null && job.isDone;
      if (track.videoId == null && track.inLibraryTrackId == null) continue; // bei YouTube nicht abrufbar
      total++;
      if (done || track.inLibraryTrackId != null) {
        inLibrary++;
        firstTrackId ??= (done ? job.trackId : null) ?? track.inLibraryTrackId;
      } else if (job != null && job.isActive) {
        active++;
        if (job.status == 'downloading') activeProgress += job.progress.clamp(0.0, 1.0);
      } else {
        missing++;
      }
    }
    final allInLibrary = total > 0 && inLibrary == total;
    final fraction = total == 0 ? 0.0 : ((inLibrary + activeProgress) / total).clamp(0.0, 1.0);

    final String status;
    if (total == 0) {
      status = 'Keine Songs abrufbar';
    } else if (allInLibrary) {
      status = total == 1 ? 'Ist in deiner Bibliothek' : 'Alle $total Songs sind in deiner Bibliothek';
    } else if (inLibrary == 0) {
      status = 'Noch nicht in deiner Bibliothek';
    } else {
      status = '$inLibrary von $total in deiner Bibliothek';
    }

    final Widget button;
    if (allInLibrary) {
      button = FilledButton.icon(
        onPressed: _opening || firstTrackId == null ? null : () => _openInLibrary(firstTrackId!),
        icon: _opening ? const _ButtonSpinner() : const Icon(Icons.library_music_rounded, size: 20),
        label: const Text('In der Bibliothek ansehen'),
      );
    } else {
      final label = _starting
          ? 'Wird gestartet …'
          : (missing == 0 && active > 0 ? 'Wird geholt …' : 'Ganzes Album holen');
      button = FilledButton.icon(
        onPressed: !canDownload || _starting || missing == 0 ? null : _startAlbum,
        icon: _starting ? const _ButtonSpinner() : const Icon(Icons.download_rounded, size: 20),
        label: Text(label),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                allInLibrary ? Icons.check_circle_rounded : Icons.library_music_outlined,
                size: 16,
                color: allInLibrary ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tileSubtitle.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (active > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: fraction > 0 ? fraction : null,
                minHeight: 4,
                backgroundColor: AppColors.surfaceHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text(active == 1 ? '1 Song wird geholt …' : '$active Songs werden geholt …', style: AppText.caption),
          ],
          const SizedBox(height: 16),
          button,
          if (!canDownload && !allInLibrary) ...[
            const SizedBox(height: 10),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.textSecondary),
                SizedBox(width: 8),
                Expanded(child: Text(downloadsLockedText, style: AppText.caption)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.black),
    );
  }
}

/// "12 Songs · 45 Min." unter der Titelliste.
class _AlbumFooter extends StatelessWidget {
  final YouTubeAlbum album;
  const _AlbumFooter({required this.album});

  @override
  Widget build(BuildContext context) {
    if (album.tracks.isEmpty) return const SizedBox.shrink();
    final seconds = album.tracks.fold<double>(0, (sum, t) => sum + (t.duration ?? 0));
    final parts = [pluralSongs(album.tracks.length), if (seconds > 0) formatLongDuration(seconds)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(parts.join(' · '), style: AppText.tileSubtitle),
          const SizedBox(height: 4),
          const Text('Quelle: YouTube Music', style: AppText.caption),
        ],
      ),
    );
  }
}
