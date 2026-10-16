import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/downloads.dart';
import '../../state/library.dart';
import '../nav.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import '../widgets/fit_text.dart';

// ------------------------------------------------------------------ Zuletzt gesucht

/// Die letzten 10 Suchbegriffe (auf dem Gerät gespeichert, neueste zuerst).
class RecentSearchesController extends Notifier<List<String>> {
  static const _key = 'search.recent';
  static const _max = 10;

  @override
  List<String> build() => ref.read(sharedPreferencesProvider).getStringList(_key) ?? const [];

  void add(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    final lower = q.toLowerCase();
    _save([q, ...state.where((e) => e.toLowerCase() != lower)].take(_max).toList());
  }

  void remove(String query) => _save(state.where((e) => e != query).toList());

  void clear() => _save(const []);

  void _save(List<String> next) {
    state = next;
    unawaited(ref.read(sharedPreferencesProvider).setStringList(_key, next));
  }
}

final recentSearchesProvider =
    NotifierProvider<RecentSearchesController, List<String>>(RecentSearchesController.new);

/// Eine Zeile unter "Zuletzt gesucht".
class RecentSearchTile extends StatelessWidget {
  final String query;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const RecentSearchTile({super.key, required this.query, required this.onTap, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(4)),
        child: const Icon(Icons.history_rounded, color: AppColors.textSecondary),
      ),
      title: Text(query, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
      trailing: IconButton(
        tooltip: 'Aus dem Verlauf entfernen',
        icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
        onPressed: onRemove,
      ),
    );
  }
}

// ------------------------------------------------------------------ Suchfeld

