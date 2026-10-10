import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PLATZHALTER – wird im nächsten Schritt umgesetzt.
class ArtistScreen extends ConsumerWidget {
  final int artistId;
  const ArtistScreen({super.key, required this.artistId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(body: Center(child: Text('ArtistScreen')));
  }
}
