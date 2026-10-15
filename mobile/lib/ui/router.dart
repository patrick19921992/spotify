import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../state/auth.dart';
import 'screens/admin_screen.dart';
import 'screens/album_screen.dart';
import 'screens/artist_screen.dart';
import 'screens/category_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/liked_screen.dart';
import 'screens/login_screen.dart';
import 'screens/mix_screen.dart';
import 'screens/offline_screen.dart';
import 'screens/player_screen.dart';
import 'screens/playlist_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/video_screen.dart';
import 'screens/youtube_album_screen.dart';
import 'shell.dart';

/// Detailseiten, die es in jedem Tab gibt (so bleibt die untere Leiste sichtbar).
List<RouteBase> _detailRoutes() => [
      GoRoute(path: 'album/:id', builder: (_, s) => AlbumScreen(albumId: int.parse(s.pathParameters['id']!))),
      GoRoute(path: 'artist/:id', builder: (_, s) => ArtistScreen(artistId: int.parse(s.pathParameters['id']!))),
      GoRoute(path: 'playlist/:id', builder: (_, s) => PlaylistScreen(playlistId: int.parse(s.pathParameters['id']!))),
      GoRoute(path: 'liked', builder: (_, _) => const LikedSongsScreen()),
      GoRoute(path: 'mix/:key', builder: (_, s) => MixScreen(mixKey: s.pathParameters['key']!)),
      GoRoute(path: 'category/:id', builder: (_, s) => CategoryScreen(categoryId: int.parse(s.pathParameters['id']!))),
      GoRoute(path: 'youtube-album/:id', builder: (_, s) => YouTubeAlbumScreen(browseId: s.pathParameters['id']!)),
    ];

/// Von unten hereinfahrende Vollbild-Seite (Player, Warteschlange).
Page<void> _slideUp(GoRouterState state, Widget child) => CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 280),
      transitionsBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );

/// Löst eine Neuberechnung der Weiterleitungen aus, wenn sich die Anmeldung ändert.
class _AuthListenable extends ChangeNotifier {
  void changed() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable();
  ref.listen(authProvider, (_, _) => listenable.changed());
  ref.onDispose(listenable.dispose);

  return GoRouter(
    initialLocation: '/start',
    refreshListenable: listenable,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final location = state.matchedLocation;
      // Solange die gespeicherte Anmeldung geladen wird: Startbildschirm
      if (auth.isLoading && !auth.hasValue) return location == '/start' ? null : '/start';
      final loggedIn = auth.value?.isLoggedIn ?? false;
      if (!loggedIn) return location == '/login' ? null : '/login';
      if (location == '/login' || location == '/start') return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/start', builder: (_, _) => const _SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/home', builder: (_, _) => const HomeScreen(), routes: _detailRoutes()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/search', builder: (_, _) => const SearchScreen(), routes: _detailRoutes()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/library', builder: (_, _) => const LibraryScreen(), routes: _detailRoutes()),
          ]),
        ],
      ),
      GoRoute(path: '/player', pageBuilder: (_, s) => _slideUp(s, const PlayerScreen())),
      GoRoute(path: '/queue', pageBuilder: (_, s) => _slideUp(s, const QueueScreen())),
      GoRoute(
        path: '/video/:id',
        builder: (_, s) => VideoScreen(trackId: int.parse(s.pathParameters['id']!), track: s.extra as Track?),
      ),
      GoRoute(
        path: '/downloads',
        builder: (_, s) => DownloadsScreen(showAll: s.uri.queryParameters['scope'] == 'all'),
      ),
      GoRoute(path: '/offline', builder: (_, _) => const OfflineScreen()),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const SettingsScreen(),
        routes: [GoRoute(path: 'devices', builder: (_, _) => const DevicesScreen())],
      ),
      GoRoute(path: '/admin', builder: (_, _) => const AdminScreen()),
    ],
  );
});

/// Kurzer Startbildschirm, bis die gespeicherte Anmeldung geladen ist.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: AppColors.accent,
              child: Icon(Icons.music_note_rounded, size: 44, color: Colors.black),
            ),
            SizedBox(height: 24),
            SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          ],
        ),
      ),
    );
  }
}
