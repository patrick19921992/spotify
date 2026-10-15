import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/offline.dart';
import '../../state/settings.dart';
import '../nav.dart';
import '../widgets/common.dart';
import '../widgets/track_menu.dart';
import 'player_widgets.dart';

/// Titel laden, wenn die Seite ohne Titeldaten geöffnet wurde (z. B. über einen Link).
final _videoTrackProvider = FutureProvider.autoDispose.family<Track, int>((ref, id) => requireApi(ref).track(id));

final _unsupportedMessage = Platform.isWindows
    ? 'Dieses Video kann hier nicht abgespielt werden. MKV/WebM brauchen unter Windows oft Zusatz-Codecs '
        '(VP9-/AV1-Erweiterung aus dem Microsoft Store) – lade Videos als MP4.'
    : 'Dieses Video kann hier nicht abgespielt werden. MKV/WebM laufen oft nicht auf dem iPhone – lade Videos als MP4.';

/// Anzahl offener Videoseiten. Am Computer gehört die Leertaste dann dem Video, nicht der Musik.
final openVideoPages = ValueNotifier<int>(0);

const _offlineMessage = 'Du bist offline. Videos kannst du nur mit Verbindung zum Server ansehen.';
const _offlineModeMessage =
    'Der Offline-Modus ist an. Videos werden nicht aufs Handy geladen und lassen sich nur online ansehen.';

/// Videoplayer (mit Vollbild, Geschwindigkeit) und weitere Videos des Künstlers.
class VideoScreen extends ConsumerStatefulWidget {
  final int trackId;
  final Track? track;
  const VideoScreen({super.key, required this.trackId, this.track});

  @override
  ConsumerState<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends ConsumerState<VideoScreen> {
  late int _trackId;
  Track? _track;
  VideoPlayerController? _video;
  ChewieController? _chewie;
  _VideoProblem? _problem;

  /// Verhindert, dass ein veralteter Ladevorgang (nach Videowechsel) noch etwas anzeigt.
  int _generation = 0;
  bool _awake = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    openVideoPages.value++;
    _trackId = widget.trackId;
    _track = widget.track?.id == widget.trackId ? widget.track : null;
    // Musik pausieren – Video und Musik gleichzeitig ergibt keinen Sinn
    final handler = ref.read(audioHandlerProvider);
    if (handler.player.playing) handler.pause();
    _initialize(initial: true);
  }

  @override
  void dispose() {
    openVideoPages.value--;
    _generation++;
    final video = _video;
    video?.removeListener(_onVideoValue);
    _chewie?.dispose();
    video?.dispose();
    WakelockPlus.disable().ignore();
    _scroll.dispose();
    super.dispose();
  }

