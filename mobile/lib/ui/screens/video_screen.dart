import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';

/// PLATZHALTER – wird im nächsten Schritt umgesetzt.
class VideoScreen extends ConsumerWidget {
  final int trackId;
  final Track? track;
  const VideoScreen({super.key, required this.trackId, this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(body: Center(child: Text('VideoScreen')));
  }
}
