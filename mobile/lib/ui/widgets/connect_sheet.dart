import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_config.dart';
import '../../state/auth.dart';
import '../../state/connect.dart';
import '../../state/premium_access.dart';
import '../nav.dart';
import 'common.dart';

// „Geräte“: Liste der verbundenen Geräte des Kontos – Wiedergabe übertragen, zurückholen, eigenes Gerät umbenennen.
// Nicht zu verwechseln mit der Sitzungsverwaltung (Einstellungen › Angemeldete Geräte).

/// Symbol zum Gerätetyp.
IconData deviceKindIcon(String kind) => switch (kind) {
      DeviceKind.computer => Icons.computer_rounded,
      DeviceKind.tablet => Icons.tablet_rounded,
      _ => Icons.smartphone_rounded,
    };

/// Darf dieses Konto übertragen? Verbunden zählt die Antwort des Servers, sonst der bekannte Premium-Stand.
bool connectLocked(ConnectState connect, PremiumAccess access) =>
    connect.connected ? !connect.allowed : !access.allows(PremiumFeature.remote);

/// Knopf „Geräte“ (nur, wenn der Server die Funktion hat). Im Remote-Modus in Akzentfarbe.
class ConnectButton extends ConsumerWidget {
  final double? iconSize;
  final Color color;

  const ConnectButton({super.key, this.iconSize, this.color = Colors.white});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(connectProvider.select((s) => s.available));
    if (!available) return const SizedBox.shrink();
    final remote = ref.watch(connectProvider.select((s) => s.isRemote));
    return IconButton(
      tooltip: 'Geräte',
      iconSize: iconSize,
      icon: Icon(Icons.devices_rounded, color: remote ? AppColors.accent : color),
      onPressed: () => showConnectSheet(context),
    );
  }
}

/// Geräte-Liste als Blatt von unten.
Future<void> showConnectSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ConnectSheet(outer: context),
    );

class _ConnectSheet extends ConsumerStatefulWidget {
  /// Kontext unter dem Blatt – für Meldungen, die nach dem Schließen sichtbar bleiben.
  final BuildContext outer;
  const _ConnectSheet({required this.outer});

  @override
  ConsumerState<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends ConsumerState<_ConnectSheet> {
  void _message(String text) {
    final target = widget.outer.mounted ? widget.outer : context;
    if (target.mounted) showMessage(target, text);
  }

  Future<void> _transfer(PlaybackDevice device) async {
    final controller = ref.read(connectProvider.notifier);
    final result = await controller.transfer(device.id);
    if (!mounted) return;
    if (!result.ok) {
      _message(result.text);
      return;
    }
    Navigator.of(context).pop();
    _message(device.isSelf ? 'Spielt jetzt auf diesem Gerät' : 'Spielt jetzt auf ${device.name}');
  }

  Future<void> _rename(PlaybackDevice device) async {
    final name = await showRenameDeviceDialog(context, device.name);
    if (name == null || !mounted) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      await api.renameSession(device.id, name);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connect = ref.watch(connectProvider);
    final access = ref.watch(premiumAccessProvider);
    final locked = connectLocked(connect, access);
    final premiumVisible = ref.watch(premiumVisibleProvider);
    final devices = connect.devices;
    // „Aktuelles Gerät“: das spielende – oder, wenn keins spielt, dieses
    final current = connect.activeDevice ?? connect.selfDevice;
    final others = [
      for (final device in devices)
        if (device.id != current?.id) device,
    ];

    final children = <Widget>[
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text('Geräte', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      ),
      if (locked)
        _PremiumHint(
          showButton: premiumVisible,
          onOpen: () {
            Navigator.of(context).pop();
            if (widget.outer.mounted) Nav.premium(widget.outer);
          },
        ),
      if (!connect.connected)
        const _Note(
          icon: Icons.sync_rounded,
          text: 'Verbindung zu deinen Geräten wird hergestellt …',
        )
      else ...[
        if (current != null) ...[
          const _Section('Aktuelles Gerät'),
          _row(connect, current, locked),
        ],
        const _Section('Weitere Geräte'),
        if (others.isEmpty)
          const _Note(
            icon: Icons.devices_other_rounded,
            text: 'Keine weiteren Geräte gefunden. Öffne Selfify auf deinem PC, Handy oder Tablet und melde dich mit '
                'demselben Konto an.',
          )
        else
          for (final device in others) _row(connect, device, locked),
      ],
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Text(
          'Handys und Tablets erscheinen, solange die App geöffnet ist oder Musik spielt.',
          style: AppText.caption,
        ),
      ),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }

  Widget _row(ConnectState connect, PlaybackDevice device, bool locked) {
    final transferringHere = connect.transferring && connect.transferTarget == device.id;
    final playingHere = device.id == connect.activeDeviceId;
    // Zurückholen: eigenes Gerät, während ein anderes gesteuert wird; sonst: anderes Gerät, das nicht schon spielt
    final canTap = !locked &&
        !connect.transferring &&
        device.canPlay &&
        (device.isSelf ? connect.isRemote : !playingHere);
    final notes = [
      if (device.isSelf) 'Dieses Gerät',
      if (playingHere) 'Spielt gerade',
      if (!device.canPlay) 'Kann gerade nicht abspielen',
    ];
    return _DeviceRow(
      device: device,
      dimmed: locked || !device.canPlay,
      highlighted: playingHere,
      subtitle: transferringHere ? 'Wird übertragen …' : notes.join(' · '),
      busy: transferringHere,
      onTap: canTap ? () => _transfer(device) : null,
      onRename: device.isSelf ? () => _rename(device) : null,
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  const _Section(this.title);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(title, style: AppText.tileSubtitle.copyWith(fontWeight: FontWeight.w700)),
      );
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Note({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: AppColors.textSecondary),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: AppText.tileSubtitle)),
          ],
        ),
      );
}

class _PremiumHint extends StatelessWidget {
  final bool showButton;
  final VoidCallback onOpen;
  const _PremiumHint({required this.showButton, required this.onOpen});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(10)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.workspace_premium_rounded, color: AppColors.accent, size: 22),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Auf anderen Geräten abspielen gibt es nur mit Premium.',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (showButton)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onOpen,
                  child: const Text('Premium ansehen', style: TextStyle(color: AppColors.accent)),
                ),
              ),
          ],
        ),
      );
}

class _DeviceRow extends StatelessWidget {
  final PlaybackDevice device;
  final bool dimmed;
  final bool highlighted;
  final String subtitle;
  final bool busy;
  final VoidCallback? onTap;
  final VoidCallback? onRename;

  const _DeviceRow({
    required this.device,
    required this.dimmed,
    required this.highlighted,
    required this.subtitle,
    required this.busy,
    required this.onTap,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? AppColors.accent : Colors.white;
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 20, right: 8),
        leading: busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
            : Icon(deviceKindIcon(device.kind), color: highlighted ? AppColors.accent : AppColors.textSecondary),
        title: Text(
          device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500, fontSize: 15),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
        trailing: onRename == null
            ? null
            : TextButton(
                onPressed: onRename,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Umbenennen'),
              ),
        onTap: onTap,
      ),
    );
  }
}

/// Dialog „Gerät umbenennen“ – liefert den neuen Namen (getrimmt) oder null bei „Abbrechen“.
Future<String?> showRenameDeviceDialog(BuildContext context, String current) => showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _RenameDialog(initial: current),
    );

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Bitte gib einen Namen ein.');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Gerät umbenennen'),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 100,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: 'Name', errorText: _error),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
          TextButton(onPressed: _save, child: const Text('Speichern')),
        ],
      );
}
