import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/downloads.dart';
import '../../state/library.dart';
import '../nav.dart';
import '../widgets/common.dart';
import '../widgets/download_widgets.dart';
import '../widgets/playlist_picker.dart';

// ------------------------------------------------------------------ Daten

typedef YouTubeSearchArgs = ({String query, String type});

/// Treffer bei YouTube Music. Erfolgreiche Ergebnisse bleiben ein paar Minuten zwischengespeichert,
/// damit das Hin- und Herschalten zwischen Songs/Videos/Alben nicht jedes Mal neu lädt.
final youtubeSearchProvider = FutureProvider.autoDispose.family<List<YouTubeItem>, YouTubeSearchArgs>(
  (ref, args) async {
    final items = await requireApi(ref).youtubeSearch(args.query, type: args.type, limit: 20);
    if (ref.mounted) {
      final link = ref.keepAlive();
      final timer = Timer(const Duration(minutes: 3), link.close);
      ref.onDispose(timer.cancel);
    }
    return items;
  },
  // Fehler sofort zeigen (mit "Erneut versuchen") statt still im Hintergrund neu zu versuchen
  retry: (_, _) => null,
);

/// YouTube bzw. Server gerade nicht erreichbar (502/503/504 oder kein Netz)?
bool isYouTubeOutage(Object error) {
  if (error is! ApiException) return false;
  final status = error.statusCode;
  return status == null || status >= 500;
}

const downloadsLockedText = 'Downloads sind für dein Konto nicht freigeschaltet – frag einen Admin.';

/// "Künstler · Album · 3:45" bzw. "Künstler · Video · 3:45"
String youtubeItemSubtitle(YouTubeItem item, {bool withDuration = true}) {
  final album = item.album;
  return [
    if (item.artistDisplay.isNotEmpty) item.artistDisplay,
    if (item.isVideo) 'Video' else if (album != null && album.isNotEmpty) album,
    if (withDuration && item.duration != null) formatDuration(secondsToDuration(item.duration!)),
  ].join(' · ');
}

// ------------------------------------------------------------------ Aktionen

