import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../player/player.dart';
import 'connect_sheet.dart';

/// Schmale Leiste „Spielt auf …“ (nur, solange ein anderes Gerät ferngesteuert wird). Tippen öffnet die Geräte.
class ConnectBar extends ConsumerWidget {
  /// Abgerundete Ecken unten (unter dem Mini-Player) oder gerade (über der Player-Leiste am PC).
  final BorderRadius borderRadius;

  const ConnectBar({super.key, this.borderRadius = BorderRadius.zero});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(remoteDeviceProvider);
    if (device == null) return const SizedBox.shrink();
    return Material(
      color: AppColors.accent,
      borderRadius: borderRadius,
      child: InkWell(
        onTap: () => showConnectSheet(context),
        borderRadius: borderRadius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Icon(deviceKindIcon(device.kind), size: 16, color: Colors.black),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Spielt auf ${device.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
