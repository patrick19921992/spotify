import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PLATZHALTER – wird im nächsten Schritt umgesetzt.
class CategoryScreen extends ConsumerWidget {
  final int categoryId;
  const CategoryScreen({super.key, required this.categoryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(body: Center(child: Text('CategoryScreen')));
  }
}
