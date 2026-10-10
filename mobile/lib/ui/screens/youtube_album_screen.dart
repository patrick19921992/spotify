import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PLATZHALTER – wird im nächsten Schritt umgesetzt.
class YouTubeAlbumScreen extends ConsumerWidget {
  final String browseId;
  const YouTubeAlbumScreen({super.key, required this.browseId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(body: Center(child: Text('YouTubeAlbumScreen')));
  }
}
