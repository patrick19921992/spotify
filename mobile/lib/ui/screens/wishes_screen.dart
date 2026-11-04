import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_config.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../widgets/common.dart';
import 'account_widgets.dart';

/// Beschriftung und Farbe zum Stand eines Wunsches.
({String label, Color color, IconData icon}) wishStatus(SongWish wish) {
  if (wish.isDone) return (label: 'Erledigt – jetzt in der Bibliothek', color: AppColors.accent, icon: Icons.check_circle_rounded);
  if (wish.isDeclined) return (label: 'Abgelehnt', color: AppColors.danger, icon: Icons.cancel_rounded);
  if (wish.isAccepted) {
    final failed = wish.jobStatus == 'failed';
    return failed
        ? (label: 'Angenommen – das Holen hat nicht geklappt', color: AppColors.danger, icon: Icons.error_outline_rounded)
        : (label: 'Angenommen – wird geholt', color: const Color(0xFF509BF5), icon: Icons.downloading_rounded);
  }
  return (label: 'Offen – wartet auf den Betreiber', color: AppColors.textSecondary, icon: Icons.hourglass_top_rounded);
}

/// „Meine Wünsche“: alle Songs, die du dir gewünscht hast, mit Stand.
class WishesScreen extends ConsumerWidget {
  const WishesScreen({super.key});

  Future<void> _remove(BuildContext context, WidgetRef ref, SongWish wish) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final ok = await confirm(
      context,
      title: 'Wunsch löschen?',
      message: '„${wish.title}“ wird aus deiner Liste entfernt.',
      confirmLabel: 'Löschen',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await api.deleteWish(wish.id);
      ref.invalidate(wishesProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wishes = ref.watch(wishesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Meine Wünsche')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showWishSheet(context),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Song wünschen', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: AsyncBody<List<SongWish>>(
        value: wishes,
        onRetry: () => ref.invalidate(wishesProvider),
        builder: (items) => RefreshableList(
          onRefresh: () async {
            ref.invalidate(wishesProvider);
            await ref.read(wishesProvider.future);
          },
          child: items.isEmpty
              ? LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SizedBox(
                      height: box.maxHeight,
                      child: const EmptyState(
                        icon: Icons.queue_music_rounded,
                        title: 'Noch keine Wünsche',
                        message: 'Fehlt dir ein Song? Wünsch ihn dir – sobald der Betreiber ihn besorgt hat, '
                            'findest du ihn in der Bibliothek.',
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(0, 4, 0, 96 + MediaQuery.paddingOf(context).bottom),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) => _WishTile(wish: items[index], onRemove: () => _remove(context, ref, items[index])),
                ),
        ),
      ),
    );
  }
}

class _WishTile extends StatelessWidget {
  final SongWish wish;
  final VoidCallback onRemove;

  const _WishTile({required this.wish, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final status = wishStatus(wish);
    return ListTile(
      isThreeLine: true,
      leading: Icon(status.icon, color: status.color),
      title: Text(
        wish.artist.isEmpty ? wish.title : '${wish.title} – ${wish.artist}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppText.tileTitle.copyWith(fontSize: 16),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status.label, style: TextStyle(color: status.color, fontSize: 13, fontWeight: FontWeight.w600)),
          if (wish.adminNote.isNotEmpty)
            Text('Nachricht: ${wish.adminNote}', maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
          Text(formatDate(wish.createdAt), style: AppText.caption),
        ],
      ),
      trailing: wish.canRemove
          ? IconButton(
              tooltip: 'Wunsch löschen',
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.textSecondary),
              onPressed: onRemove,
            )
          : null,
    );
  }
}

/// Blatt „Song wünschen“. [initialTitle] kommt z. B. aus dem Suchfeld. Liefert true, wenn der Wunsch gesendet wurde.
Future<bool> showWishSheet(BuildContext context, {String initialTitle = ''}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.surfaceHigh,
    builder: (_) => _WishSheet(initialTitle: initialTitle),
  );
  return sent ?? false;
}

class _WishSheet extends ConsumerStatefulWidget {
  final String initialTitle;
  const _WishSheet({required this.initialTitle});

  @override
  ConsumerState<_WishSheet> createState() => _WishSheetState();
}

class _WishSheetState extends ConsumerState<_WishSheet> {
  late final TextEditingController _title = TextEditingController(text: widget.initialTitle);
  final _artist = TextEditingController();
  final _note = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Bitte gib den Titel ein.');
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await api.createWish(title: title, artist: _artist.text.trim(), note: _note.text.trim());
      ref.invalidate(wishesProvider);
      if (!mounted) return;
      Navigator.pop(context, true);
      showMessage(context, 'Wunsch gesendet – du siehst den Stand unter „Meine Wünsche“.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 20, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Song wünschen', style: AppText.sectionTitle),
            const SizedBox(height: 4),
            const Text(
              'Der Betreiber sieht deinen Wunsch und besorgt den Song, wenn er ihn bekommen kann.',
              style: AppText.tileSubtitle,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              enabled: !_sending,
              autofocus: widget.initialTitle.isEmpty,
              maxLength: 200,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Titel', counterText: ''),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _artist,
              enabled: !_sending,
              maxLength: 200,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Interpret (optional)', counterText: ''),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              enabled: !_sending,
              maxLength: 500,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Hinweis (optional, z. B. Album oder Version)', counterText: ''),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              AccountNotice.error(_error!),
            ],
            const SizedBox(height: 16),
            AccountButton(label: 'Wunsch senden', loading: _sending, onPressed: _send),
          ],
        ),
      ),
    );
  }
}

/// Kachel in der Suche: „Nicht dabei? Wünsch dir den Song“ (statt der YouTube-Suche der GitHub-Version).
class WishSuggestionTile extends ConsumerWidget {
  /// Suchbegriff, der als Titel vorgeschlagen wird (leer = nichts vorausgefüllt).
  final String query;
  const WishSuggestionTile({super.key, this.query = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(wishlistVisibleProvider)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => showWishSheet(context, initialTitle: query),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.playlist_add_rounded, color: AppColors.accent, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Nicht dabei? Wünsch dir den Song',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.white)),
                      Text(
                        query.isEmpty ? 'Der Betreiber besorgt ihn für dich.' : '„$query“ wünschen – der Betreiber besorgt ihn.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tileSubtitle,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