  /// Alte Controller freigeben – erst, wenn der Player sie nicht mehr anzeigt.
  void _releaseControllers() {
    final video = _video;
    final chewie = _chewie;
    _video = null;
    _chewie = null;
    if (video == null && chewie == null) return;
    video?.removeListener(_onVideoValue);
    video?.pause().ignore();
    void release() {
      chewie?.dispose();
      video?.dispose().ignore();
    }

    // Im Vollbild zuerst das Vollbild schließen und dessen Animation abwarten
    if (chewie != null && chewie.isFullScreen) {
      chewie.exitFullScreen();
      unawaited(Future<void>.delayed(const Duration(milliseconds: 800), release));
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => release());
    }
  }

  VideoPlayerController _createController(int trackId) {
    final local = ref.read(offlineProvider.notifier).localPath(trackId);
    if (local != null && File(local).existsSync()) return VideoPlayerController.file(File(local));
    if (ref.read(isOfflineProvider)) throw const _VideoProblem(_offlineMessage);
    if (ref.read(settingsProvider).offlineMode) throw const _VideoProblem(_offlineModeMessage, offlineMode: true);
    final api = ref.read(apiProvider);
    if (api == null) throw const _VideoProblem('Bitte melde dich erneut an.');
    return VideoPlayerController.networkUrl(Uri.parse(api.streamUrl(trackId)));
  }

  Future<void> _initialize({bool initial = false}) async {
    final generation = ++_generation;
    _releaseControllers();
    _problem = null;
    _setAwake(false);

    final VideoPlayerController controller;
    try {
      controller = _createController(_trackId);
    } catch (e) {
      _problem = e is _VideoProblem ? e : _VideoProblem(_unsupportedMessage);
      if (!initial && mounted) setState(() {});
      return;
    }
    if (!initial && mounted) setState(() {});

    try {
      await controller.initialize().timeout(const Duration(seconds: 45));
    } catch (_) {
      controller.dispose().ignore();
      if (mounted && generation == _generation) setState(() => _problem = _VideoProblem(_unsupportedMessage));
      return;
    }
    if (!mounted || generation != _generation) {
      controller.dispose().ignore();
      return;
    }

    controller.addListener(_onVideoValue);
    final colors = ChewieProgressColors(
      playedColor: AppColors.accent,
      handleColor: AppColors.accent,
      bufferedColor: Colors.white38,
      backgroundColor: Colors.white24,
    );
    final chewie = ChewieController(
      videoPlayerController: controller,
      autoPlay: true,
      allowFullScreen: true,
      allowPlaybackSpeedChanging: true,
      allowMuting: true,
      aspectRatio: _aspectRatio(controller, _track),
      playbackSpeeds: const [0.5, 0.75, 1, 1.25, 1.5, 2],
      materialProgressColors: colors,
      cupertinoProgressColors: colors,
      placeholder: const ColoredBox(color: Colors.black),
      optionsTranslation: OptionsTranslation(
        playbackSpeedButtonText: 'Geschwindigkeit',
        subtitlesButtonText: 'Untertitel',
        cancelButtonText: 'Abbrechen',
        qualityButtonText: 'Qualität',
      ),
      errorBuilder: (context, _) => _VideoMessage(
        problem: _VideoProblem(_unsupportedMessage),
        onRetry: _initialize,
      ),
    );
    setState(() {
      _video = controller;
      _chewie = chewie;
    });
  }

  Future<void> _goOnline() async {
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineMode: false));
    if (mounted) await _initialize();
  }

  void _setAwake(bool awake) {
    if (awake == _awake) return;
    _awake = awake;
    (awake ? WakelockPlus.enable() : WakelockPlus.disable()).ignore();
  }

  /// Bildschirm anlassen, solange das Video läuft; startet die Musik nebenbei, wird sie pausiert.
  void _onVideoValue() {
    final video = _video;
    if (!mounted || video == null) return;
    final playing = video.value.isPlaying;
    _setAwake(playing);
    if (playing) {
      final handler = ref.read(audioHandlerProvider);
      if (handler.player.playing) handler.pause();
    }
  }

  /// Anderes Video in derselben Ansicht abspielen.
  void _switchTo(Track next) {
    if (next.id == _trackId) return;
    setState(() {
      _trackId = next.id;
      _track = next;
    });
    _initialize();
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  Future<void> _refresh(Track track) async {
    final api = ref.read(apiProvider);
    final artist = track.artists.firstOrNull;
    try {
      if (api != null) {
        final fresh = await api.track(track.id);
        if (mounted && fresh.id == _trackId) setState(() => _track = fresh);
      }
      if (artist != null) {
        ref.invalidate(artistProvider(artist.id));
        await ref.read(artistProvider(artist.id).future);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  static double _aspectRatio(VideoPlayerController? controller, Track? track) {
    final value = controller?.value;
    if (value != null && value.isInitialized && value.size.width > 0 && value.size.height > 0) {
      return value.size.width / value.size.height;
    }
    final width = track?.width;
    final height = track?.height;
    if (width != null && height != null && width > 0 && height > 0) return width / height;
    return 16 / 9;
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _track == null ? ref.watch(_videoTrackProvider(_trackId)) : null;
    final track = _track ?? loaded?.value;
    final screenHeight = MediaQuery.sizeOf(context).height;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          tooltip: 'Zurück',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => closeFullScreen(context),
        ),
        title: const Text('Video', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          ColoredBox(
            color: Colors.black,
            child: SizedBox(
              width: double.infinity,
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: screenHeight * 0.6),
                  child: AspectRatio(
                    aspectRatio: _aspectRatio(_video, track),
                    child: _buildPlayer(track),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: _buildDetails(track, loaded)),
        ],
      ),
    );
  }

  Widget _buildPlayer(Track? track) {
    final problem = _problem;
    if (problem != null) {
      return _VideoMessage(problem: problem, onRetry: _initialize, onGoOnline: problem.offlineMode ? _goOnline : null);
    }
    final chewie = _chewie;
    if (chewie == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (track?.coverId != null) Opacity(opacity: 0.35, child: _VideoThumbnail(coverId: track!.coverId, size: 600)),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    return Chewie(key: ValueKey(_trackId), controller: chewie);
  }

  Widget _buildDetails(Track? track, AsyncValue<Track>? loaded) {
    if (track == null) {
      if (loaded != null && loaded.hasError && !loaded.isLoading) {
        return ErrorView(
          message: errorText(loaded.error!),
          onRetry: () => ref.invalidate(_videoTrackProvider(_trackId)),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final offline = ref.watch(isOfflineProvider) || ref.watch(settingsProvider.select((s) => s.offlineMode));
    final artist = track.artists.firstOrNull;
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () => _refresh(track),
      child: ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          _VideoInfo(track: track),
          if (artist != null && !offline) _MoreVideos(artist: artist, currentId: track.id, onSelect: _switchTo),
        ],
      ),
    );
  }
}

/// Warum das Video nicht läuft.
class _VideoProblem implements Exception {
  final String message;

  /// Offline-Modus ist an – Ausschalten hilft.
  final bool offlineMode;

  const _VideoProblem(this.message, {this.offlineMode = false});
}

/// Freundliche Meldung im Player-Bereich, mit „Erneut versuchen“.
class _VideoMessage extends StatelessWidget {
  final _VideoProblem problem;
  final VoidCallback onRetry;
  final VoidCallback? onGoOnline;

  const _VideoMessage({required this.problem, required this.onRetry, this.onGoOnline});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, size: 40, color: AppColors.textSecondary),
              const SizedBox(height: 12),
              Text(
                problem.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.35),
              ),
              const SizedBox(height: 14),
              if (onGoOnline != null)
                FilledButton(onPressed: onGoOnline, child: const Text('Offline-Modus ausschalten'))
              else
                OutlinedButton(onPressed: onRetry, child: const Text('Erneut versuchen')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Standbild eines Videos (vom Server, zwischengespeichert).
class _VideoThumbnail extends ConsumerWidget {
  final String? coverId;
  final int size;

  const _VideoThumbnail({required this.coverId, this.size = 300});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    const placeholder = ColoredBox(
      color: AppColors.surfaceHighest,
      child: Center(child: Icon(Icons.movie_rounded, color: AppColors.textMuted, size: 28)),
    );
    final id = coverId;
    if (id == null || api == null) return placeholder;
    return CachedNetworkImage(
      imageUrl: api.coverUrl(id, size: size),
      cacheKey: '$id-$size',
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

/// Titel, Künstler, Herz und Menü unter dem Video.
class _VideoInfo extends ConsumerWidget {
  final Track track;
  const _VideoInfo({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = [
      'Video',
      if (track.year != null) '${track.year}',
      if (track.duration > 0) formatDuration(track.length),
      if (track.height != null && track.height! > 0) '${track.height}p',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: track.artists.isEmpty
                      ? null
                      : () => openAfterPop(context, (c) => Nav.artist(c, track.artists.first.id)),
                  child: Text(
                    track.artistDisplay.isEmpty ? 'Unbekannter Künstler' : track.artistDisplay,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                  ),
                ),
                const SizedBox(height: 4),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ),
          ),
          PlayerLikeButton(track: track, size: 26),
          IconButton(
            tooltip: 'Mehr',
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () => showTrackMenu(context, ref, track),
          ),
        ],
      ),
    );
  }
}

