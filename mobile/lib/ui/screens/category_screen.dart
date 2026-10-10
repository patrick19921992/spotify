import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/offline.dart';
import '../../state/settings.dart';
import '../nav.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';
import 'home_widgets.dart';

/// Neueste Alben einer Rubrik.
final _categoryAlbumsProvider = FutureProvider.autoDispose.family<List<Album>, int>(
  (ref, id) async => (await requireApi(ref).albums(categoryId: id, sort: 'recent', limit: 30)).items,
);

/// Künstler einer Rubrik (mit den meisten Titeln zuerst).
final _categoryArtistsProvider = FutureProvider.autoDispose.family<List<Artist>, int>(
  (ref, id) async => (await requireApi(ref).artists(categoryId: id, sort: 'tracks', limit: 30)).items,
);

final _countFormat = NumberFormat.decimalPattern('de_DE');

String _countLabel(int count, {required bool video}) {
  final number = _countFormat.format(count);
  if (video) return count == 1 ? '1 Video' : '$number Videos';
  return '$number Titel';
}

/// Eine Rubrik (z. B. "Musik", "Hörspiele", "Musikvideos"): Alben, Künstler und alle Titel bzw. Videos.
class CategoryScreen extends ConsumerStatefulWidget {
  final int categoryId;
  const CategoryScreen({super.key, required this.categoryId});

  @override
  ConsumerState<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends ConsumerState<CategoryScreen> {
  static const _pageSize = 50;

  List<Track> _tracks = const [];
  int _offset = 0;
  int _total = 0;
  bool _firstPageLoaded = false;
  bool _loading = false;
  bool _scheduled = false;
  Object? _error;

  /// Wird gesetzt, sobald die Rubrik bekannt ist (Audio oder Video).
  bool? _isVideo;
  String _sort = 'title';

  /// Verwirft Antworten, die nach einem Neuladen/Sortierwechsel eintreffen.
  int _generation = 0;

  int get _id => widget.categoryId;
  bool get _hasMore => !_firstPageLoaded || _offset < _total;

  void _ensureStarted(Category category) {
    if (_isVideo != null) return;
    _isVideo = category.isVideo;
    _sort = category.isVideo ? 'recent' : 'title';
    _scheduleLoadMore();
  }

  /// Nächste Seite nach dem aktuellen Frame laden (darf aus build() aufgerufen werden).
  void _scheduleLoadMore() {
    if (_loading || _scheduled || !_hasMore || _error != null || _isVideo == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _loadMore();
    });
  }

