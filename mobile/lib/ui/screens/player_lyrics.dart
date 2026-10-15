import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/settings.dart';
import '../widgets/cover.dart';
import 'player_widgets.dart';

/// Hintergrundfarbe der Songtext-Ansicht: Cover-Farbe, gedämpft, damit weiße Schrift gut lesbar ist.
Color lyricsColorFor(Track track) {
  final color = parseHexColor(track.coverColor);
  if (color == null) return AppColors.surfaceHighest;
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness(hsl.lightness.clamp(0.2, 0.34)).toColor();
}

bool _hasText(Lyrics lyrics) => lyrics.lines.any((line) => line.text.trim().isNotEmpty);

/// Karte „Songtext“ unter dem Player. Ohne Songtext wird sie ausgeblendet.
class PlayerLyricsCard extends ConsumerWidget {
  final Track track;
  final EdgeInsetsGeometry margin;

  const PlayerLyricsCard({super.key, required this.track, this.margin = EdgeInsets.zero});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Songtexte liegen auf dem Server – ohne Netz bzw. im Offline-Modus gibt es keine
    final offline = ref.watch(isOfflineProvider) || ref.watch(settingsProvider.select((s) => s.offlineMode));
    if (offline) return const SizedBox.shrink();
    final value = ref.watch(lyricsProvider(track.id));
    final lyrics = value.value;
    final color = lyricsColorFor(track);

