import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../widgets/common.dart';
import 'admin_library.dart';
import 'admin_widgets.dart';

// Verwaltung › Rubriken: eigene Bereiche (Ordner) anlegen, umbenennen, sortieren, entfernen.

const _deleteMessage = 'Entfernt die Rubrik mit allen ihren Titeln aus der App – auch aus den Playlists, Lieblingssongs '
    'und dem Verlauf aller Familienmitglieder. Der Ordner und alle Dateien bleiben auf dem Server erhalten.';

/// Was beim Entfernen verloren geht – ehrlich, mit Anzahl der Titel.
String _deleteDetails(Category category) {
  final buffer = StringBuffer();
  if (category.itemCount > 0) {
    buffer
      ..write('„${category.name}“ enthält ${_itemCountLabel(category)}. ')
      ..write('Sie verschwinden für alle aus Playlists, Lieblingssongs und Verlauf. ')
      ..write('Legst du die Rubrik später neu an, kommen diese Einträge nicht zurück.\n\n');
  }
  buffer
    ..write('Der Ordner /media/${category.folder} und alle Dateien bleiben auf dem Server erhalten.\n\n')
    ..write('Nur umbenennen? Dafür reicht „Speichern“ – dabei geht nichts verloren.');
  return buffer.toString();
}

String _mediaLabel(Category category) => category.isVideo ? 'Video' : 'Audio';

String _itemCountLabel(Category category) {
  final count = category.itemCount;
  if (category.isVideo) return count == 1 ? '1 Video' : '${formatCount(count)} Videos';
  return count == 1 ? '1 Titel' : '${formatCount(count)} Titel';
}

/// Nach Änderungen an Rubriken alles neu laden, was Rubriken anzeigt.
void _invalidateCategories(WidgetRef ref, {bool content = false}) {
  ref.invalidate(categoriesProvider);
  ref.invalidate(homeProvider);
  if (content) {
    ref.invalidate(libraryOverviewProvider);
    ref.invalidate(adminLibraryStatsProvider);
  }
}

/// Tab „Rubriken“.
class AdminCategoriesTab extends ConsumerStatefulWidget {
  const AdminCategoriesTab({super.key});

  @override
  ConsumerState<AdminCategoriesTab> createState() => _AdminCategoriesTabState();
}

class _AdminCategoriesTabState extends ConsumerState<AdminCategoriesTab> {
  /// Neue Reihenfolge, solange sie gespeichert wird (sofort anzeigen statt warten).
  List<Category>? _order;

