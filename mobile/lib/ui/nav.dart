import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';

/// Navigation wie bei Spotify: Detailseiten öffnen sich im aktuellen Tab (Start/Suche/Bibliothek),
/// die untere Leiste und der Mini-Player bleiben sichtbar.
class Nav {
  static const _tabs = {'home', 'search', 'library'};

  /// Pfad der obersten Seite (z. B. "/player" über "/home").
  static String _topPath(GoRouter router) {
    try {
      return router.state.uri.path;
    } catch (_) {
      return '/home';
    }
  }

  /// "/home", "/search" oder "/library" – null, wenn oben eine Vollbild-Seite liegt.
  static String? _tabOf(String path) {
    final first = path.split('/').where((s) => s.isNotEmpty).firstOrNull;
    return _tabs.contains(first) ? '/$first' : null;
  }

  /// Öffnet eine Detailseite im aktuellen Tab.
  ///
  /// Liegt eine Vollbild-Seite darüber (Player, Warteschlange, Video, Downloads, Einstellungen …),
  /// wird sie zuerst geschlossen: Würde die Detailseite darüber gelegt, baut go_router die Tab-Ansicht
  /// ein zweites Mal auf und die App stürzt ab.
  static void _openInTab(BuildContext context, String subPath) {
    final GoRouter router;
    try {
      router = GoRouter.of(context);
    } catch (_) {
      return;
    }
    var tab = _tabOf(_topPath(router));
    while (tab == null && router.canPop()) {
      router.pop();
      tab = _tabOf(_topPath(router));
    }
    if (tab == null) {
      router.go('/home/$subPath');
    } else {
      router.push('$tab/$subPath');
    }
  }

  static void album(BuildContext context, int id) => _openInTab(context, 'album/$id');
  static void artist(BuildContext context, int id) => _openInTab(context, 'artist/$id');
  static void playlist(BuildContext context, int id) => _openInTab(context, 'playlist/$id');
  static void liked(BuildContext context) => _openInTab(context, 'liked');
  static void mix(BuildContext context, String key) => _openInTab(context, 'mix/${Uri.encodeComponent(key)}');
  static void category(BuildContext context, int id) => _openInTab(context, 'category/$id');
  static void youtubeAlbum(BuildContext context, String browseId) => _openInTab(context, 'youtube-album/$browseId');

  /// Kachel der Startseite öffnen (Album, Playlist, Künstler, Lieblingssongs, Mix).
  static void context_(BuildContext context, ContextItem item) {
    switch (item.type) {
      case 'album':
        album(context, int.parse(item.id));
      case 'playlist':
        playlist(context, int.parse(item.id));
      case 'artist':
        artist(context, int.parse(item.id));
      case 'liked':
        liked(context);
      case 'mix':
        mix(context, item.id);
    }
  }

  static void player(BuildContext context) => context.push('/player');
  static void queue(BuildContext context) => context.push('/queue');
  static void video(BuildContext context, Track track) => context.push('/video/${track.id}', extra: track);
  static void downloads(BuildContext context) => context.push('/downloads');
  static void allDownloads(BuildContext context) => context.push('/downloads?scope=all');
  static void offline(BuildContext context) => context.push('/offline');
  static void settings(BuildContext context) => context.push('/settings');
  static void devices(BuildContext context) => context.push('/settings/devices');
  static void admin(BuildContext context) => context.push('/admin');
}
