import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/library.dart';

// Bausteine für Anmeldung, Einstellungen und Geräteverwaltung.

/// Überschrift eines Abschnitts in den Einstellungen.
class AccountSectionTitle extends StatelessWidget {
  final String title;
  const AccountSectionTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 6),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Eintrag in den Einstellungen (Symbol, Titel, Untertitel).
class AccountTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool danger;
  final bool chevron;

  const AccountTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.danger = false,
    this.chevron = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : Colors.white;
    return ListTile(
      leading: Icon(icon, color: danger ? AppColors.danger : AppColors.textSecondary),
      title: Text(
        title,
        style: AppText.tileTitle.copyWith(color: color, fontSize: 16),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppText.tileSubtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing ??
          (chevron ? const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary) : null),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// Schalter in den Einstellungen.
class AccountSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const AccountSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(icon, color: AppColors.textSecondary),
      title: Text(
        title,
        style: AppText.tileTitle.copyWith(fontSize: 16),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppText.tileSubtitle, maxLines: 3, overflow: TextOverflow.ellipsis),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Hinweis-Kasten (Info oder Fehler).
class AccountNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool error;

  const AccountNotice({super.key, required this.text, this.icon = Icons.info_outline_rounded, this.error = false});

  const AccountNotice.error(this.text, {super.key})
      : icon = Icons.error_outline_rounded,
        error = true;

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.danger : Colors.white;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: error ? AppColors.danger.withValues(alpha: 0.14) : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: error ? AppColors.danger.withValues(alpha: 0.5) : AppColors.surfaceHighest),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: error ? const Color(0xFFFFC2C8) : Colors.white, fontSize: 14, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Großer grüner Knopf mit Ladeanzeige.
class AccountButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  const AccountButton({super.key, required this.label, required this.onPressed, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          disabledBackgroundColor: AppColors.accent.withValues(alpha: loading ? 0.75 : 0.35),
          disabledForegroundColor: Colors.black,
        ),
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
              )
            : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

// ------------------------------------------------------------------ Profilbild

const _avatarColors = [
  Color(0xFFE8115B),
  Color(0xFF1E3264),
  Color(0xFF8D67AB),
  Color(0xFFE13300),
  Color(0xFF148A08),
  Color(0xFF509BF5),
  Color(0xFFBA5D07),
  Color(0xFF477D95),
  Color(0xFFAF2896),
  Color(0xFF27856A),
];

/// Feste Farbe pro Benutzer (immer gleich für denselben Namen).
Color avatarColor(String seed) {
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _avatarColors[hash % _avatarColors.length];
}

/// Runder Kreis mit dem Anfangsbuchstaben des Namens.
class AccountAvatar extends StatelessWidget {
  final String name;
  final String seed;
  final double size;

  const AccountAvatar({super.key, required this.name, required this.seed, this.size = 64});

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: avatarColor(seed),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: Text(
        initial,
        style: TextStyle(fontSize: size * 0.44, fontWeight: FontWeight.w800, color: Colors.white),
      ),
    );
  }
}

// ------------------------------------------------------------------ Auswahl

/// Eine Möglichkeit in [showAccountChoiceSheet].
class AccountChoice<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;

  const AccountChoice({required this.value, required this.label, this.subtitle, this.icon});
}

