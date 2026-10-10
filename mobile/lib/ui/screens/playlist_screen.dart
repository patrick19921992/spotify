import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PLATZHALTER – wird im nächsten Schritt umgesetzt.
class PlaylistScreen extends ConsumerWidget {
  final int playlistId;
  const PlaylistScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(body: Center(child: Text('PlaylistScreen')));
  }
}
