import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PLATZHALTER – wird im nächsten Schritt umgesetzt.
class AlbumScreen extends ConsumerWidget {
  final int albumId;
  const AlbumScreen({super.key, required this.albumId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(body: Center(child: Text('AlbumScreen')));
  }
}
