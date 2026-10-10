import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';

/// Navigation wie bei Spotify: Detailseiten öffnen sich im aktuellen Tab (Start/Suche/Bibliothek),
/// die untere Leiste und der Mini-Player bleiben sichtbar.
class Nav {
  static String _tab(BuildContext context) {
    String path;
    try {
      path = GoRouter.of(context).routerDelegate.currentConfiguration.uri.path;
    } catch (_) {
      path = '/home';
    }
    final first = path.split('/').where((s) => s.isNotEmpty).firstOrNull;
    return switch (first) { 'search' => '/search', 'library' => '/library', _ => '/home' };
  }

  static void album(BuildContext context, int id) => context.push('${_tab(context)}/album/$id');
  static void artist(BuildContext context, int id) => context.push('${_tab(context)}/artist/$id');
  static void playlist(BuildContext context, int id) => context.push('${_tab(context)}/playlist/$id');
  static void liked(BuildContext context) => context.push('${_tab(context)}/liked');
  static void mix(BuildContext context, String key) =>
      context.push('${_tab(context)}/mix/${Uri.encodeComponent(key)}');
  static void category(BuildContext context, int id) => context.push('${_tab(context)}/category/$id');
  static void youtubeAlbum(BuildContext context, String browseId) =>
      context.push('${_tab(context)}/youtube-album/$browseId');

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
  static void offline(BuildContext context) => context.push('/offline');
  static void settings(BuildContext context) => context.push('/settings');
  static void devices(BuildContext context) => context.push('/settings/devices');
  static void admin(BuildContext context) => context.push('/admin');
}