  Future<void> _loadMore() async {
    final isVideo = _isVideo;
    if (_loading || !_hasMore || isVideo == null) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await api.tracks(
        categoryId: _id,
        mediaType: isVideo ? 'video' : null,
        sort: _sort,
        limit: _pageSize,
        offset: _offset,
      );
      if (!mounted || generation != _generation) return;
      final known = {for (final track in _tracks) track.id};
      setState(() {
        _tracks = [..._tracks, ...page.items.where((track) => known.add(track.id))];
        _offset += page.items.length;
        // Leere Seite: nichts mehr da (auch wenn sich die Gesamtzahl inzwischen geändert hat)
        _total = page.items.isEmpty ? _offset : page.total;
        _firstPageLoaded = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _reload() async {
    _generation++;
    setState(() {
      _tracks = const [];
      _offset = 0;
      _total = 0;
      _firstPageLoaded = false;
      _loading = false;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _refresh() async {
    ref.invalidate(categoriesProvider);
    ref.invalidate(_categoryAlbumsProvider(_id));
    ref.invalidate(_categoryArtistsProvider(_id));
    await _reload();
    try {
      await ref.read(categoriesProvider.future);
    } catch (_) {
      // Fehler wird in der Seite angezeigt
    }
  }

  void _setSort(String sort) {
    if (sort == _sort) return;
    _sort = sort;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    final offlineMode = ref.watch(settingsProvider.select((s) => s.offlineMode));
    final noNetwork = ref.watch(isOfflineProvider);
    // Wieder online: fehlgeschlagenes Laden automatisch wiederholen
    ref.listen<bool>(isOfflineProvider, (previous, next) {
      if (previous == true && !next && _error != null) _reload();
    });

    final category = categories.value?.where((c) => c.id == _id).firstOrNull;
    final color = categoryColor(_id);

    if (offlineMode || noNetwork) {
      return HomeGradientScaffold(
        title: category?.name ?? 'Rubrik',
        color: color,
        alwaysShowTitle: true,
        collapseOffset: 60,
        bodyBuilder: (context, topInset) => _OfflineCategory(
          category: category,
          categoryId: _id,
          color: color,
          topInset: topInset,
          noNetwork: noNetwork,
        ),
      );
    }

    if (category == null) {
      final Widget body;
      if (!categories.hasValue && categories.hasError) {
        body = ErrorView(message: errorText(categories.error!), onRetry: () => ref.invalidate(categoriesProvider));
      } else if (!categories.hasValue) {
        body = const Center(child: CircularProgressIndicator());
      } else {
        body = ErrorView(
          message: 'Diese Rubrik gibt es nicht (mehr).',
          onRetry: () => ref.invalidate(categoriesProvider),
        );
      }
      return Scaffold(appBar: AppBar(title: const Text('Rubrik')), body: body);
    }

    _ensureStarted(category);
    final isVideo = category.isVideo;
    final albums = isVideo ? null : ref.watch(_categoryAlbumsProvider(_id));
    final artists = isVideo ? null : ref.watch(_categoryArtistsProvider(_id));

    return HomeGradientScaffold(
      title: category.name,
      color: color,
      alwaysShowTitle: true,
      collapseOffset: 60,
      bodyBuilder: (context, topInset) => RefreshIndicator(
        color: AppColors.accent,
        edgeOffset: topInset,
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _CategoryHeader(
                icon: categoryIcon(category.icon),
                color: color,
                topInset: topInset,
                title: _countLabel(category.itemCount, video: isVideo),
                subtitle: isVideo ? 'Video-Rubrik' : 'Audio-Rubrik',
                actions: isVideo
                    ? null
                    : Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => Nav.mix(context, 'category:${category.id}'),
                            icon: const Icon(Icons.shuffle_rounded, size: 20),
                            label: const Text('Zufallsmix'),
                          ),
                          const Spacer(),
                          _CategoryPlayButton(categoryId: category.id, name: category.name, tracks: _tracks),
                        ],
                      ),
              ),
            ),
            if (albums != null)
              SliverToBoxAdapter(
                child: _CardSection<Album>(
                  title: 'Alben',
                  value: albums,
                  card: (album) => MediaCard.album(context, album),
                  onRetry: () => ref.invalidate(_categoryAlbumsProvider(_id)),
                ),
              ),
            if (artists != null)
              SliverToBoxAdapter(
                child: _CardSection<Artist>(
                  title: 'Künstler',
                  value: artists,
                  card: (artist) => MediaCard.artist(context, artist),
                  onRetry: () => ref.invalidate(_categoryArtistsProvider(_id)),
                ),
              ),
            SliverToBoxAdapter(child: _listHeader(isVideo)),
            ..._listSlivers(category),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _listHeader(bool isVideo) {
    final options = isVideo
        ? const [('recent', 'Neu hinzugefügt'), ('title', 'A–Z')]
        : const [('title', 'A–Z'), ('recent', 'Neu hinzugefügt')];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(isVideo ? 'Alle Videos' : 'Alle Titel', style: AppText.sectionTitle),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (value, label) in options)
                ChoiceChip(
                  label: Text(label),
                  selected: _sort == value,
                  onSelected: (_) => _setSort(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _listSlivers(Category category) {
    final isVideo = category.isVideo;
    if (!_firstPageLoaded) {
      if (_error != null) {
        return [SliverToBoxAdapter(child: InlineError(message: errorText(_error!), onRetry: _loadMore))];
      }
      return const [
        SliverToBoxAdapter(child: SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))),
      ];
    }
    if (_tracks.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: EmptyState(
              icon: isVideo ? Icons.movie_rounded : Icons.music_off_rounded,
              title: isVideo ? 'Noch keine Videos' : 'Noch keine Titel',
              message: 'Sobald etwas in dieser Rubrik liegt, erscheint es hier.',
            ),
          ),
        ),
      ];
    }
    final showFooter = _hasMore || _error != null;

    if (isVideo) {
      final rows = (_tracks.length + 1) ~/ 2;
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: rows + (showFooter ? 1 : 0),
            itemBuilder: (context, row) {
              if (row == rows) return _footer();
              if (row >= rows - 6) _scheduleLoadMore();
              final first = _tracks[row * 2];
              final second = row * 2 + 1 < _tracks.length ? _tracks[row * 2 + 1] : null;
              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: VideoCard(track: first, titleLines: 2)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: second == null ? const SizedBox.shrink() : VideoCard(track: second, titleLines: 2),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ];
    }

    final playContext = PlayContext('category', id: category.id, title: category.name);
    return [
      SliverList.builder(
        itemCount: _tracks.length + (showFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _tracks.length) return _footer();
          if (index >= _tracks.length - 15) _scheduleLoadMore();
          return TrackTile(track: _tracks[index], queue: _tracks, context_: playContext);
        },
      ),
    ];
  }

  /// Ende der Liste: lädt weiter bzw. zeigt einen Fehler mit "Erneut versuchen".
  Widget _footer() {
    if (_error != null) return InlineError(message: errorText(_error!), onRetry: _loadMore);
    _scheduleLoadMore();
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
      ),
    );
  }
}

// ------------------------------------------------------------------ Bausteine

