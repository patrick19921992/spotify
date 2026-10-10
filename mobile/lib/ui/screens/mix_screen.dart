import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/offline.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import '../widgets/playlist_picker.dart';
import '../widgets/track_tile.dart';
import 'home_widgets.dart';

/// Ein Mix (Genre-Mix, Entdecken, Künstler-/Rubrik-Mix …) – aufgebaut wie eine Playlist.
class MixScreen extends ConsumerWidget {
  final String mixKey;
  const MixScreen({super.key, required this.mixKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mix = ref.watch(mixProvider(mixKey));
    final noNetwork = ref.watch(isOfflineProvider);
    final data = mix.value;
    return HomeGradientScaffold(
      title: data?.title ?? '',
      color: parseHexColor(data?.coverColor) ?? AppColors.surfaceHighest,
      bodyBuilder: (context, topInset) {
        if (data != null) return _MixBody(mix: data, mixKey: mixKey, topInset: topInset);
        if (mix.hasError) {
          if (noNetwork) {
            return const EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Du bist offline',
              message: 'Mixe werden vom Server zusammengestellt. Deine heruntergeladene Musik findest du auf der Startseite.',
            );
          }
          return ErrorView(message: errorText(mix.error!), onRetry: () => ref.invalidate(mixProvider(mixKey)));
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}

class _MixBody extends ConsumerWidget {
  final Mix mix;
  final String mixKey;
  final double topInset;

  const _MixBody({required this.mix, required this.mixKey, required this.topInset});

  PlayContext get _playContext => PlayContext('mix', title: mix.title);

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    ref.invalidate(mixProvider(mixKey));
    try {
      await ref.read(mixProvider(mixKey).future);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = mix.tracks;
    return RefreshIndicator(
      color: AppColors.accent,
      edgeOffset: topInset,
      onRefresh: () => _refresh(context, ref),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _MixHeader(mix: mix, topInset: topInset, playContext: _playContext)),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 24),
                child: EmptyState(
                  icon: Icons.queue_music_rounded,
                  title: 'Dieser Mix ist noch leer',
                  message: 'Sobald passende Titel in deiner Bibliothek sind, tauchen sie hier auf.',
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) =>
                  TrackTile(track: tracks[index], queue: tracks, context_: _playContext),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

/// Kopfbereich: großes Mosaik-Cover, Titel, Infos und Aktionen.
class _MixHeader extends ConsumerWidget {
  final Mix mix;
  final double topInset;
  final PlayContext playContext;

  const _MixHeader({required this.mix, required this.topInset, required this.playContext});

  bool _matches(PlayContext c) => c.type == 'mix' && c.title == mix.title;

  void _showMenu(BuildContext context, WidgetRef ref) {
    final tracks = mix.tracks;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        Future<void> run(Future<void> Function() action, String done) async {
          Navigator.of(sheetContext).pop();
          try {
            await action();
            if (context.mounted) showMessage(context, done);
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: PlaylistCover(coverId: null, mosaic: mix.mosaic, size: 48),
                title: Text(mix.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                subtitle: Text(pluralSongs(tracks.length), style: AppText.tileSubtitle),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: const Text('Zur Warteschlange hinzufügen'),
                onTap: () => run(
                  () => ref.read(playerProvider).addToQueue(tracks),
                  '${pluralSongs(tracks.length)} zur Warteschlange hinzugefügt',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Zu Playlist hinzufügen'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showAddToPlaylist(context, ref, tracks);
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Alle aufs Handy laden'),
                onTap: () => run(
                  () async => ref.read(offlineProvider.notifier).downloadTracks(tracks),
                  'Wird aufs Handy geladen',
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = mix.tracks;
    final active = watchIsPlayingContext(ref, _matches, tracks);
    final playing = active && ref.watch(isPlayingProvider);
    final shuffleOn = active &&
        ref.watch(playbackStateProvider).value?.shuffleMode == AudioServiceShuffleMode.all;
    final offline = ref.watch(offlineProvider);
    final downloadedCount = tracks.where((t) => offline.isDownloaded(t.id)).length;
    final allDownloaded = tracks.isNotEmpty && downloadedCount == tracks.length;
    final downloading = tracks.any((t) => offline.isPending(t.id));
    final duration = tracks.fold<double>(0, (sum, t) => sum + t.duration);
    final player = ref.read(playerProvider);

    return CoverGradient(
      colorHex: mix.coverColor,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 32, offset: Offset(0, 10))],
                ),
                child: PlaylistCover(
                  coverId: null,
                  mosaic: mix.mosaic,
                  size: 220,
                  radius: 4,
                  placeholderIcon: Icons.auto_awesome_rounded,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              mix.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
            ),
            if (mix.subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(mix.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.auto_awesome_rounded, size: 14, color: AppColors.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tracks.isEmpty
                        ? 'Selfify-Mix'
                        : '${pluralSongs(tracks.length)} · ${formatLongDuration(duration)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                if (downloading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                else
                  IconButton(
                    tooltip: allDownloaded ? 'Auf dem Handy' : 'Aufs Handy laden',
                    iconSize: 28,
                    icon: Icon(
                      allDownloaded ? Icons.arrow_circle_down_rounded : Icons.arrow_circle_down_outlined,
                      color: allDownloaded ? AppColors.accent : AppColors.textSecondary,
                    ),
                    onPressed: tracks.isEmpty
                        ? null
                        : () {
                            if (allDownloaded) {
                              showMessage(context, 'Alle Songs dieses Mixes sind auf deinem Handy');
                              return;
                            }
                            ref.read(offlineProvider.notifier).downloadTracks(tracks);
                            showMessage(context, 'Wird aufs Handy geladen');
                          },
                  ),
                IconButton(
                  tooltip: 'Mehr',
                  iconSize: 26,
                  color: AppColors.textSecondary,
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: tracks.isEmpty ? null : () => _showMenu(context, ref),
                ),
                const Spacer(),
                IconButton(
                  tooltip: shuffleOn ? 'Zufallswiedergabe aus' : 'Zufällig abspielen',
                  iconSize: 28,
                  icon: Icon(Icons.shuffle_rounded, color: shuffleOn ? AppColors.accent : AppColors.textSecondary),
                  onPressed: tracks.isEmpty
                      ? null
                      : () => active
                          ? player.toggleShuffle()
                          : playWithFeedback(context, ref, tracks, playContext: playContext, shuffle: true),
                ),
                const SizedBox(width: 8),
                PlayButton(
                  playing: playing,
                  onPressed: tracks.isEmpty
                      ? null
                      : () => active
                          ? player.togglePlay()
                          : playWithFeedback(context, ref, tracks, playContext: playContext),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
