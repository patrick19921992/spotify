import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../nav.dart';
import '../widgets/common.dart';
import 'admin_widgets.dart';

// Verwaltung › Benutzer: Konten anlegen, bearbeiten, sperren und löschen.

final _usersProvider = FutureProvider.autoDispose<List<User>>((ref) => requireApi(ref).users());

final _usernamePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{2,31}$');

String? _validateUsername(String? value) {
  final name = (value ?? '').trim().toLowerCase();
  if (name.isEmpty) return 'Bitte gib einen Benutzernamen ein.';
  if (name.length < 3 || name.length > 32) return 'Der Benutzername braucht 3 bis 32 Zeichen.';
  if (!_usernamePattern.hasMatch(name)) {
    return 'Erlaubt sind a–z, 0–9 sowie . _ - (am Anfang ein Buchstabe oder eine Ziffer).';
  }
  return null;
}

String? _validatePassword(String? value) {
  final password = value ?? '';
  if (password.length < 8) return 'Das Passwort braucht mindestens 8 Zeichen.';
  if (password.length > 128) return 'Das Passwort darf höchstens 128 Zeichen lang sein.';
  return null;
}

/// Kleinbuchstaben beim Tippen des Benutzernamens.
final _lowercase = TextInputFormatter.withFunction(
  (_, value) => value.copyWith(text: value.text.toLowerCase()),
);

const _avatarColors = [
  Color(0xFFE8115B),
  Color(0xFF1E3264),
  Color(0xFF8D67AB),
  Color(0xFF477D95),
  Color(0xFFBA5D07),
  Color(0xFF148A08),
  Color(0xFFE1118C),
  Color(0xFF503750),
];

/// Runder Avatar mit dem Anfangsbuchstaben des Namens.
class _UserAvatar extends StatelessWidget {
  final User user;
  final double radius;
  const _UserAvatar({required this.user, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    final name = user.displayName.trim().isNotEmpty ? user.displayName.trim() : user.username;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final color = _avatarColors[user.id.abs() % _avatarColors.length];
    return CircleAvatar(
      radius: radius,
      backgroundColor: user.isActive ? color : AppColors.surfaceHighest,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.85,
          fontWeight: FontWeight.w700,
          color: user.isActive ? Colors.white : AppColors.textMuted,
        ),
      ),
    );
  }
}

List<Widget> _userBadges(User user, {required bool isMe}) => [
      if (isMe) const AdminBadge(label: 'Du', color: AppColors.accent, icon: Icons.person_rounded),
      if (user.isAdmin)
        const AdminBadge(label: 'Admin', color: Colors.white, icon: Icons.admin_panel_settings_rounded),
      if (!user.isActive) const AdminBadge(label: 'Deaktiviert', color: AppColors.danger, icon: Icons.block_rounded),
      if (!user.canDownload)
        const AdminBadge(label: 'Kein Download', color: adminWarningColor, icon: Icons.file_download_off_rounded),
    ];

/// Tab „Benutzer“.
class AdminUsersTab extends ConsumerWidget {
  const AdminUsersTab({super.key});

  Future<void> _refresh(WidgetRef ref) => adminQuietly(ref.refresh(_usersProvider.future));

  Future<void> _open(BuildContext context, WidgetRef ref, User user) async {
    final result = await showAdminSheet<_EditResult>(context, (_) => _EditUserSheet(user: user));
    if (!context.mounted) return;
    ref.invalidate(_usersProvider);
    switch (result) {
      case _EditResult(openSettings: true):
        Nav.settings(context);
      case _EditResult(:final message?):
        showMessage(context, message);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(_usersProvider);
    final me = ref.watch(currentUserProvider);
    return AsyncBody<List<User>>(
      value: users,
      onRetry: () => ref.invalidate(_usersProvider),
      builder: (list) {
        final padding = adminListPadding(context, top: 8, bottom: 96, horizontal: 0);
        if (list.isEmpty) {
          return RefreshIndicator(
            color: AppColors.accent,
            onRefresh: () => _refresh(ref),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              children: const [
                SizedBox(height: 64),
                EmptyState(
                  icon: Icons.group_outlined,
                  title: 'Noch keine Benutzer',
                  message: 'Lege Konten für deine Familie an – jeder bekommt eigene Playlists und Lieblingssongs.',
                ),
              ],
            ),
          );
        }
        final admins = list.where((u) => u.isAdmin && u.isActive).length;
        final inactive = list.where((u) => !u.isActive).length;
        final summary = [
          list.length == 1 ? '1 Benutzer' : '${list.length} Benutzer',
          admins == 1 ? '1 Admin' : '$admins Admins',
          if (inactive > 0) '$inactive deaktiviert',
        ].join(' · ');
        return RefreshIndicator(
          color: AppColors.accent,
          onRefresh: () => _refresh(ref),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: padding,
            itemCount: list.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(summary, style: AppText.caption),
                );
              }
              final user = list[index - 1];
              return _UserTile(
                user: user,
                isMe: user.id == me?.id,
                onTap: () => _open(context, ref, user),
              );
            },
          ),
        );
      },
    );
  }
}