/// Kopfbereich mit großem Rubrik-Symbol, Anzahl und optionalen Aktionen.
class _CategoryHeader extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double topInset;
  final String title;
  final String subtitle;
  final Widget? actions;

  const _CategoryHeader({
    required this.icon,
    required this.color,
    required this.topInset,
    required this.title,
    required this.subtitle,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return HeaderGradient(
      color: color,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset + 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [color, darken(color, 0.15)],
                    ),
                    boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 18, offset: Offset(0, 6))],
                  ),
                  child: Icon(icon, size: 44, color: Colors.white),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
                    ],
                  ),
                ),
              ],
            ),
            if (actions != null) ...[const SizedBox(height: 16), actions!],
          ],
        ),
      ),
    );
  }
}

/// Grüner Abspielknopf für die geladenen Titel einer Rubrik (Pause, wenn sie gerade läuft).
class _CategoryPlayButton extends ConsumerWidget {
  final int categoryId;
  final String? name;
  final List<Track> tracks;

  const _CategoryPlayButton({required this.categoryId, required this.name, required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playContext = PlayContext('category', id: categoryId, title: name);
    final active = watchIsPlayingContext(ref, (c) => c.type == 'category' && c.id == categoryId, tracks);
    final playing = active && ref.watch(isPlayingProvider);
    return PlayButton(
      size: 52,
      playing: playing,
      onPressed: tracks.isEmpty
          ? null
          : () => active
              ? ref.read(playerProvider).togglePlay()
              : playWithFeedback(context, ref, tracks, playContext: playContext),
    );
  }
}

/// Abschnitt mit horizontaler Kartenreihe (Alben, Künstler) inkl. Laden/Fehler.
class _CardSection<T> extends StatelessWidget {
  final String title;
  final AsyncValue<List<T>> value;
  final Widget Function(T item) card;
  final VoidCallback onRetry;

  const _CardSection({required this.title, required this.value, required this.card, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: (items) => items.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [SectionHeader(title), CardRow(children: [for (final item in items) card(item)])],
            ),
      loading: () => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title),
          const SizedBox(height: 210, child: Center(child: CircularProgressIndicator())),
        ],
      ),
      error: (error, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [SectionHeader(title), InlineError(message: errorText(error), onRetry: onRetry)],
      ),
    );
  }
}

/// Ohne Netz bzw. im Offline-Modus: nur die heruntergeladenen Titel dieser Rubrik.
class _OfflineCategory extends ConsumerWidget {
  final Category? category;
  final int categoryId;
  final Color color;
  final double topInset;
  final bool noNetwork;

  const _OfflineCategory({
    required this.category,
    required this.categoryId,
    required this.color,
    required this.topInset,
    required this.noNetwork,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    final tracks = [
      for (final item in offline.tracks.values)
        if (item.track.categoryId == categoryId) item.track,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final isVideo = category?.isVideo ?? false;
    final playContext = PlayContext('category', id: categoryId, title: category?.name);

    final Widget content;
    if (isVideo) {
      content = SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.movie_rounded,
          title: noNetwork ? 'Videos gibt es nur online' : 'Im Offline-Modus keine Videos',
          message: noNetwork
              ? 'Videos werden direkt vom Server abgespielt. Sobald du wieder online bist, findest du sie hier.'
              : 'Videos werden direkt vom Server abgespielt. Schalte den Offline-Modus in den Einstellungen aus, um sie anzusehen.',
        ),
      );
    } else if (!offline.loaded) {
      content = const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
    } else if (tracks.isEmpty) {
      content = const SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.download_for_offline_outlined,
          title: 'Nichts heruntergeladen',
          message: 'Aus dieser Rubrik ist noch nichts auf deinem Handy.',
        ),
      );
    } else {
      content = SliverList.builder(
        itemCount: tracks.length,
        itemBuilder: (context, index) => TrackTile(track: tracks[index], queue: tracks, context_: playContext),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _CategoryHeader(
            icon: categoryIcon(category?.icon ?? 'folder'),
            color: color,
            topInset: topInset,
            title: isVideo ? 'Nicht offline verfügbar' : '${_countFormat.format(tracks.length)} heruntergeladen',
            subtitle: noNetwork ? 'Keine Verbindung – nur Titel auf deinem Handy' : 'Offline-Modus – nur Titel auf deinem Handy',
            actions: isVideo || tracks.isEmpty
                ? null
                : Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => playWithFeedback(context, ref, tracks, playContext: playContext, shuffle: true),
                        icon: const Icon(Icons.shuffle_rounded, size: 20),
                        label: const Text('Zufällig'),
                      ),
                      const Spacer(),
                      _CategoryPlayButton(categoryId: categoryId, name: category?.name, tracks: tracks),
                    ],
                  ),
          ),
        ),
        if (!isVideo && tracks.isNotEmpty) const SliverToBoxAdapter(child: SectionHeader('Heruntergeladen')),
        content,
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}
