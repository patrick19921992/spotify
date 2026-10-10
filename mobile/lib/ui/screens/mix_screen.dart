import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PLATZHALTER – wird im nächsten Schritt umgesetzt.
class MixScreen extends ConsumerWidget {
  final String mixKey;
  const MixScreen({super.key, required this.mixKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(body: Center(child: Text('MixScreen')));
  }
}