class _UserTile extends StatelessWidget {
  final User user;
  final bool isMe;
  final VoidCallback onTap;

  const _UserTile({required this.user, required this.isMe, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final badges = _userBadges(user, isMe: isMe);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _UserAvatar(user: user),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle.copyWith(
                      color: user.isActive ? Colors.white : AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('@${user.username}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
                  if (badges.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 4, children: badges),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Benutzer anlegen

/// Blatt „Benutzer anlegen“ (vom Plus-Knopf der Verwaltung).
Future<void> showCreateUserSheet(BuildContext context) async {
  final user = await showAdminSheet<User>(context, (_) => const _CreateUserSheet());
  if (user != null && context.mounted) {
    showMessage(context, '„${user.displayName}“ wurde angelegt – Anmeldung mit @${user.username}');
  }
}

class _CreateUserSheet extends ConsumerStatefulWidget {
  const _CreateUserSheet();

  @override
  ConsumerState<_CreateUserSheet> createState() => _CreateUserSheetState();
}

class _CreateUserSheetState extends ConsumerState<_CreateUserSheet> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _isAdmin = false;
  bool _canDownload = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final displayName = _displayName.text.trim();
      final user = await api.createUser(
        username: _username.text.trim().toLowerCase(),
        password: _password.text,
        displayName: displayName.isEmpty ? null : displayName,
        isAdmin: _isAdmin,
        canDownload: _canDownload,
      );
      if (!mounted) return;
      ref.invalidate(_usersProvider);
      Navigator.of(context).pop(user);
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
    final preview = _username.text.trim();
    final fallbackName = preview.isEmpty ? null : '${preview[0].toUpperCase()}${preview.substring(1)}';
    return AdminSheet(
      title: 'Benutzer anlegen',
      subtitle: 'Jeder bekommt eigene Playlists, Lieblingssongs und einen eigenen Verlauf.',
      children: [
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _username,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 32,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newUsername],
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9._-]')),
                    _lowercase,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Benutzername',
                    hintText: 'z. B. lena',
                    prefixIcon: Icon(Icons.alternate_email_rounded),
                    helperText: 'Zum Anmelden · 3–32 Zeichen: a–z, 0–9, . _ -',
                    counterText: '',
                  ),
                  validator: _validateUsername,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _displayName,
                  maxLength: 64,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  decoration: InputDecoration(
                    labelText: 'Anzeigename (optional)',
                    hintText: fallbackName ?? 'z. B. Lena',
                    prefixIcon: const Icon(Icons.badge_outlined),
                    helperText: fallbackName == null
                        ? 'So sehen ihn die anderen'
                        : 'Leer = „$fallbackName“',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 128,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: 'Passwort',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    helperText: 'Mindestens 8 Zeichen',
                    counterText: '',
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Passwort anzeigen' : 'Passwort verbergen',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: _validatePassword,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _isAdmin,
          onChanged: _busy ? null : (value) => setState(() => _isAdmin = value),
          secondary: const Icon(Icons.admin_panel_settings_outlined),
          title: const Text('Admin'),
          subtitle: const Text('Darf Benutzer, Rubriken und die Bibliothek verwalten', style: AppText.caption),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _canDownload,
          onChanged: _busy ? null : (value) => setState(() => _canDownload = value),
          secondary: const Icon(Icons.download_rounded),
          title: const Text('Darf YouTube-Downloads starten'),
          subtitle: const Text('Neue Songs und Videos von YouTube in die Bibliothek holen', style: AppText.caption),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          AdminNotice(_error!),
        ],
        const SizedBox(height: 20),
        AdminPrimaryButton(
          label: 'Benutzer anlegen',
          icon: Icons.person_add_alt_1_rounded,
          busy: _busy,
          onPressed: _submit,
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Benutzer bearbeiten

/// Ergebnis des Bearbeiten-Blatts: Meldung für die Liste oder „Einstellungen öffnen“.
class _EditResult {
  final String? message;
  final bool openSettings;
  const _EditResult({this.message, this.openSettings = false});
}

class _EditUserSheet extends ConsumerStatefulWidget {
  final User user;
  const _EditUserSheet({required this.user});

  @override
  ConsumerState<_EditUserSheet> createState() => _EditUserSheetState();
}

class _EditUserSheetState extends ConsumerState<_EditUserSheet> {
  late User _user = widget.user;
  bool _busy = false;
  String? _error;
  String? _info;

  bool get _isMe => ref.read(currentUserProvider)?.id == _user.id;

  /// Änderung an den Server schicken. Liefert true bei Erfolg.
  Future<bool> _update({
    String? displayName,
    String? password,
    bool? isAdmin,
    bool? isActive,
    bool? canDownload,
    String? success,
  }) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return false;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final updated = await api.updateUser(
        _user.id,
        displayName: displayName,
        password: password,
        isAdmin: isAdmin,
        isActive: isActive,
        canDownload: canDownload,
      );
      if (!mounted) return true;
      ref.invalidate(_usersProvider);
      if (updated.id == ref.read(currentUserProvider)?.id) {
        // Eigenes Konto: Name/Rechte in der App übernehmen
        ref.read(authProvider.notifier).replaceUser(updated);
        if (displayName != null) {
          ref.invalidate(myPlaylistsProvider);
          ref.invalidate(familyPlaylistsProvider);
          ref.invalidate(libraryOverviewProvider);
        }
      }
      setState(() {
        _user = updated;
        _busy = false;
        _info = success;
      });
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
      return false;
    }
  }

  Future<void> _rename() async {
    final name = await promptText(
      context,
      title: 'Anzeigename ändern',
      initial: _user.displayName,
      hint: 'So sehen ihn die anderen',
      maxLength: 64,
    );
    if (name == null || !mounted) return;
    if (name.isEmpty) {
      setState(() => _error = 'Der Name darf nicht leer sein.');
      return;
    }
    if (name == _user.displayName) return;
    await _update(displayName: name, success: 'Der Name wurde geändert.');
  }

  Future<void> _resetPassword() async {
    if (_isMe) {
      // Das eigene Passwort ändert man mit dem alten Passwort – sonst würde auch dieses Gerät abgemeldet.
      Navigator.of(context).pop(const _EditResult(openSettings: true));
      return;
    }
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _NewPasswordDialog(username: _user.username),
    );
    if (password == null || !mounted) return;
    await _update(
      password: password,
      success: 'Neues Passwort gespeichert. @${_user.username} wurde auf allen Geräten abgemeldet.',
    );
  }

  Future<void> _setAdmin(bool value) async {
    if (!value && _isMe) {
      final ok = await confirm(
        context,
        title: 'Admin-Rechte abgeben?',
        message: 'Du kannst danach keine Benutzer, Rubriken und die Bibliothek mehr verwalten. '
            'Nur ein anderer Admin kann dir die Rechte zurückgeben.',
        confirmLabel: 'Abgeben',
        danger: true,
      );
      if (!ok || !mounted) return;
      final done = await _update(isAdmin: false);
      if (done && mounted) Navigator.of(context).pop(const _EditResult(message: 'Du bist jetzt kein Admin mehr.'));
      return;
    }
    await _update(
      isAdmin: value,
      success: value ? '${_user.displayName} ist jetzt Admin.' : '${_user.displayName} ist kein Admin mehr.',
    );
  }

  Future<void> _setActive(bool value) async {
    if (!value) {
      final ok = await confirm(
        context,
        title: '„${_user.displayName}“ deaktivieren?',
        message: '@${_user.username} wird auf allen Geräten abgemeldet und kann sich nicht mehr anmelden, '
            'bis du das Konto wieder aktivierst. Playlists und Lieblingssongs bleiben erhalten.',
        confirmLabel: 'Deaktivieren',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    await _update(
      isActive: value,
      success: value ? 'Das Konto ist wieder aktiv.' : 'Das Konto ist deaktiviert.',
    );
  }

  Future<void> _setCanDownload(bool value) => _update(
        canDownload: value,
        success: value
            ? '${_user.displayName} darf jetzt YouTube-Downloads starten.'
            : '${_user.displayName} darf keine YouTube-Downloads mehr starten.',
      );

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: '„${_user.displayName}“ löschen?',
      message: 'Das Konto @${_user.username} wird mit seinen Playlists, Lieblingssongs und dem Verlauf gelöscht. '
          'Heruntergeladene Songs bleiben in der Bibliothek. Das kann nicht rückgängig gemacht werden.',
      confirmLabel: 'Löschen',
      danger: true,
    );
    if (!ok || !mounted) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await api.deleteUser(_user.id);
      if (!mounted) return;
      ref.invalidate(_usersProvider);
      // Playlists des Benutzers sind weg
      ref.invalidate(familyPlaylistsProvider);
      ref.invalidate(libraryOverviewProvider);
      ref.invalidate(homeProvider);
      Navigator.of(context).pop(_EditResult(message: '„${_user.displayName}“ wurde gelöscht.'));
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
    final me = ref.watch(currentUserProvider);
    final isMe = me?.id == _user.id;
    final user = _user;
    final lastLogin = user.lastLoginAt;
    final badges = _userBadges(user, isMe: isMe);
    return AdminSheet(
      title: user.displayName,
      subtitle: '@${user.username}',
      leading: _UserAvatar(user: user, radius: 28),
      children: [
        if (badges.isNotEmpty) ...[
          Wrap(spacing: 6, runSpacing: 4, children: badges),
          const SizedBox(height: 10),
        ],
        Text(
          [
            'Seit ${formatDate(user.createdAt)} dabei',
            lastLogin == null ? 'noch nie angemeldet' : 'zuletzt angemeldet ${formatRelative(lastLogin)}',
          ].join(' · '),
          style: AppText.caption,
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(minHeight: 2),
        ] else
          const SizedBox(height: 14),
        if (_error != null) ...[
          const SizedBox(height: 8),
          AdminNotice(_error!),
        ],
        if (_info != null) ...[
          const SizedBox(height: 8),
          AdminNotice(_info!, error: false),
        ],
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          enabled: !_busy,
          leading: const Icon(Icons.badge_outlined),
          title: const Text('Anzeigename'),
          subtitle: Text(user.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
          trailing: const Icon(Icons.edit_outlined, size: 20),
          onTap: _rename,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          enabled: !_busy,
          leading: const Icon(Icons.lock_reset_rounded),
          title: Text(isMe ? 'Passwort ändern' : 'Passwort zurücksetzen'),
          subtitle: Text(
            isMe
                ? 'Dein eigenes Passwort änderst du in den Einstellungen.'
                : 'Neues Passwort vergeben – meldet @${user.username} überall ab',
            style: AppText.caption,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _resetPassword,
        ),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: user.isAdmin,
          onChanged: _busy ? null : _setAdmin,
          secondary: const Icon(Icons.admin_panel_settings_outlined),
          title: const Text('Admin'),
          subtitle: const Text('Darf Benutzer, Rubriken und die Bibliothek verwalten', style: AppText.caption),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: user.isActive,
          onChanged: _busy || isMe ? null : _setActive,
          secondary: Icon(user.isActive ? Icons.how_to_reg_outlined : Icons.person_off_outlined),
          title: const Text('Konto aktiv'),
          subtitle: Text(
            isMe
                ? 'Du kannst dich nicht selbst deaktivieren.'
                : (user.isActive ? 'Kann sich anmelden und Musik hören' : 'Anmelden ist gesperrt'),
            style: AppText.caption,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: user.canDownload,
          onChanged: _busy ? null : _setCanDownload,
          secondary: Icon(user.canDownload ? Icons.download_rounded : Icons.file_download_off_rounded),
          title: const Text('Darf YouTube-Downloads starten'),
          subtitle: const Text('Neue Songs und Videos von YouTube in die Bibliothek holen', style: AppText.caption),
        ),
        const Divider(height: 24),
        if (isMe)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Dein eigenes Konto kannst du hier nicht löschen.', style: AppText.caption),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _delete,
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Benutzer löschen'),
            ),
          ),
      ],
    );
  }
}

/// Dialog „Neues Passwort“ (mit Anzeigen/Verbergen). Liefert das Passwort oder null.
class _NewPasswordDialog extends StatefulWidget {
  final String username;
  const _NewPasswordDialog({required this.username});

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Passwort zurücksetzen'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Neues Passwort für @${widget.username}. Danach wird @${widget.username} auf allen Geräten abgemeldet.',
              style: AppText.tileSubtitle,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _controller,
              autofocus: true,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 128,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: 'Neues Passwort',
                helperText: 'Mindestens 8 Zeichen',
                counterText: '',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Passwort anzeigen' : 'Passwort verbergen',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: _validatePassword,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
        TextButton(onPressed: _submit, child: const Text('Speichern')),
      ],
    );
  }
}