/// Auswahl von unten (wie bei Spotify). Liefert die gewählte Möglichkeit –
/// oder null, wenn das Blatt ohne Auswahl geschlossen wurde. Der Wert darf selbst null sein.
Future<({T value})?> showAccountChoiceSheet<T>(
  BuildContext context, {
  required String title,
  String? message,
  required List<AccountChoice<T>> options,
  required T selected,
}) {
  return showModalBottomSheet<({T value})>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    builder: (context) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, message == null ? 12 : 4),
            child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(message, style: AppText.tileSubtitle),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                for (final option in options)
                  _ChoiceTile(
                    option: option,
                    selected: option.value == selected,
                    onTap: () => Navigator.pop(context, (value: option.value)),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ChoiceTile<T> extends StatelessWidget {
  final AccountChoice<T> option;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceTile({required this.option, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: option.icon == null
          ? null
          : Icon(option.icon, color: selected ? AppColors.accent : AppColors.textSecondary),
      title: Text(
        option.label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 16,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? AppColors.accent : Colors.white,
        ),
      ),
      subtitle: option.subtitle == null
          ? null
          : Text(option.subtitle!, style: AppText.tileSubtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: selected ? const Icon(Icons.check_rounded, color: AppColors.accent) : null,
      onTap: onTap,
    );
  }
}

// ------------------------------------------------------------------ Rubriken

/// Material-Symbol zum Symbolnamen einer Rubrik (vom Server, z. B. "music_note").
IconData categoryIcon(Category category) {
  return switch (category.icon) {
    'music_note' => Icons.music_note_rounded,
    'music_video' => Icons.music_video_rounded,
    'auto_stories' => Icons.auto_stories_rounded,
    'movie' => Icons.movie_rounded,
    'library_music' => Icons.library_music_rounded,
    'video_library' => Icons.video_library_rounded,
    'headphones' || 'headset' => Icons.headphones_rounded,
    'mic' || 'podcasts' => Icons.podcasts_rounded,
    'child_care' || 'child_friendly' || 'toys' => Icons.child_care_rounded,
    'menu_book' || 'book' => Icons.menu_book_rounded,
    'piano' => Icons.piano_rounded,
    'theaters' => Icons.theaters_rounded,
    'tv' || 'live_tv' => Icons.live_tv_rounded,
    'star' => Icons.star_rounded,
    'favorite' => Icons.favorite_rounded,
    'nightlight' || 'bedtime' => Icons.bedtime_rounded,
    'school' => Icons.school_rounded,
    'sports_esports' => Icons.sports_esports_rounded,
    'folder' => category.isVideo ? Icons.video_library_rounded : Icons.folder_rounded,
    _ => category.isVideo ? Icons.movie_rounded : Icons.library_music_rounded,
  };
}

/// "12 Songs" bzw. "3 Videos".
String categoryCount(Category category) {
  final n = category.itemCount;
  if (category.isVideo) return n == 1 ? '1 Video' : '$n Videos';
  return n == 1 ? '1 Titel' : '$n Titel';
}

// ------------------------------------------------------------------ Geräte

final _tabletPattern = RegExp(r'ipad|tablet|\btab\b|galaxy[ _-]?tab|kindle|silk/|nexus (7|9|10)');
final _phonePattern = RegExp(r'iphone|ipod|android|mobile|handy|phone|pixel|galaxy');
final _computerPattern =
    RegExp(r'windows|macintosh|mac os|macos|linux|x11|cros|desktop|laptop|computer|\bpc\b|notebook|imac|macbook');

/// Symbol (Handy, Tablet, Computer) – geraten aus Gerätename und Browser-Kennung.
IconData deviceIcon(DeviceSession session) {
  // Die App meldet sich auf Apple-Geräten als "iPhone/iPad · <Gerätename>"
  final name = session.deviceName.toLowerCase().replaceAll('iphone/ipad', ' ');
  final agent = session.userAgent.toLowerCase();
  final all = '$name $agent';
  final androidBrowserTablet = agent.contains('android') && agent.contains('mozilla') && !agent.contains('mobile');
  if (_tabletPattern.hasMatch(all) || androidBrowserTablet) return Icons.tablet_mac_rounded;
  if (_phonePattern.hasMatch(all)) return Icons.smartphone_rounded;
  if (_computerPattern.hasMatch(all)) return Icons.computer_rounded;
  if (agent.contains('mozilla')) return Icons.language_rounded;
  if (agent.startsWith('dart/') || session.deviceName.toLowerCase().contains('iphone/ipad')) {
    return Icons.smartphone_rounded;
  }
  return Icons.devices_other_rounded;
}

/// Womit angemeldet wurde, z. B. "Selfify-App" oder "Firefox unter Windows" (null = unbekannt).
String? deviceClient(DeviceSession session) {
  final agent = session.userAgent.trim();
  if (agent.isEmpty) return null;
  final ua = agent.toLowerCase();
  if (ua.startsWith('dart/') || ua.contains('dart:io')) return 'Selfify-App';
  final browser = switch (ua) {
    _ when ua.contains('edg/') || ua.contains('edga/') || ua.contains('edgios/') => 'Edge',
    _ when ua.contains('opr/') || ua.contains('opera') => 'Opera',
    _ when ua.contains('samsungbrowser/') => 'Samsung Internet',
    _ when ua.contains('firefox/') || ua.contains('fxios/') => 'Firefox',
    _ when ua.contains('chrome/') || ua.contains('crios/') || ua.contains('chromium/') => 'Chrome',
    _ when ua.contains('safari/') => 'Safari',
    _ => null,
  };
  if (browser == null) {
    // z. B. "curl/8.5" -> "curl"
    final first = agent.split(RegExp(r'[\s/]')).first;
    return first.length > 40 ? '${first.substring(0, 40)}…' : first;
  }
  final system = switch (ua) {
    _ when ua.contains('iphone') || ua.contains('ipad') || ua.contains('ipod') => 'iOS',
    _ when ua.contains('android') => 'Android',
    _ when ua.contains('windows') => 'Windows',
    _ when ua.contains('cros') => 'ChromeOS',
    _ when ua.contains('macintosh') || ua.contains('mac os') => 'macOS',
    _ when ua.contains('linux') => 'Linux',
    _ => null,
  };
  return system == null ? browser : '$browser unter $system';
}

// ------------------------------------------------------------------ Passwort

/// Dialog "Passwort ändern" – ändert das Passwort direkt. Liefert true bei Erfolg.
Future<bool> showChangePasswordDialog(BuildContext context, ApiClient api) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ChangePasswordDialog(api: api),
  );
  return result ?? false;
}