  /// Zuletzt gespeicherte Sortierwerte (bis die Liste neu vom Server kommt).
  final Map<int, int> _savedOrder = {};
  Future<void> _queue = Future.value();
  int _pendingSaves = 0;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AsyncValue<List<Category>>>(categoriesProvider, (_, next) {
      // Frische Liste vom Server -> lokale Reihenfolge ist übernommen
      if (next.isLoading || !next.hasValue || _pendingSaves > 0) return;
      _savedOrder.clear();
      if (_order != null && mounted) setState(() => _order = null);
    });
  }

  Future<void> _refresh() => adminQuietly(ref.refresh(categoriesProvider.future));

  /// [newIndex] ist schon um das entfernte Element bereinigt (onReorderItem).
  void _reorder(List<Category> current, int oldIndex, int newIndex) {
    if (newIndex == oldIndex) return;
    final list = [...current];
    list.insert(newIndex, list.removeAt(oldIndex));
    setState(() => _order = list);
    final api = ref.read(apiProvider);
    _pendingSaves++;
    _queue = _queue.then((_) => _saveOrder(api, list));
  }

  Future<void> _saveOrder(ApiClient? api, List<Category> list) async {
    Object? error;
    if (api != null) {
      try {
        for (var i = 0; i < list.length; i++) {
          final category = list[i];
          final sortOrder = (i + 1) * 10;
          if ((_savedOrder[category.id] ?? category.sortOrder) == sortOrder) continue;
          await api.updateCategory(category.id, sortOrder: sortOrder);
          _savedOrder[category.id] = sortOrder;
        }
      } catch (e) {
        error = e;
      }
    }
    _pendingSaves--;
    if (!mounted) return;
    if (error != null) {
      showError(context, error);
      _savedOrder.clear();
      setState(() => _order = null);
    }
    if (_pendingSaves == 0) _invalidateCategories(ref);
  }

  Future<void> _makeDefault(Category category) async {
    final kind = category.isVideo ? 'Video' : 'Audio';
    if (category.isDefault) {
      showMessage(
        context,
        '„${category.name}“ ist schon der Standard für neue $kind-Downloads. '
        'Tippe bei einer anderen $kind-Rubrik auf den Stern, um das zu ändern.',
      );
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      await api.updateCategory(category.id, isDefault: true);
      if (!mounted) return;
      _invalidateCategories(ref);
      showMessage(context, '„${category.name}“ ist jetzt der Standard für neue $kind-Downloads');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _edit(Category category) async {
    final message = await showAdminSheet<String>(context, (_) => _EditCategorySheet(category: category));
    if (message != null && mounted) showMessage(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(categoriesProvider);
    return AsyncBody<List<Category>>(
      value: value,
      onRetry: () => ref.invalidate(categoriesProvider),
      builder: (categories) {
        final list = _order ?? categories;
        final padding = adminListPadding(context, top: 0, bottom: 96, horizontal: 0);
        if (list.isEmpty) {
          return RefreshIndicator(
            color: AppColors.accent,
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              children: const [
                SizedBox(height: 64),
                EmptyState(
                  icon: Icons.category_outlined,
                  title: 'Noch keine Rubriken',
                  message: 'Lege eine Rubrik an, zum Beispiel „Kinderlieder“ oder „Konzerte“. '
                      'Jede Rubrik bekommt einen eigenen Ordner auf dem Server.',
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          color: AppColors.accent,
          onRefresh: _refresh,
          child: ReorderableListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: padding,
            buildDefaultDragHandles: false,
            header: const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Ziehe eine Rubrik am Griff (oder halte sie gedrückt), um die Reihenfolge in der App zu ändern. '
                'Der Stern markiert das Standard-Ziel für neue Downloads.',
                style: AppText.caption,
              ),
            ),
            itemCount: list.length,
            onReorderItem: (oldIndex, newIndex) => _reorder(list, oldIndex, newIndex),
            proxyDecorator: (child, _, animation) => AnimatedBuilder(
              animation: animation,
              builder: (context, child) => Material(
                color: AppColors.surfaceHigh,
                elevation: 8 * animation.value,
                borderRadius: BorderRadius.circular(8),
                child: child,
              ),
              child: child,
            ),
            itemBuilder: (context, index) {
              final category = list[index];
              return ReorderableDelayedDragStartListener(
                key: ValueKey(category.id),
                index: index,
                child: _CategoryTile(
                  category: category,
                  index: index,
                  onTap: () => _edit(category),
                  onStar: () => _makeDefault(category),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _CategoryIconBox extends StatelessWidget {
  final Category category;
  final double size;
  const _CategoryIconBox({required this.category, this.size = 52});

  @override
  Widget build(BuildContext context) {
    final color = category.isVideo ? adminVideoColor : AppColors.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.35), AppColors.surfaceHigh],
        ),
      ),
      child: Icon(adminCategoryIcon(category.icon), color: Colors.white, size: size * 0.5),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final Category category;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onStar;

  const _CategoryTile({required this.category, required this.index, required this.onTap, required this.onStar});

  @override
  Widget build(BuildContext context) {
    final kind = _mediaLabel(category);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            children: [
              _CategoryIconBox(category: category),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            category.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.tileTitle.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AdminMediaTypeChip(isVideo: category.isVideo),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(_itemCountLabel(category), style: AppText.tileSubtitle, maxLines: 1),
                    const SizedBox(height: 2),
                    Text(
                      '/media/${category.folder}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: adminMonospace,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: category.isDefault ? 'Standard für neue $kind-Downloads' : 'Als Standard für $kind festlegen',
                onPressed: onStar,
                icon: Icon(
                  category.isDefault ? Icons.star_rounded : Icons.star_border_rounded,
                  color: category.isDefault ? AppColors.accent : AppColors.textMuted,
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Icon(Icons.drag_handle_rounded, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Rubrik bearbeiten

class _EditCategorySheet extends ConsumerStatefulWidget {
  final Category category;
  const _EditCategorySheet({required this.category});

  @override
  ConsumerState<_EditCategorySheet> createState() => _EditCategorySheetState();
}

class _EditCategorySheetState extends ConsumerState<_EditCategorySheet> {
  late final TextEditingController _name = TextEditingController(text: widget.category.name);
  late String _icon = widget.category.icon;
  late bool _makeDefault = widget.category.isDefault;
  bool _busy = false;
  String? _error;

  Category get _category => widget.category;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _trimmedName => _name.text.trim();

  bool get _nameChanged => _trimmedName != _category.name;
  bool get _iconChanged => _icon != _category.icon;
  bool get _defaultChanged => _makeDefault && !_category.isDefault;
  bool get _changed => _nameChanged || _iconChanged || _defaultChanged;

  String? get _nameError {
    if (_trimmedName.isEmpty) return 'Bitte gib einen Namen ein.';
    if (_trimmedName.length > 64) return 'Höchstens 64 Zeichen.';
    return null;
  }

  Future<void> _save() async {
    if (_busy || !_changed || _nameError != null) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await api.updateCategory(
        _category.id,
        name: _nameChanged ? _trimmedName : null,
        icon: _iconChanged ? _icon : null,
        isDefault: _defaultChanged ? true : null,
      );
      if (!mounted) return;
      _invalidateCategories(ref);
      Navigator.of(context).pop('„${updated.name}“ gespeichert');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
    }
  }

  Future<void> _delete() async {
    final category = _category;
    final ok = category.itemCount > 0
        ? await showDialog<bool>(context: context, builder: (_) => _ConfirmDeleteDialog(category: category)) ?? false
        : await confirm(
            context,
            title: '„${category.name}“ entfernen?',
            message: _deleteDetails(category),
            confirmLabel: 'Entfernen',
            danger: true,
          );
    if (!ok || !mounted) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.deleteCategory(_category.id);
      if (!mounted) return;
      _invalidateCategories(ref, content: true);
      Navigator.of(context).pop(
        '„${_category.name}“ wurde entfernt. Die Dateien liegen weiter in /media/${_category.folder}.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = _mediaLabel(_category);
    final nameError = _nameError;
    return AdminSheet(
      title: 'Rubrik bearbeiten',
      subtitle: '$kind · ${_itemCountLabel(_category)}',
      leading: _CategoryIconBox(category: _category, size: 48),
      children: [
        TextField(
          controller: _name,
          maxLength: 64,
          enabled: !_busy,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Name',
            prefixIcon: const Icon(Icons.label_outline_rounded),
            errorText: nameError,
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 20),
        const Text('Symbol', style: AppText.tileTitle),
        const SizedBox(height: 10),
        AdminIconPicker(selected: _icon, onChanged: _busy ? null : (icon) => setState(() => _icon = icon)),
        const SizedBox(height: 20),
        AdminCard(
          color: AppColors.surfaceHighest,
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.folder_outlined, color: AppColors.textSecondary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('/media/${_category.folder}', style: adminMonospace.copyWith(color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 4),
                    const Text(
                      'Der Ordner lässt sich nicht ändern, damit keine Dateien verloren gehen.',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _makeDefault,
          onChanged: _busy || _category.isDefault ? null : (value) => setState(() => _makeDefault = value),
          secondary: Icon(_makeDefault ? Icons.star_rounded : Icons.star_border_rounded,
              color: _makeDefault ? AppColors.accent : null),
          title: Text('Standard für neue $kind-Downloads'),
          subtitle: Text(
            _category.isDefault
                ? 'Wähle eine andere $kind-Rubrik als Standard, um das zu ändern.'
                : 'Hier landen Downloads, wenn keine Rubrik gewählt wird.',
            style: AppText.caption,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          AdminNotice(_error!),
        ],
        const SizedBox(height: 20),
        AdminPrimaryButton(
          label: 'Speichern',
          busy: _busy,
          onPressed: _changed && _nameError == null ? _save : null,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Rubrik entfernen'),
          ),
        ),
        const Text(_deleteMessage, style: AppText.caption),
      ],
    );
  }
}

/// Abfrage vor dem Entfernen einer Rubrik mit Titeln: erst nach Eintippen des Namens möglich.
class _ConfirmDeleteDialog extends StatefulWidget {
  const _ConfirmDeleteDialog({required this.category});

  final Category category;

  @override
  State<_ConfirmDeleteDialog> createState() => _ConfirmDeleteDialogState();
}

class _ConfirmDeleteDialogState extends State<_ConfirmDeleteDialog> {
  final _controller = TextEditingController();

  bool get _matches => _controller.text.trim().toLowerCase() == widget.category.name.trim().toLowerCase();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('„${widget.category.name}“ endgültig entfernen?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_deleteDetails(widget.category)),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Zum Bestätigen „${widget.category.name}“ eingeben'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
        TextButton(
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          child: Text('Endgültig entfernen', style: TextStyle(color: _matches ? AppColors.danger : null)),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Rubrik anlegen

/// Blatt „Rubrik anlegen“ (vom Plus-Knopf der Verwaltung).
Future<void> showCreateCategorySheet(BuildContext context) async {
  final category = await showAdminSheet<Category>(context, (_) => const _CreateCategorySheet());
  if (category != null && context.mounted) {
    showMessage(
      context,
      'Rubrik „${category.name}“ angelegt. Dateien in /media/${category.folder} werden automatisch eingelesen.',
    );
  }
}

const _umlauts = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'Ä': 'Ae', 'Ö': 'Oe', 'Ü': 'Ue', 'ß': 'ss'};

const _accents = {
  'a': 'àáâãåāăą',
  'A': 'ÀÁÂÃÅĀĂĄ',
  'c': 'çćĉċč',
  'C': 'ÇĆĈĊČ',
  'd': 'ď',
  'D': 'Ď',
  'e': 'èéêëēĕėęě',
  'E': 'ÈÉÊËĒĔĖĘĚ',
  'g': 'ĝğġģ',
  'G': 'ĜĞĠĢ',
  'i': 'ìíîïĩīĭį',
  'I': 'ÌÍÎÏĨĪĬĮİ',
  'n': 'ñńņňǹ',
  'N': 'ÑŃŅŇǸ',
  'o': 'òóôõōŏő',
  'O': 'ÒÓÔÕŌŎŐ',
  'r': 'ŕŗř',
  'R': 'ŔŖŘ',
  's': 'śŝşš',
  'S': 'ŚŜŞŠ',
  't': 'ţť',
  'T': 'ŢŤ',
  'u': 'ùúûũūŭůűų',
  'U': 'ÙÚÛŨŪŬŮŰŲ',
  'y': 'ýÿŷ',
  'Y': 'ÝŸŶ',
  'z': 'źżž',
  'Z': 'ŹŻŽ',
};

final Map<String, String> _accentMap = {
  for (final entry in _accents.entries)
    for (final char in entry.value.split('')) char: entry.key,
};

/// Ordnername wie ihn der Server aus dem Namen bildet („Hörspiele & Co.“ -> „Hoerspiele und Co“).
String _folderFromName(String name) {
  var folder = name.split('').map((c) => _umlauts[c] ?? _accentMap[c] ?? c).join();
  folder = folder.replaceAll('&', 'und').replaceAll(RegExp(r'[^A-Za-z0-9 _-]+'), '');
  folder = folder.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (folder.length > 100) folder = folder.substring(0, 100).trim();
  return folder.isEmpty ? 'Rubrik' : folder;
}

/// Grobe Prüfung des Ordners (der Server prüft genauer).
String? _validateFolder(String folder) {
  if (folder.isEmpty) return null;
  if (folder.startsWith('/')) return 'Bitte relativ angeben, z. B. „Hoerspiele“ oder „Videos/Konzerte“.';
  if (folder.length > 255) return 'Höchstens 255 Zeichen.';
  final parts = folder.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty);
  if (parts.any((p) => p == '.' || p == '..' || p.startsWith('.'))) return 'Ungültiger Ordnername.';
  if (RegExp(r'[:*?"<>|]').hasMatch(folder) || folder.codeUnits.any((c) => c < 32)) {
    return 'Der Ordnername enthält unerlaubte Zeichen.';
  }
  return null;
}

class _CreateCategorySheet extends ConsumerStatefulWidget {
  const _CreateCategorySheet();

  @override
  ConsumerState<_CreateCategorySheet> createState() => _CreateCategorySheetState();
}

class _CreateCategorySheetState extends ConsumerState<_CreateCategorySheet> {
  final _name = TextEditingController();
  final _folder = TextEditingController();
  String _mediaType = 'audio';
  String _icon = 'music_note';
  bool _iconTouched = false;
  bool _submitted = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _folder.dispose();
    super.dispose();
  }

  String get _trimmedName => _name.text.trim();
  String get _trimmedFolder => _folder.text.trim();

  String? get _nameError {
    if (_trimmedName.isEmpty) return 'Bitte gib einen Namen ein.';
    if (_trimmedName.length > 64) return 'Höchstens 64 Zeichen.';
    return null;
  }

  String get _folderPreview {
    final folder = _trimmedFolder.replaceAll('\\', '/');
    if (folder.isNotEmpty) return folder.split('/').where((p) => p.isNotEmpty).join('/');
    return _trimmedName.isEmpty ? '…' : _folderFromName(_trimmedName);
  }

  void _setMediaType(String type) {
    setState(() {
      _mediaType = type;
      if (!_iconTouched) _icon = type == 'video' ? 'movie' : 'music_note';
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _submitted = true);
    if (_nameError != null || _validateFolder(_trimmedFolder) != null) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final category = await api.createCategory(
        name: _trimmedName,
        mediaType: _mediaType,
        folder: _trimmedFolder.isEmpty ? null : _trimmedFolder,
        icon: _icon,
      );
      if (!mounted) return;
      _invalidateCategories(ref);
      Navigator.of(context).pop(category);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final folderError = _validateFolder(_trimmedFolder);
    return AdminSheet(
      title: 'Rubrik anlegen',
      subtitle: 'Eine Rubrik ist ein eigener Bereich in der App – mit eigenem Ordner auf dem Server.',
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 64,
          enabled: !_busy,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'z. B. Kinderlieder',
            prefixIcon: const Icon(Icons.label_outline_rounded),
            errorText: _submitted ? _nameError : null,
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        const Text('Inhalt', style: AppText.tileTitle),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'audio', label: Text('Audio'), icon: Icon(Icons.graphic_eq_rounded)),
            ButtonSegment(value: 'video', label: Text('Video'), icon: Icon(Icons.videocam_rounded)),
          ],
          selected: {_mediaType},
          showSelectedIcon: false,
          onSelectionChanged: _busy ? null : (selection) => _setMediaType(selection.first),
          style: SegmentedButton.styleFrom(
            foregroundColor: Colors.white,
            selectedForegroundColor: Colors.black,
            selectedBackgroundColor: AppColors.accent,
            side: const BorderSide(color: AppColors.textMuted),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _mediaType == 'video'
              ? 'Für Musikvideos, Filme und Konzerte – wird im Video-Player abgespielt.'
              : 'Für Musik, Hörspiele und Hörbücher.',
          style: AppText.caption,
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _folder,
          maxLength: 255,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Ordner (optional)',
            hintText: 'leer = aus dem Namen',
            prefixIcon: const Icon(Icons.folder_outlined),
            errorText: folderError,
            helperText: 'Wird angelegt unter /media/$_folderPreview',
            helperMaxLines: 2,
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 18),
        const Text('Symbol', style: AppText.tileTitle),
        const SizedBox(height: 10),
        AdminIconPicker(
          selected: _icon,
          onChanged: _busy
              ? null
              : (icon) => setState(() {
                    _icon = icon;
                    _iconTouched = true;
                  }),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          AdminNotice(_error!),
        ],
        const SizedBox(height: 24),
        AdminPrimaryButton(
          label: 'Rubrik anlegen',
          icon: Icons.create_new_folder_rounded,
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 10),
        const Text(
          'Der Ordner wird sofort angelegt. Liegen dort schon Dateien, werden sie gleich eingelesen.',
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Liste der Rubriken zur Auswahl (z. B. „Nur eine Rubrik einlesen“). Liefert die gewählte Rubrik.
Future<Category?> pickAdminCategory(BuildContext context, {required String title, String? subtitle}) {
  return showAdminSheet<Category>(context, (_) => _CategoryPickerSheet(title: title, subtitle: subtitle));
}

class _CategoryPickerSheet extends ConsumerWidget {
  final String title;
  final String? subtitle;
  const _CategoryPickerSheet({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(categoriesProvider);
    return AdminSheet(
      title: title,
      subtitle: subtitle,
      children: [
        value.when(
          skipLoadingOnRefresh: true,
          skipLoadingOnReload: true,
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SizedBox(
            height: 220,
            child: ErrorView(message: errorText(error), onRetry: () => ref.invalidate(categoriesProvider)),
          ),
          data: (categories) {
            if (categories.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Es gibt noch keine Rubriken.', style: AppText.tileSubtitle, textAlign: TextAlign.center),
              );
            }
            return Column(
              children: [
                for (final category in categories)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: _CategoryIconBox(category: category, size: 44),
                    title: Text(category.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${_mediaLabel(category)} · ${_itemCountLabel(category)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).pop(category),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