/// Weißes Suchfeld wie bei Spotify – bleibt beim Scrollen oben kleben.
class SearchFieldHeader extends SliverPersistentHeaderDelegate {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  const SearchFieldHeader({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  static const double height = 68;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final scrolled = shrinkOffset > 0 || overlapsContent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.background,
        boxShadow: scrolled
            ? const [BoxShadow(color: Color(0x99000000), blurRadius: 10, offset: Offset(0, 3))]
            : const [],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        // Feste Höhe (angeheftet) – daher sehr große Schrift im Feld etwas begrenzen
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.1,
          child: Align(
            alignment: Alignment.center,
            child: SearchField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              onClear: onClear,
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant SearchFieldHeader oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.focusNode != focusNode ||
      oldDelegate.onChanged != onChanged ||
      oldDelegate.onSubmitted != onSubmitted ||
      oldDelegate.onClear != onClear;
}

class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  const SearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        autocorrect: false,
        cursorColor: Colors.black,
        style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          hintText: 'Was möchtest du hören?',
          hintStyle: const TextStyle(color: Color(0xFF535353), fontSize: 16, fontWeight: FontWeight.w600),
          contentPadding: const EdgeInsets.symmetric(vertical: 13),
          prefixIcon: const Icon(Icons.search_rounded, color: Colors.black, size: 28),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Suche leeren',
                  icon: const Icon(Icons.close_rounded, color: Colors.black),
                  onPressed: onClear,
                ),
          border: border,
          enabledBorder: border,
          focusedBorder: border,
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Rubriken

/// Kräftige Farben für die Rubriken-Kacheln (wie bei Spotify "Alle durchsuchen").
const categoryPalette = <Color>[
  Color(0xFFE13300),
  Color(0xFF1E3264),
  Color(0xFF8D67AB),
  Color(0xFF27856A),
  Color(0xFFE8115B),
  Color(0xFF148A08),
  Color(0xFFBA5D07),
  Color(0xFF0D73EC),
  Color(0xFF8C1932),
  Color(0xFF477D95),
  Color(0xFFAF2896),
  Color(0xFF503750),
];

/// Material-Symbol zum Symbolnamen einer Rubrik (vom Server, z. B. "music_note").
IconData searchCategoryIcon(Category category) {
  return switch (category.icon) {
    'music_note' => Icons.music_note_rounded,
    'music_video' => Icons.music_video_rounded,
    'auto_stories' => Icons.auto_stories_rounded,
    'movie' => Icons.movie_rounded,
    'library_music' => Icons.library_music_rounded,
    'video_library' => Icons.video_library_rounded,
    'headphones' || 'headset' => Icons.headphones_rounded,
    'mic' || 'podcasts' => Icons.podcasts_rounded,
    'child_care' || 'child_friendly' || 'toys' => Icons.child_care_rounded,
    'menu_book' || 'book' => Icons.menu_book_rounded,
    'piano' => Icons.piano_rounded,
    'theaters' => Icons.theaters_rounded,
    'tv' || 'live_tv' => Icons.live_tv_rounded,
    'star' => Icons.star_rounded,
    'favorite' => Icons.favorite_rounded,
    'nightlight' || 'bedtime' => Icons.bedtime_rounded,
    'school' => Icons.school_rounded,
    'sports_esports' => Icons.sports_esports_rounded,
    'album' => Icons.album_rounded,
    'radio' => Icons.radio_rounded,
    _ => category.isVideo ? Icons.video_library_rounded : Icons.library_music_rounded,
  };
}

/// "12 Titel" bzw. "3 Videos".
String searchCategoryCount(Category category) {
  final n = category.itemCount;
  if (category.isVideo) return n == 1 ? '1 Video' : '$n Videos';
  return n == 1 ? '1 Titel' : '$n Titel';
}

/// Bunte Kachel einer Rubrik mit schräg gestelltem Symbol unten rechts.
class CategoryTile extends StatelessWidget {
  final Category category;
  final Color color;
  final VoidCallback onTap;

  const CategoryTile({super.key, required this.category, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Positioned(
              right: -14,
              bottom: -6,
              child: Transform.rotate(
                angle: 0.44,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: darken(color, 0.14),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 4))],
                  ),
                  child: Icon(searchCategoryIcon(category), color: Colors.white, size: 34),
                ),
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              right: 58,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WordSafeText(
                    category.name,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white, height: 1.15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    searchCategoryCount(category),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xDDFFFFFF)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kachelhöhe wächst mit großer Schrift (Name zweizeilig + Anzahl), sonst würde abgeschnitten.
SliverGridDelegate _categoryGridDelegate(BuildContext context) => SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisExtent: math.max(100.0, MediaQuery.textScalerOf(context).scale(1) * 53 + 32),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
    );

/// "Rubriken durchsuchen" – 2-spaltiges Raster (Sliver).
class CategoryGridSliver extends ConsumerWidget {
  const CategoryGridSliver({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    final list = categories.value;
    if (list == null && categories.hasError) {
      return SliverToBoxAdapter(
        child: ErrorView(message: errorText(categories.error!), onRetry: () => ref.invalidate(categoriesProvider)),
      );
    }
    if (list == null) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid.builder(
          gridDelegate: _categoryGridDelegate(context),
          itemCount: 6,
          itemBuilder: (_, _) => DecoratedBox(
            decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(6)),
          ),
        ),
      );
    }
    if (list.isEmpty) {
      return const SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.folder_off_rounded,
          title: 'Noch keine Rubriken',
          message: 'Ein Admin kann in den Einstellungen Rubriken anlegen.',
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid.builder(
        gridDelegate: _categoryGridDelegate(context),
        itemCount: list.length,
        itemBuilder: (context, index) => CategoryTile(
          category: list[index],
          color: categoryPalette[index % categoryPalette.length],
          onTap: () => Nav.category(context, list[index].id),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ YouTube-Link

const _youtubeRed = Color(0xFFFF0033);

/// Kachel "YouTube-Link einfügen" (nur für Konten mit Download-Recht).
class YouTubeLinkTile extends StatelessWidget {
  const YouTubeLinkTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showYouTubeLinkDialog(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: _youtubeRed, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.add_link_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('YouTube-Link einfügen',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                      SizedBox(height: 2),
                      Text('Song, Video oder ganze Playlist per Link holen',
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dialog: YouTube-Link einfügen, Musik oder Video wählen, Download starten.
Future<void> showYouTubeLinkDialog(BuildContext context) async {
  final count = await showDialog<int>(context: context, builder: (_) => const _YouTubeLinkDialog());
  if (count == null || !context.mounted) return;
  showMessage(
    context,
    switch (count) {
      0 => 'Unter diesem Link wurde nichts gefunden',
      1 => '1 Titel wird geholt',
      _ => '$count Titel werden geholt',
    },
  );
}

class _YouTubeLinkDialog extends ConsumerStatefulWidget {
  const _YouTubeLinkDialog();

  @override
  ConsumerState<_YouTubeLinkDialog> createState() => _YouTubeLinkDialogState();
}

class _YouTubeLinkDialogState extends ConsumerState<_YouTubeLinkDialog> {
  final _controller = TextEditingController();
  bool _video = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String _normalize(String input) {
    final url = input.trim();
    return url.contains('://') ? url : 'https://$url';
  }

  static bool _isYouTube(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host == 'youtu.be' || host == 'youtube.com' || host.endsWith('.youtube.com');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() => _error = 'In der Zwischenablage ist kein Link.');
      return;
    }
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() => _error = null);
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_controller.text.trim().isEmpty) {
      setState(() => _error = 'Bitte füge einen Link ein.');
      return;
    }
    final url = _normalize(_controller.text);
    if (!_isYouTube(url)) {
      setState(() => _error = 'Das ist kein Link von youtube.com oder music.youtube.com.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final jobs = await ref.read(downloadsProvider.notifier).startUrl(url, video: _video);
      if (mounted) Navigator.of(context).pop(jobs.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('YouTube-Link einfügen'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Füge den Link zu einem Song, einem Video oder einer ganzen Playlist ein.',
              style: AppText.tileSubtitle,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'https://music.youtube.com/…',
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: IconButton(
                  tooltip: 'Aus Zwischenablage einfügen',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: _busy ? null : _paste,
                ),
                errorText: _error,
                errorMaxLines: 4,
              ),
            ),
            const SizedBox(height: 18),
            const Text('Holen als', style: AppText.caption),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Musik'), icon: Icon(Icons.music_note_rounded)),
                ButtonSegment(value: true, label: Text('Video'), icon: Icon(Icons.movie_rounded)),
              ],
              selected: {_video},
              onSelectionChanged: _busy ? null : (selection) => setState(() => _video = selection.first),
              style: SegmentedButton.styleFrom(
                foregroundColor: Colors.white,
                selectedForegroundColor: Colors.black,
                selectedBackgroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.textMuted),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _video
                  ? 'Landet als Video in deiner Bibliothek (mit Bild).'
                  : 'Landet als Song in deiner Bibliothek (nur Ton).',
              style: AppText.caption,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.black),
                )
              : const Text('Holen'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Top-Ergebnis

/// Große Karte "Top-Ergebnis" (Künstler, Album, Song oder Video).
class TopResultCard extends ConsumerWidget {
  final TopResult result;
  /// Songs der Suche – Warteschlange, wenn ein Song das Top-Ergebnis ist.
  final List<Track> songs;
  /// Wird beim Öffnen aufgerufen (Suchbegriff merken).
  final VoidCallback onOpen;

  const TopResultCard({super.key, required this.result, required this.songs, required this.onOpen});

  static const _coverSize = 92.0;
  static const _searchContext = PlayContext('search');

  Future<void> _playTrack(BuildContext context, WidgetRef ref, Track track) async {
    final queue = songs.contains(track) ? songs : [track];
    await ref.read(playerProvider).play(queue, index: queue.indexOf(track), context: _searchContext);
  }

  void _openVideo(BuildContext context, WidgetRef ref, Track track) {
    ref.read(audioHandlerProvider).pause();
    Nav.video(context, track);
  }

  Future<void> _guard(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on StateError catch (e) {
      if (context.mounted) showMessage(context, e.message);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  /// Karte antippen: Künstler/Album öffnen, Song abspielen, Video ansehen.
  void _open(BuildContext context, WidgetRef ref) {
    onOpen();
    final artist = result.artist;
    final album = result.album;
    final track = result.track;
    if (result.type == 'artist' && artist != null) {
      Nav.artist(context, artist.id);
    } else if (result.type == 'album' && album != null) {
      Nav.album(context, album.id);
    } else if (track != null && track.isVideo) {
      _openVideo(context, ref, track);
    } else if (track != null) {
      _guard(context, () => _playTrack(context, ref, track));
    }
  }

  /// Grüner Knopf: alles direkt abspielen.
  void _play(BuildContext context, WidgetRef ref, {required bool isCurrent}) {
    onOpen();
    final player = ref.read(playerProvider);
    final artist = result.artist;
    final album = result.album;
    final track = result.track;
    _guard(context, () async {
      if (result.type == 'artist' && artist != null) {
        final detail = await ref.read(apiProvider)!.artist(artist.id);
        if (detail.topTracks.isEmpty) {
          if (context.mounted) showMessage(context, 'Von ${artist.name} gibt es noch keine Songs');
          return;
        }
        await player.play(detail.topTracks, context: PlayContext('artist', id: artist.id, title: artist.name));
      } else if (result.type == 'album' && album != null) {
        final detail = await ref.read(apiProvider)!.album(album.id);
        await player.play(detail.tracks, context: PlayContext('album', id: album.id, title: album.title));
      } else if (track != null && track.isVideo) {
        if (context.mounted) _openVideo(context, ref, track);
      } else if (track != null) {
        if (isCurrent) {
          await player.togglePlay();
        } else if (context.mounted) {
          await _playTrack(context, ref, track);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = result.artist;
    final album = result.album;
    final track = result.track;

    late final String title;
    late final String label;
    String? detail;
    String? colorHex;
    late final Widget cover;

    if (result.type == 'artist' && artist != null) {
      title = artist.name;
      label = 'Künstler';
      colorHex = artist.coverColor;
      cover = CoverImage(
        coverId: artist.coverId,
        size: _coverSize,
        circle: true,
        placeholderIcon: Icons.person_rounded,
      );
    } else if (result.type == 'album' && album != null) {
      title = album.title;
      label = 'Album';
      detail = album.artist.name;
      colorHex = album.coverColor;
      cover = CoverImage(coverId: album.coverId, size: _coverSize, radius: 4, placeholderIcon: Icons.album_rounded);
    } else if (track != null) {
      title = track.title;
      label = track.isVideo ? 'Video' : 'Song';
      detail = track.artistDisplay.isEmpty ? null : track.artistDisplay;
      colorHex = track.coverColor;
      cover = Stack(
        children: [
          CoverImage(
            coverId: track.coverId,
            size: _coverSize,
            radius: 4,
            placeholderIcon: track.isVideo ? Icons.movie_rounded : Icons.music_note_rounded,
          ),
          if (track.isVideo)
            const Positioned(
              right: 6,
              bottom: 6,
              child: Icon(Icons.play_circle_fill_rounded, size: 26, color: Colors.white),
            ),
        ],
      );
    } else {
      return const SizedBox.shrink();
    }

    final isCurrent = track != null && !track.isVideo && ref.watch(isCurrentTrackProvider(track.id));
    final playing = isCurrent && ref.watch(isPlayingProvider);
    final tint = parseHexColor(colorHex) ?? AppColors.surfaceHighest;

    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(AppColors.surfaceHigh, darken(tint, 0.05), 0.55)!, AppColors.surfaceHigh],
          ),
        ),
        child: InkWell(
          onTap: () => _open(context, ref),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: result.type == 'artist' ? BoxShape.circle : BoxShape.rectangle,
                    boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 16, offset: Offset(0, 6))],
                  ),
                  child: cover,
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    color: isCurrent ? AppColors.accent : Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0x66000000),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(label,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                          ),
                          if (detail != null) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.tileSubtitle.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    PlayButton(size: 48, playing: playing, onPressed: () => _play(context, ref, isCurrent: isCurrent)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Hinweise & Offline-Suche

/// Kleiner Hinweiskasten (z. B. "Nur heruntergeladene Musik wird durchsucht").
class SearchNote extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const SearchNote({super.key, required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: AppColors.textSecondary),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: AppText.tileSubtitle)),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: action!),
          ],
        ],
      ),
    );
  }
}

const _foldMap = {
  'ä': 'ae',
  'ö': 'oe',
  'ü': 'ue',
  'ß': 'ss',
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
};

/// Kleinbuchstaben ohne Umlaute/Akzente – so findet "aerzte" auch "Ärzte".
String foldForSearch(String text) {
  final lower = text.toLowerCase();
  final buffer = StringBuffer();
  for (final char in lower.split('')) {
    buffer.write(_foldMap[char] ?? char);
  }
  return buffer.toString();
}

/// Durchsucht heruntergeladene Titel (Titel, Künstler, Album; alle Wörter müssen vorkommen).
List<Track> searchOfflineTracks(Iterable<Track> tracks, String query) {
  final words = foldForSearch(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final needle = foldForSearch(query.trim());
  final matches = <(Track, String)>[];
  for (final track in tracks) {
    final haystack = foldForSearch('${track.title} ${track.artistDisplay} ${track.album?.title ?? ''}');
    if (words.every(haystack.contains)) matches.add((track, foldForSearch(track.title)));
  }
  int rank((Track, String) entry) {
    final title = entry.$2;
    if (title == needle) return 0;
    if (title.startsWith(needle)) return 1;
    if (title.contains(needle)) return 2;
    return 3;
  }

  matches.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
  });
  return matches.map((m) => m.$1).toList();
}
