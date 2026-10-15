import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../shell.dart';
import '../desktop/search_focus.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';
import 'search_widgets.dart';
import 'search_youtube.dart';

/// Offline-Modus an oder kein Netz → nur heruntergeladene Musik durchsuchen.
final _searchOfflineProvider = Provider<bool>(
  (ref) => ref.watch(settingsProvider.select((s) => s.offlineMode)) || ref.watch(isOfflineProvider),
);

const _searchContext = PlayContext('search');
const _debounceDelay = Duration(milliseconds: 350);
const _listHeaderPadding = EdgeInsets.fromLTRB(16, 24, 8, 4);
const _cardWidth = 132.0;
const _cardRowHeight = 200.0;

/// Suche wie bei Spotify – plus "Nicht dabei? Von YouTube holen".
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _debounce;

  /// Aktueller (getrimmter) Suchbegriff im Feld.
  String _query = '';

  /// Letztes Ergebnis der Bibliothekssuche – bleibt sichtbar, während schon neu gesucht wird.
  SearchResult? _result;
  String? _resultQuery;

  /// Laufende Anfrage und Fehler (jeweils mit dem Suchbegriff, zu dem sie gehören).
  String? _pendingQuery;
  Object? _error;
  String? _errorQuery;

  String _youtubeType = 'songs';

  @override
  void initState() {
    super.initState();
    searchFocusRequests.addListener(_focusField); // Strg+F am Computer
  }

  void _focusField() {
    if (mounted) _focus.requestFocus();
  }

  @override
  void dispose() {
    searchFocusRequests.removeListener(_focusField);
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _offline => ref.read(_searchOfflineProvider);

  // ---------------------------------------------------------------- Suchen

  void _onChanged(String text) {
    final q = text.trim();
    if (q == _query) return;
    _debounce?.cancel();
    setState(() {
      _query = q;
      if (q.isEmpty) {
        _result = null;
        _resultQuery = null;
        _pendingQuery = null;
        _error = null;
        _errorQuery = null;
      }
    });
    if (q.isNotEmpty) _debounce = Timer(_debounceDelay, () => _search(q));
  }

  /// Bibliothek durchsuchen. Antworten zu veralteten Suchbegriffen werden verworfen.
  Future<void> _search(String q) async {
    _debounce?.cancel();
    if (q.isEmpty || _offline) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _pendingQuery = q;
      _error = null;
      _errorQuery = null;
    });
    try {
      final result = await api.search(q, limit: 10);
      if (!mounted || q != _query) return;
      final newQuery = _resultQuery != q;
      setState(() {
        _result = result;
        _resultQuery = q;
        if (_pendingQuery == q) _pendingQuery = null;
      });
      if (newQuery && _scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || q != _query) return;
      setState(() {
        _error = e;
        _errorQuery = q;
        if (_pendingQuery == q) _pendingQuery = null;
      });
    }
  }

  void _submit(String text) {
    final q = text.trim();
    if (q.isEmpty) return;
    _remember(q);
    if (q != _query) _onChanged(q);
    if (_offline || _pendingQuery == q) return;
    if (_resultQuery != q || _debounce?.isActive == true) _search(q);
  }

  void _clear() {
    _controller.clear();
    _onChanged('');
    _focus.requestFocus();
  }

  /// Zuletzt gesuchten Begriff erneut suchen.
  void _useRecent(String q) {
    _controller.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    _focus.unfocus();
    _onChanged(q);
    _remember(q);
    _search(q);
  }

  /// Suchbegriff unter "Zuletzt gesucht" merken (beim Öffnen eines Treffers oder Absenden).
  void _remember([String? q]) {
    final query = q ?? (_offline ? _query : (_resultQuery ?? _query));
    ref.read(recentSearchesProvider.notifier).add(query);
  }

  Future<void> _refresh() async {
    if (_offline) return;
    if (_query.isEmpty) {
      ref.invalidate(categoriesProvider);
      try {
        await ref.read(categoriesProvider.future).timeout(const Duration(seconds: 20));
      } catch (_) {
        // Fehler zeigt das Raster selbst an
      }
      return;
    }
    final shown = _resultQuery;
    if (shown != null && shown.length >= 2) {
      ref.invalidate(youtubeSearchProvider((query: shown, type: _youtubeType)));
    }
    await _search(_query);
  }

  // ---------------------------------------------------------------- Öffnen & Abspielen

  Future<void> _playTracks(List<Track> tracks, int index, {String? remember}) async {
    _remember(remember);
    try {
      await ref.read(playerProvider).play(tracks, index: index < 0 ? 0 : index, context: _searchContext);
    } on StateError catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _openVideo(Track track) {
    _remember();
    ref.read(audioHandlerProvider).pause();
    Nav.video(context, track);
  }

  /// Karte aus [MediaCard.artist]/[MediaCard.album], die beim Antippen zusätzlich den Suchbegriff merkt.
  MediaCard _remembering(MediaCard card) => MediaCard(
        title: card.title,
        subtitle: card.subtitle,
        cover: card.cover,
        width: card.width,
        centered: card.centered,
        onTap: () {
          _remember();
          card.onTap();
        },
      );

  // ---------------------------------------------------------------- Aufbau

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(_searchOfflineProvider);
    // Wieder online: Suche für den aktuellen Begriff nachholen
    ref.listen<bool>(_searchOfflineProvider, (previous, next) {
      if (previous == true && !next && _query.isNotEmpty && _resultQuery != _query) _search(_query);
    });

    final List<Widget> content;
    if (_query.isEmpty) {
      content = _browseSlivers(offline);
    } else if (offline) {
      content = _offlineSlivers();
    } else {
      content = _onlineSlivers();
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AppColors.accent,
          onRefresh: _refresh,
          notificationPredicate: (notification) => !offline && notification.depth == 0,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              const SliverToBoxAdapter(child: _TitleRow()),
              SliverPersistentHeader(
                pinned: true,
                delegate: SearchFieldHeader(
                  controller: _controller,
                  focusNode: _focus,
                  onChanged: _onChanged,
                  onSubmitted: _submit,
                  onClear: _clear,
                ),
              ),
              ...content,
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ),
      ),
    );
  }

  /// Leeres Suchfeld: zuletzt gesucht, YouTube-Link, Rubriken.
  List<Widget> _browseSlivers(bool offline) {
    final recent = ref.watch(recentSearchesProvider);
    final canDownload = ref.watch(currentUserProvider)?.canDownload ?? false;
    return [
      if (recent.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 4, 4),
            child: Row(
              children: [
                const Expanded(child: Text('Zuletzt gesucht', style: AppText.sectionTitle)),
                TextButton(
                  onPressed: () => ref.read(recentSearchesProvider.notifier).clear(),
                  child: const Text(
                    'Löschen',
                    style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: recent.length,
          itemBuilder: (context, index) {
            final q = recent[index];
            return RecentSearchTile(
              query: q,
              onTap: () => _useRecent(q),
              onRemove: () => ref.read(recentSearchesProvider.notifier).remove(q),
            );
          },
        ),
      ],
      if (offline)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: recent.isEmpty ? 4 : 16),
            child: SearchNote(
              icon: Icons.cloud_off_rounded,
              text: 'Du bist offline. Die Suche findet nur Musik, die auf deinem Handy gespeichert ist.',
              action: TextButton(
                onPressed: () => Nav.offline(context),
                child: const Text('Heruntergeladene Musik', style: TextStyle(color: AppColors.accent)),
              ),
            ),
          ),
        )
      else ...[
        if (canDownload)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: recent.isEmpty ? 0 : 12),
              child: const YouTubeLinkTile(),
            ),
          ),
        const SliverToBoxAdapter(child: SectionHeader('Rubriken durchsuchen')),
        const CategoryGridSliver(),
      ],
    ];
  }

  /// Offline: heruntergeladene Titel durchsuchen.
  List<Widget> _offlineSlivers() {
    final offline = ref.watch(offlineProvider);
    final matches = searchOfflineTracks(offline.tracks.values.map((t) => t.track), _query);
    return [
      const SliverToBoxAdapter(
        child: SearchNote(
          icon: Icons.cloud_off_rounded,
          text: 'Offline wird nur Musik durchsucht, die auf deinem Handy gespeichert ist.',
        ),
      ),
      if (!offline.loaded)
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
        )
      else if (matches.isEmpty)
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Nichts gefunden',
            message: 'Zu „$_query“ ist keine Musik auf deinem Handy gespeichert.',
          ),
        )
      else ...[
        SliverToBoxAdapter(
          child: SectionHeader('${pluralSongs(matches.length)} auf deinem Handy', padding: _listHeaderPadding),
        ),
        SliverList.builder(
          itemCount: matches.length,
          itemBuilder: (context, index) => TrackTile(
            track: matches[index],
            queue: matches,
            context_: _searchContext,
            onTap: () => _playTracks(matches, index, remember: _query),
          ),
        ),
      ],
    ];
  }

  /// Online: Treffer aus der Bibliothek, danach YouTube Music.
  List<Widget> _onlineSlivers() {
    if (_error != null && _errorQuery == _query) {
      return [
        SliverToBoxAdapter(child: ErrorView(message: errorText(_error!), onRetry: () => _search(_query))),
      ];
    }
    final result = _result;
    final shownQuery = _resultQuery;
    if (result == null || shownQuery == null) {
      return const [
        SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
        ),
      ];
    }
    final searching = _pendingQuery != null || shownQuery != _query;
    return [
      SliverToBoxAdapter(
        child: SizedBox(
          height: 2,
          child: searching
              ? const LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent)
              : null,
        ),
      ),
      ..._resultSlivers(result, shownQuery),
      if (shownQuery.length >= 2)
        YouTubeSearchSection(
          query: shownQuery,
          type: _youtubeType,
          onTypeChanged: (type) => setState(() => _youtubeType = type),
          onOpen: _remember,
        ),
    ];
  }

  List<Widget> _resultSlivers(SearchResult result, String query) {
    final top = result.topResult;
    if (result.isEmpty && top == null) {
      return [SliverToBoxAdapter(child: _NoLibraryHits(query: query, youtubeFollows: query.length >= 2))];
    }
    final songs = result.tracks.take(5).toList();
    return [
      if (top != null) ...[
        const SliverToBoxAdapter(
          child: SectionHeader('Top-Ergebnis', padding: EdgeInsets.fromLTRB(16, 14, 8, 12)),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TopResultCard(result: top, songs: result.tracks, onOpen: _remember),
          ),
        ),
      ],
      if (songs.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Songs', padding: _listHeaderPadding)),
        SliverList.builder(
          itemCount: songs.length,
          itemBuilder: (context, index) => TrackTile(
            track: songs[index],
            queue: result.tracks,
            context_: _searchContext,
            onTap: () => _playTracks(result.tracks, result.tracks.indexOf(songs[index])),
          ),
        ),
      ],
      if (result.artists.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Künstler')),
        SliverToBoxAdapter(
          child: CardRow(
            height: _cardRowHeight,
            children: [
              for (final artist in result.artists)
                _remembering(MediaCard.artist(context, artist, width: _cardWidth)),
            ],
          ),
        ),
      ],
      if (result.albums.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Alben')),
        SliverToBoxAdapter(
          child: CardRow(
            height: _cardRowHeight,
            children: [
              for (final album in result.albums) _remembering(MediaCard.album(context, album, width: _cardWidth)),
            ],
          ),
        ),
      ],
      if (result.videos.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Videos', padding: _listHeaderPadding)),
        SliverList.builder(
          itemCount: result.videos.length,
          itemBuilder: (context, index) {
            final video = result.videos[index];
            return TrackTile(
              track: video,
              queue: result.videos,
              context_: _searchContext,
              onTap: () => _openVideo(video),
            );
          },
        ),
      ],
    ];
  }
}

/// "Suche" mit Downloads-Knopf.
class _TitleRow extends StatelessWidget {
  const _TitleRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 4, 6),
      child: Row(
        children: [
          Expanded(child: Text('Suche', style: AppText.pageTitle)),
          DownloadsAction(),
        ],
      ),
    );
  }
}

/// Nichts in der Bibliothek gefunden.
class _NoLibraryHits extends StatelessWidget {
  final String query;
  final bool youtubeFollows;

  const _NoLibraryHits({required this.query, required this.youtubeFollows});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 4),
      child: Column(
        children: [
          Text(
            'Keine Treffer für „$query“',
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            youtubeFollows
                ? 'In deiner Bibliothek ist dazu noch nichts. Schau unten bei YouTube Music.'
                : 'Prüf die Schreibweise oder versuch es mit einem anderen Suchbegriff.',
            textAlign: TextAlign.center,
            style: AppText.tileSubtitle,
          ),
        ],
      ),
    );
  }
}