class _ChangePasswordDialog extends StatefulWidget {
  final ApiClient api;
  const _ChangePasswordDialog({required this.api});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  final _nextFocus = FocusNode();
  final _repeatFocus = FocusNode();
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    _nextFocus.dispose();
    _repeatFocus.dispose();
    super.dispose();
  }

  String? _validate() {
    final current = _current.text;
    final next = _next.text;
    if (current.isEmpty) return 'Bitte gib dein aktuelles Passwort ein.';
    if (next.length < 8) return 'Das neue Passwort muss mindestens 8 Zeichen lang sein.';
    if (next.length > 128) return 'Das neue Passwort darf höchstens 128 Zeichen lang sein.';
    if (next != _repeat.text) return 'Die beiden neuen Passwörter stimmen nicht überein.';
    if (next == current) return 'Das neue Passwort muss sich vom aktuellen unterscheiden.';
    return null;
  }

  Future<void> _submit() async {
    if (_saving) return;
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.changePassword(_current.text, _next.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = errorText(e);
      });
    }
  }

  InputDecoration _decoration(String label, {String? helper, Widget? suffix}) => InputDecoration(
        labelText: label,
        helperText: helper,
        helperStyle: AppText.caption,
        suffixIcon: suffix,
        floatingLabelStyle: const TextStyle(color: AppColors.accent),
      );

  @override
  Widget build(BuildContext context) {
    final toggle = IconButton(
      tooltip: _obscure ? 'Passwörter anzeigen' : 'Passwörter verbergen',
      icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded, color: AppColors.textSecondary),
      onPressed: () => setState(() => _obscure = !_obscure),
    );
    return AlertDialog(
      title: const Text('Passwort ändern'),
      scrollable: true,
      content: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Danach werden alle anderen Geräte abgemeldet. Auf diesem Gerät bleibst du angemeldet.',
              style: AppText.tileSubtitle,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _current,
              enabled: !_saving,
              autofocus: true,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _nextFocus.requestFocus(),
              decoration: _decoration('Aktuelles Passwort', suffix: toggle),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _next,
              focusNode: _nextFocus,
              enabled: !_saving,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _repeatFocus.requestFocus(),
              decoration: _decoration('Neues Passwort', helper: 'Mindestens 8 Zeichen'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _repeat,
              focusNode: _repeatFocus,
              enabled: !_saving,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: _decoration('Neues Passwort wiederholen'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              AccountNotice.error(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Abbrechen', style: TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Ändern', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
