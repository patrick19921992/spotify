import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/settings.dart';
import '../nav.dart';
import '../shell.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';

/// Linke Spalte: Start, Suchen, Bibliothek und darunter die eigenen Playlists.
/// Schmal ([expanded] = false) nur mit Symbolen und Covern.
class DesktopSidebar extends ConsumerWidget {
  final StatefulNavigationShell shell;
  final bool expanded;

  const DesktopSidebar({super.key, required this.shell, required this.expanded});

  void _onTab(int index) => shell.goBranch(index, initialLocation: index == shell.currentIndex);

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final name = await promptText(context, title: 'Neue Playlist', hint: 'Name der Playlist', confirmLabel: 'Erstellen');
    if (name == null || name.isEmpty || !context.mounted) return;
    try {
      final created = await ref.read(apiProvider)!.createPlaylist(name: name);
      ref.invalidate(libraryOverviewProvider);
      ref.invalidate(myPlaylistsProvider);
      if (context.mounted) Nav.playlist(context, created.playlist.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(isOfflineProvider) || ref.watch(settingsProvider.select((s) => s.offlineMode));
    final router = GoRouter.of(context);
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: router.routerDelegate,
        builder: (context, _) {
          final path = _currentPath(router);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              _NavItem(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home_rounded,
                label: 'Start',
                expanded: expanded,
                selected: shell.currentIndex == 0,
                onTap: () => _onTab(0),
              ),
              _NavItem(
                icon: Icons.search_rounded,
                selectedIcon: Icons.manage_search_rounded,
                label: 'Suchen',
                expanded: expanded,
                selected: shell.currentIndex == 1,
                onTap: () => _onTab(1),
              ),
              _NavItem(
                icon: Icons.library_music_outlined,
                selectedIcon: Icons.library_music_rounded,
                label: 'Bibliothek',
                expanded: expanded,
                selected: shell.currentIndex == 2,
                onTap: () => _onTab(2),
              ),
              const Divider(height: 16),
              if (expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Playlists', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                      const DownloadsAction(),
                      IconButton(
                        tooltip: 'Playlist erstellen',
                        icon: const Icon(Icons.add_rounded),
                        onPressed: offline ? null : () => _createPlaylist(context, ref),
                      ),
                    ],
                  ),
                ),
              Expanded(child: _PlaylistList(expanded: expanded, offline: offline, currentPath: path)),
              const Divider(height: 1),
              _NavItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: 'Einstellungen',
                expanded: expanded,
                selected: false,
                onTap: () => Nav.settings(context),
              ),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }

  static String _currentPath(GoRouter router) {
    try {
      return router.state.uri.path;
    } catch (_) {
      return '';
    }
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : AppColors.textSecondary;
    final iconWidget = Icon(selected ? selectedIcon : icon, color: color, size: 26);
    if (!expanded) {
      return Tooltip(
        message: label,
        child: InkWell(onTap: onTap, child: SizedBox(height: 48, child: Center(child: iconWidget))),
      );
    }
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              iconWidget,
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lieblingssongs + eigene/gefolgte Playlists (aus „Deine Bibliothek“).
class _PlaylistList extends ConsumerWidget {
  final bool expanded;
  final bool offline;
  final String currentPath;

  const _PlaylistList({required this.expanded, required this.offline, required this.currentPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (offline) {
      return expanded
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Offline – deine gespeicherte Musik findest du unter Bibliothek › Auf diesem Gerät.',
                style: AppText.caption,
              ),
            )
          : const SizedBox.shrink();
    }
    final overview = ref.watch(libraryOverviewProvider);
    final data = overview.value;
    if (data == null) {
      if (overview.hasError && expanded) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Text(errorText(overview.error!), style: AppText.caption),
        );
      }
      return const SizedBox.shrink();
    }
    final likedSelected = currentPath.endsWith('/liked');
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        _PlaylistTile(
          expanded: expanded,
          title: 'Lieblingssongs',
          subtitle: 'Playlist · ${pluralSongs(data.likedCount)}',
          cover: (size) => LikedSongsCover(size: size, radius: 4),
          selected: likedSelected,
          onTap: () => Nav.liked(context),
        ),
        for (final playlist in data.playlists)
          _PlaylistTile(
            expanded: expanded,
            title: playlist.name,
            subtitle: 'Playlist · ${playlist.owner.displayName}',
            cover: (size) => PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: size, radius: 4),
            selected: _isOpen(playlist),
            onTap: () => Nav.playlist(context, playlist.id),
          ),
      ],
    );
  }

  bool _isOpen(Playlist playlist) => currentPath.endsWith('/playlist/${playlist.id}');
}

class _PlaylistTile extends StatelessWidget {
  final bool expanded;
  final String title;
  final String subtitle;
  final Widget Function(double size) cover;
  final bool selected;
  final VoidCallback onTap;

  const _PlaylistTile({
    required this.expanded,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!expanded) {
      return Tooltip(
        message: title,
        child: InkWell(
          onTap: onTap,
          child: Container(
            color: selected ? AppColors.surfaceHigh : null,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(child: cover(48)),
          ),
        ),
      );
    }
    return Material(
      color: selected ? AppColors.surfaceHigh : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              cover(44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.tileTitle.copyWith(color: selected ? AppColors.accent : Colors.white),
                    ),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
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