/// Titel aus der Bibliothek öffnen: Songs abspielen, Videos im Video-Player zeigen.
Future<void> openLibraryTrack(BuildContext context, int trackId) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final track = await container.read(apiProvider)!.track(trackId);
    if (!context.mounted) return;
    if (track.isVideo) {
      container.read(audioHandlerProvider).pause();
      Nav.video(context, track);
      return;
    }
    await container.read(playerProvider).playOne(track, context: const PlayContext('search'));
  } on StateError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> _startDownload(BuildContext context, YouTubeItem item, {int? playlistId}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await container.read(downloadsProvider.notifier).startItem(item, playlistId: playlistId);
    if (!context.mounted) return;
    showMessage(
      context,
      playlistId == null ? '„${item.title}“ wird geholt' : '„${item.title}“ wird geholt und landet in deiner Playlist',
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Menü zu einem YouTube-Treffer: Holen, Holen + Playlist, Abspielen, Album ansehen …
Future<void> showYouTubeItemSheet(BuildContext context, WidgetRef ref, YouTubeItem item, {bool showAlbumLink = true}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => _YouTubeItemSheet(item: item, parentContext: context, parentRef: ref, showAlbumLink: showAlbumLink),
  );
}

class _YouTubeItemSheet extends ConsumerWidget {
  final YouTubeItem item;
  final BuildContext parentContext;
  final WidgetRef parentRef;
  final bool showAlbumLink;

  const _YouTubeItemSheet({
    required this.item,
    required this.parentContext,
    required this.parentRef,
    required this.showAlbumLink,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = item.videoId == null ? null : ref.watch(jobForVideoProvider(item.videoId!));
    final canDownload = ref.watch(currentUserProvider)?.canDownload ?? false;
    final trackId = job?.trackId ?? item.inLibraryTrackId;
    final failed = job != null && job.isFailed;
    final albumBrowseId = item.albumBrowseId;
    final subtitle = youtubeItemSubtitle(item, withDuration: false);

    void close() => Navigator.of(context).pop();

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ThumbnailImage(url: item.thumbnailUrl, size: item.isVideo ? 40 : 48, video: item.isVideo),
              title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
              subtitle: subtitle.isEmpty
                  ? null
                  : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
            ),
            const Divider(),
            if (trackId != null) ...[
              ListTile(
                leading: Icon(item.isVideo ? Icons.smart_display_rounded : Icons.play_circle_outline_rounded),
                title: Text(item.isVideo ? 'Video ansehen' : 'Abspielen'),
                subtitle: const Text('Ist schon in deiner Bibliothek', style: AppText.tileSubtitle),
                onTap: () {
                  close();
                  openLibraryTrack(parentContext, trackId);
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Zu Playlist hinzufügen'),
                onTap: () async {
                  close();
                  final api = ProviderScope.containerOf(parentContext, listen: false).read(apiProvider)!;
                  try {
                    final track = await api.track(trackId);
                    if (parentContext.mounted) await showAddToPlaylist(parentContext, parentRef, [track]);
                  } catch (e) {
                    if (parentContext.mounted) showError(parentContext, e);
                  }
                },
              ),
            ] else if (job != null && job.isActive) ...[
              ListTile(
                leading: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                title: const Text('Wird geholt …'),
                subtitle: Padding(padding: const EdgeInsets.only(top: 6), child: JobProgress(job: job)),
              ),
              ListTile(
                leading: const Icon(Icons.cancel_outlined),
                title: const Text('Download abbrechen'),
                onTap: () async {
                  close();
                  final downloads = ProviderScope.containerOf(parentContext, listen: false).read(downloadsProvider.notifier);
                  try {
                    await downloads.cancel(job.id);
                  } catch (e) {
                    if (parentContext.mounted) showError(parentContext, e);
                  }
                },
              ),
            ] else if (item.videoId == null) ...[
              const ListTile(
                leading: Icon(Icons.block_rounded),
                title: Text('Nicht verfügbar'),
                subtitle: Text('Dieser Titel ist bei YouTube Music gerade nicht abrufbar.', style: AppText.tileSubtitle),
              ),
            ] else ...[
              if (!canDownload)
                const ListTile(
                  leading: Icon(Icons.lock_outline_rounded),
                  title: Text(downloadsLockedText, style: AppText.tileSubtitle),
                ),
              ListTile(
                enabled: canDownload,
                leading: Icon(failed ? Icons.refresh_rounded : Icons.download_rounded),
                title: Text(failed ? 'Erneut holen' : 'Holen'),
                subtitle: failed
                    ? Text(
                        'Letzter Versuch fehlgeschlagen: ${job.error ?? 'unbekannter Fehler'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tileSubtitle.copyWith(color: AppColors.danger),
                      )
                    : Text(item.isVideo ? 'Als Video in deine Bibliothek' : 'Als Song in deine Bibliothek',
                        style: AppText.tileSubtitle),
                onTap: () {
                  close();
                  _startDownload(parentContext, item);
                },
              ),
              ListTile(
                enabled: canDownload,
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Holen und zu Playlist hinzufügen'),
                onTap: () async {
                  close();
                  final playlistId = await pickPlaylist(parentContext);
                  if (playlistId == null || !parentContext.mounted) return;
                  await _startDownload(parentContext, item, playlistId: playlistId);
                },
              ),
            ],
            if (showAlbumLink && !item.isVideo && albumBrowseId != null)
              ListTile(
                leading: const Icon(Icons.album_rounded),
                title: const Text('Album ansehen'),
                subtitle: item.album == null
                    ? null
                    : Text(item.album!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
                onTap: () {
                  close();
                  Nav.youtubeAlbum(parentContext, albumBrowseId);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Bausteine

/// Kleines "E" für Explicit-Titel.
class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(color: AppColors.textSecondary, borderRadius: BorderRadius.circular(2)),
      child: const Text('E', style: TextStyle(color: Colors.black, fontSize: 9.5, fontWeight: FontWeight.w800)),
    );
  }
}

/// Song- oder Video-Treffer von YouTube Music mit "Holen"-Knopf.
/// Mit [number] wird statt des Vorschaubilds die Tracknummer gezeigt (Albumansicht).
class YouTubeItemTile extends ConsumerWidget {
  final YouTubeItem item;
  final int? number;
  /// Wird aufgerufen, wenn der Treffer geöffnet wird (z. B. Suchbegriff merken).
  final VoidCallback? onOpen;
  final bool showAlbumLink;

  const YouTubeItemTile({super.key, required this.item, this.number, this.onOpen, this.showAlbumLink = true});

  void _openSheet(BuildContext context, WidgetRef ref) {
    onOpen?.call();
    showYouTubeItemSheet(context, ref, item, showAlbumLink: showAlbumLink);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = item.videoId == null ? null : ref.watch(jobForVideoProvider(item.videoId!));
    final trackId = job?.trackId ?? item.inLibraryTrackId;
    final available = item.videoId != null || trackId != null;
    final albumMode = number != null;
    final details = albumMode ? item.artistDisplay : youtubeItemSubtitle(item);
    final subtitle = available ? details : ['Nicht verfügbar', if (details.isNotEmpty) details].join(' · ');
    final titleColor = available ? Colors.white : AppColors.textMuted;

    final Widget leading = albumMode
        ? SizedBox(
            width: 28,
            child: Text('$number', textAlign: TextAlign.center, style: AppText.tileSubtitle),
          )
        : ThumbnailImage(url: item.thumbnailUrl, size: item.isVideo ? 40 : 48, video: item.isVideo);

    final Widget trailing = available
        ? DownloadButton(item: item)
        : const Tooltip(
            message: 'Bei YouTube Music nicht abrufbar',
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Icon(Icons.block_rounded, size: 20, color: AppColors.textMuted),
            ),
          );

    return InkWell(
      onTap: !available
          ? null
          : () {
              if (trackId != null) {
                onOpen?.call();
                openLibraryTrack(context, trackId);
              } else {
                _openSheet(context, ref);
              }
            },
      onLongPress: () => _openSheet(context, ref),
      child: Padding(
        padding: EdgeInsets.fromLTRB(albumMode ? 12 : 16, 6, 8, 6),
        child: Row(
          children: [
            leading,
            SizedBox(width: albumMode ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle.copyWith(color: titleColor),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (item.explicit) const ExplicitBadge(),
                      if (trackId != null)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.check_circle_rounded, size: 13, color: AppColors.accent),
                        ),
                      Expanded(
                        child: Text(
                          subtitle.isEmpty ? (item.isVideo ? 'Video' : 'Song') : subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.tileSubtitle,
                        ),
                      ),
                    ],
                  ),
                  if (job != null && job.isFailed && trackId == null)
                    Padding(padding: const EdgeInsets.only(top: 2), child: JobProgress(job: job, compact: true)),
                ],
              ),
            ),
            if (albumMode && item.duration != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(formatDuration(secondsToDuration(item.duration!)), style: AppText.caption),
              ),
            const SizedBox(width: 4),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// Album-Treffer von YouTube Music – öffnet die Albumansicht.
class YouTubeAlbumTile extends StatelessWidget {
  final YouTubeItem item;
  final VoidCallback? onOpen;

  const YouTubeAlbumTile({super.key, required this.item, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final browseId = item.browseId;
    final subtitle = [
      'Album',
      if (item.artistDisplay.isNotEmpty) item.artistDisplay,
      if (item.year != null) '${item.year}',
    ].join(' · ');
    return InkWell(
      onTap: browseId == null
          ? null
          : () {
              onOpen?.call();
              Nav.youtubeAlbum(context, browseId);
            },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            ThumbnailImage(url: item.thumbnailUrl, size: 56),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (item.explicit) const ExplicitBadge(),
                      Expanded(
                        child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// "YouTube Music ist gerade nicht erreichbar" mit "Erneut versuchen" (inline, kein Absturz).
class YouTubeUnavailableView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const YouTubeUnavailableView({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final outage = isYouTubeOutage(error);
    final detail = errorText(error);
    final title = outage ? 'YouTube Music ist gerade nicht erreichbar' : detail;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.cloud_off_rounded, color: AppColors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ],
          ),
          if (outage && detail != title) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
            ),
          ],
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Erneut versuchen'),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Abschnitt in der Suche

const _types = [('songs', 'Songs'), ('videos', 'Videos'), ('albums', 'Alben')];

/// "Nicht dabei? Von YouTube holen" – Treffer bei YouTube Music (Sliver).
class YouTubeSearchSection extends ConsumerWidget {
  final String query;
  final String type;
  final ValueChanged<String> onTypeChanged;
  final VoidCallback onOpen;

  const YouTubeSearchSection({
    super.key,
    required this.query,
    required this.type,
    required this.onTypeChanged,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canDownload = ref.watch(currentUserProvider)?.canDownload ?? false;
    final args = (query: query, type: type);
    final results = ref.watch(youtubeSearchProvider(args));
    final items = results.value;
    final failed = results.hasError && !results.isLoading;

    Widget body;
    if (failed) {
      body = SliverToBoxAdapter(
        child: YouTubeUnavailableView(
          error: results.error!,
          onRetry: () => ref.invalidate(youtubeSearchProvider(args)),
        ),
      );
    } else if (items == null) {
      body = const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else if (items.isEmpty) {
      body = SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            switch (type) {
              'videos' => 'Keine Videos zu „$query“ bei YouTube Music gefunden.',
              'albums' => 'Keine Alben zu „$query“ bei YouTube Music gefunden.',
              _ => 'Keine Songs zu „$query“ bei YouTube Music gefunden.',
            },
            style: AppText.tileSubtitle,
          ),
        ),
      );
    } else {
      body = SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return item.isAlbum
              ? YouTubeAlbumTile(item: item, onOpen: onOpen)
              : YouTubeItemTile(item: item, onOpen: onOpen);
        },
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 28, 16, 2),
                child: Row(
                  children: [
                    Icon(Icons.smart_display_rounded, color: Color(0xFFFF0033), size: 24),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text('Nicht dabei? Von YouTube holen',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.sectionTitle),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(50, 0, 16, 8),
                child: Text('Treffer bei YouTube Music', style: AppText.caption),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final (key, label) in _types)
                      ChoiceChip(
                        label: Text(label),
                        selected: type == key,
                        showCheckmark: false,
                        labelStyle: TextStyle(
                          color: type == key ? Colors.black : Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                        onSelected: (_) => onTypeChanged(key),
                      ),
                  ],
                ),
              ),
              if (!canDownload)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.textSecondary),
                      SizedBox(width: 8),
                      Expanded(child: Text(downloadsLockedText, style: AppText.caption)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        body,
      ],
    );
  }
}