/// „Weitere Videos von …“ – Tippen spielt das Video hier ab.
class _MoreVideos extends ConsumerWidget {
  final ArtistRef artist;
  final int currentId;
  final void Function(Track video) onSelect;

  const _MoreVideos({required this.artist, required this.currentId, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(artistProvider(artist.id));
    return value.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
        ),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Weitere Videos konnten nicht geladen werden. ${errorText(error)}',
              style: AppText.tileSubtitle,
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => ref.invalidate(artistProvider(artist.id)),
              child: const Text('Erneut versuchen'),
            ),
          ],
        ),
      ),
      data: (detail) {
        final others = detail.videos.where((video) => video.id != currentId).toList();
        if (others.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('Weitere Videos von ${detail.artist.name}'),
            for (final video in others) _VideoRow(video: video, onTap: () => onSelect(video)),
          ],
        );
      },
    );
  }
}

class _VideoRow extends StatelessWidget {
  final Track video;
  final VoidCallback onTap;

  const _VideoRow({required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final subtitle = [if (video.year != null) '${video.year}', video.artistDisplay].where((s) => s.isNotEmpty).join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 136,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _VideoThumbnail(coverId: video.coverId),
                      if (video.duration > 0)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(3)),
                            child: Text(
                              formatDuration(video.length),
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