    if (lyrics == null) {
      if (!value.hasError || value.isLoading) return const SizedBox.shrink();
      return Padding(
        padding: margin,
        child: _LyricsFrame(
          color: color,
          child: Padding(
            padding: const EdgeInsets.only(right: 8, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Der Songtext konnte nicht geladen werden. ${errorText(value.error!)}',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => ref.invalidate(lyricsProvider(track.id)),
                  child: const Text('Erneut versuchen'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_hasText(lyrics)) return const SizedBox.shrink();

    return Padding(
      padding: margin,
      child: _LyricsFrame(
        color: color,
        onExpand: () => showFullLyrics(context, track),
        child: SizedBox(
          height: 300,
          child: PlayerLyricsView(
            key: ValueKey(track.id),
            lyrics: lyrics,
            fontSize: 20,
            padding: const EdgeInsets.fromLTRB(0, 12, 8, 40),
          ),
        ),
      ),
    );
  }
}

class _LyricsFrame extends StatelessWidget {
  final Color color;
  final Widget child;
  final VoidCallback? onExpand;

  const _LyricsFrame({required this.color, required this.child, this.onExpand});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onExpand,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Songtext', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                  if (onExpand != null)
                    IconButton(
                      tooltip: 'Songtext im Vollbild',
                      iconSize: 20,
                      onPressed: onExpand,
                      icon: const Icon(Icons.open_in_full_rounded),
                    ),
                ],
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Songtext im Vollbild (folgt dem gerade laufenden Titel).
Future<void> showFullLyrics(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (_) => _FullLyricsSheet(initial: track),
  );
}

class _FullLyricsSheet extends ConsumerWidget {
  final Track initial;
  const _FullLyricsSheet({required this.initial});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider) ?? initial;
    final offline = ref.watch(isOfflineProvider) || ref.watch(settingsProvider.select((s) => s.offlineMode));
    final value = offline ? null : ref.watch(lyricsProvider(track.id));
    final lyrics = value?.value;

    Widget body;
    if (value == null) {
      body = const _SheetMessage(text: 'Songtexte gibt es nur mit Verbindung zum Server – nicht im Offline-Modus.');
    } else if (lyrics != null && _hasText(lyrics)) {
      body = PlayerLyricsView(
        key: ValueKey(track.id),
        lyrics: lyrics,
        fontSize: 26,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 80),
      );
    } else if (lyrics == null && value.isLoading) {
      body = const Center(child: CircularProgressIndicator(color: Colors.white));
    } else if (lyrics == null && value.hasError) {
      body = _SheetMessage(
        text: 'Der Songtext konnte nicht geladen werden. ${errorText(value.error!)}',
        onRetry: () => ref.invalidate(lyricsProvider(track.id)),
      );
    } else {
      body = const _SheetMessage(text: 'Für diesen Song gibt es keinen Songtext.');
    }

    return FractionallySizedBox(
      heightFactor: 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: lyricsColorFor(track),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: Colors.white54, borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: [
                    CoverImage(coverId: track.coverId, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(track.artistDisplay,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5, color: Colors.white70)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Schließen',
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(child: body),
              PlayerSeekBar(fallbackDuration: track.length),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Zurück',
                      iconSize: 40,
                      icon: const Icon(Icons.skip_previous_rounded),
                      onPressed: () => runPlayerAction(context, () => ref.read(playerProvider).previous()),
                    ),
                    const SizedBox(width: 20),
                    const PlayerPlayPauseButton(size: 60),
                    const SizedBox(width: 20),
                    IconButton(
                      tooltip: 'Weiter',
                      iconSize: 40,
                      icon: const Icon(Icons.skip_next_rounded),
                      onPressed: () => runPlayerAction(context, () => ref.read(playerProvider).next()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetMessage extends StatelessWidget {
  final String text;
  final VoidCallback? onRetry;
  const _SheetMessage({required this.text, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lyrics_outlined, size: 48, color: Colors.white70),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.white70)),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(onPressed: onRetry, child: const Text('Erneut versuchen')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Songtext-Zeilen. Zeitsynchron: aktuelle Zeile hervorgehoben und automatisch im Blick,
/// Tippen auf eine Zeile spult dorthin.
class PlayerLyricsView extends ConsumerStatefulWidget {
  final Lyrics lyrics;
  final double fontSize;
  final EdgeInsets padding;

  const PlayerLyricsView({super.key, required this.lyrics, this.fontSize = 22, this.padding = EdgeInsets.zero});

  @override
  ConsumerState<PlayerLyricsView> createState() => _PlayerLyricsViewState();
}

class _PlayerLyricsViewState extends ConsumerState<PlayerLyricsView> {
  /// Etwas früher hervorheben – wirkt natürlicher.
  static const _lead = 250;

  final _controller = ScrollController();
  final _columnKey = GlobalKey();
  late List<GlobalKey> _lineKeys;
  int? _shownIndex;
  DateTime? _userScrolledAt;

  List<LyricsLine> get _lines => widget.lyrics.lines;

  bool get _synced => widget.lyrics.synced && _lines.any((line) => line.timeMs != null);

  @override
  void initState() {
    super.initState();
    _lineKeys = List.generate(_lines.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant PlayerLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lyrics, widget.lyrics)) {
      _lineKeys = List.generate(_lines.length, (_) => GlobalKey());
      _shownIndex = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Index der Zeile, die bei [ms] gesungen wird (-1 = vor der ersten Zeile).
  int _indexAt(int ms) {
    var result = -1;
    for (var i = 0; i < _lines.length; i++) {
      final time = _lines[i].timeMs;
      if (time == null) continue;
      if (time <= ms) {
        result = i;
      } else {
        break;
      }
    }
    return result;
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final byUser = switch (notification) {
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      _ => false,
    };
    if (byUser) _userScrolledAt = DateTime.now();
    return false;
  }

  void _scrollTo(int index, {required bool animate}) {
    if (!mounted || !_controller.hasClients) return;
    final scrolledAt = _userScrolledAt;
    // Wer gerade selbst scrollt, wird nicht unterbrochen
    if (scrolledAt != null && DateTime.now().difference(scrolledAt) < const Duration(seconds: 4)) return;
    final position = _controller.position;
    var target = 0.0;
    if (index >= 0 && index < _lineKeys.length) {
      final lineBox = _lineKeys[index].currentContext?.findRenderObject() as RenderBox?;
      final columnBox = _columnKey.currentContext?.findRenderObject() as RenderBox?;
      if (lineBox == null || columnBox == null || !lineBox.attached || !columnBox.attached) return;
      final y = lineBox.localToGlobal(Offset.zero, ancestor: columnBox).dy + widget.padding.top;
      target = y + lineBox.size.height / 2 - position.viewportDimension * 0.38;
    }
    target = target.clamp(0.0, position.maxScrollExtent);
    if (animate) {
      _controller.animateTo(target, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    } else {
      _controller.jumpTo(target);
    }
  }

  void _seekTo(LyricsLine line) {
    final time = line.timeMs;
    if (time == null) return;
    _userScrolledAt = null;
    runPlayerAction(context, () => ref.read(playerProvider).seek(Duration(milliseconds: time)));
  }

  @override
  Widget build(BuildContext context) {
    final synced = _synced;
    var active = -1;
    if (synced) {
      // Nur neu aufbauen, wenn sich die aktuelle Zeile ändert
      active = ref.watch(positionProvider.select((value) => _indexAt((value.value ?? Duration.zero).inMilliseconds + _lead)));
      if (active != _shownIndex) {
        final first = _shownIndex == null;
        _shownIndex = active;
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(active, animate: !first));
      }
    }

    final baseStyle = TextStyle(fontSize: widget.fontSize, fontWeight: FontWeight.w800, height: 1.3);
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.06, 0.88, 1],
        ).createShader(rect),
        child: SingleChildScrollView(
          controller: _controller,
          padding: widget.padding,
          child: Column(
            key: _columnKey,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _lines.length; i++)
                _LyricsLineText(
                  key: _lineKeys[i],
                  text: _lines[i].text.trim().isEmpty ? '♪' : _lines[i].text,
                  style: baseStyle.copyWith(
                    color: !synced
                        ? Colors.white
                        : i == active
                            ? Colors.white
                            : i < active
                                ? Colors.white.withValues(alpha: 0.72)
                                : Colors.white.withValues(alpha: 0.38),
                  ),
                  onTap: synced && _lines[i].timeMs != null ? () => _seekTo(_lines[i]) : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LyricsLineText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final VoidCallback? onTap;

  const _LyricsLineText({super.key, required this.text, required this.style, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          style: style,
          child: Text(text),
        ),
      ),
    );
  }
}
