import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/app_update.dart';
import '../../data/models.dart';
import '../../state/app_update.dart';
import '../../state/auth.dart';
import '../../state/downloads.dart';
import '../../state/library.dart';
import '../../state/offline.dart';
import '../../state/settings.dart';
import '../nav.dart';
import '../widgets/app_update.dart';
import '../widgets/common.dart';
import 'account_widgets.dart';
import 'devices_screen.dart';

final _serverInfoProvider = FutureProvider.autoDispose<ServerInfo>((ref) => requireApi(ref).serverInfo());

final _packageInfoProvider = FutureProvider<PackageInfo>((ref) => PackageInfo.fromPlatform());

/// Alle Stufen (inkl. "low") fürs Streamen, ohne "low" für Downloads.
final _streamingQualities = qualityLabels.keys.toList();
final _offlineQualities = _streamingQualities.where((key) => key != 'low').toList();

String _qualityLabel(String key) => qualityLabels[key] ?? key;

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Update-Prüfung läuft gerade (verhindert zwei Dialoge bei Doppeltipp).
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    // Rechte (Downloads, Admin) können sich geändert haben -> Konto neu laden
    Future.microtask(_refreshUser);
    // Gelöschte Rubriken nicht weiter als Download-Ziel verwenden
    ref.listenManual(
      categoriesProvider,
      (_, next) => Future.microtask(() {
        if (mounted) _dropMissingCategories(next.value);
      }),
      fireImmediately: true,
    );
  }

  Future<void> _refreshUser() async {
    try {
      await ref.read(authProvider.notifier).refreshUser();
    } catch (_) {
      // offline o. Ä. – die gespeicherten Kontodaten bleiben gültig
    }
  }

  Future<void> _quietly(Future<Object?> future) async {
    try {
      await future;
    } catch (_) {
      // Fehler werden in der jeweiligen Zeile angezeigt
    }
  }

  Future<void> _refresh() async {
    await Future.wait([
      _refreshUser(),
      _quietly(ref.refresh(_serverInfoProvider.future)),
      _quietly(ref.refresh(categoriesProvider.future)),
    ]);
  }

  void _dropMissingCategories(List<Category>? categories) {
    if (categories == null) return;
    final settings = ref.read(settingsProvider);
    bool missing(int? id, String type) => id != null && !categories.any((c) => c.id == id && c.mediaType == type);
    final audioMissing = missing(settings.audioCategoryId, 'audio');
    final videoMissing = missing(settings.videoCategoryId, 'video');
    if (!audioMissing && !videoMissing) return;
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(
          audioCategoryId: audioMissing ? () => null : null,
          videoCategoryId: videoMissing ? () => null : null,
        ));
  }

  // ---------------------------------------------------------------- Konto

  Future<void> _editName(User user) async {
    final name = await promptText(
      context,
      title: 'Anzeigename ändern',
      initial: user.displayName,
      hint: 'So sehen dich die anderen',
    );
    if (name == null || !mounted) return;
    if (name.isEmpty) {
      showMessage(context, 'Der Name darf nicht leer sein.');
      return;
    }
    if (name.length > 64) {
      showMessage(context, 'Der Name darf höchstens 64 Zeichen lang sein.');
      return;
    }
    if (name == user.displayName) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      final updated = await api.updateMe(displayName: name);
      ref.read(authProvider.notifier).replaceUser(updated);
      // Der Name steht z. B. bei Playlists ("Von …")
      ref.invalidate(myPlaylistsProvider);
      ref.invalidate(familyPlaylistsProvider);
      ref.invalidate(libraryOverviewProvider);
      ref.invalidate(homeProvider);
      if (mounted) showMessage(context, 'Dein Name wurde geändert');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _changePassword() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final changed = await showChangePasswordDialog(context, api);
    if (!changed || !mounted) return;
    ref.invalidate(deviceSessionsProvider);
    showMessage(context, 'Passwort geändert. Alle anderen Geräte wurden abgemeldet.');
  }

  Future<void> _logout(User user) async {
    final ok = await confirm(
      context,
      title: 'Abmelden?',
      message: 'Du wirst auf diesem Gerät als @${user.username} abgemeldet. '
          'Musik auf diesem Gerät bleibt erhalten.',
      confirmLabel: 'Abmelden',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(authProvider.notifier).logout();
    // Der Router wechselt automatisch zur Anmeldung.
  }

  // ---------------------------------------------------------------- Wiedergabe & Offline

  Future<String?> _pickQuality({
    required String title,
    String? message,
    required List<String> keys,
    required String selected,
  }) async {
    final choice = await showAccountChoiceSheet<String>(
      context,
      title: title,
      message: message,
      selected: selected,
      options: [
        for (final key in keys)
          AccountChoice(
            value: key,
            label: _qualityLabel(key),
            icon: switch (key) {
              'original' => Icons.high_quality_rounded,
              'high' => Icons.graphic_eq_rounded,
              'normal' => Icons.music_note_rounded,
              _ => Icons.data_saver_on_rounded,
            },
          ),
      ],
    );
    return choice?.value;
  }

  Future<void> _pickWifiQuality(AppSettings settings) async {
    final value = await _pickQuality(
      title: 'Streaming-Qualität im WLAN',
      message: 'Gilt, wenn du im WLAN bist.',
      keys: _streamingQualities,
      selected: settings.wifiQuality,
    );
    if (value != null) await ref.read(settingsProvider.notifier).update((s) => s.copyWith(wifiQuality: value));
  }

  Future<void> _pickMobileQuality(AppSettings settings) async {
    final value = await _pickQuality(
      title: 'Streaming-Qualität über mobile Daten',
      message: 'Eine niedrigere Qualität spart Datenvolumen.',
      keys: _streamingQualities,
      selected: settings.mobileQuality,
    );
    if (value != null) await ref.read(settingsProvider.notifier).update((s) => s.copyWith(mobileQuality: value));
  }

  Future<void> _pickOfflineQuality(AppSettings settings) async {
    final value = await _pickQuality(
      title: 'Qualität auf diesem Gerät',
      message: 'Gilt für Songs, die neu aufs Gerät geladen werden. Songs, die schon auf diesem Gerät sind, bleiben, wie sie sind.',
      keys: _offlineQualities,
      selected: _offlineQualities.contains(settings.offlineQuality) ? settings.offlineQuality : 'original',
    );
    if (value != null) await ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineQuality: value));
  }

  Future<void> _setWifiOnly(bool value) async {
    // Der Offline-Speicher startet wartende Downloads selbst, sobald mobile Daten erlaubt sind
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineWifiOnly: value));
  }

  // ---------------------------------------------------------------- YouTube-Downloads

  Future<void> _pickVideoFetch(AppSettings settings) async {
    final choice = await showAccountChoiceSheet<String>(
      context,
      title: 'YouTube-Videos holen als',
      message: 'Gilt für „Holen“ auf diesem Gerät. Im Menü eines Videos geht weiterhin beides.',
      selected: settings.videoFetch,
      options: [
        AccountChoice(
          value: 'ask',
          label: videoFetchLabels['ask']!,
          subtitle: 'Musik oder Video wählen',
          icon: Icons.help_outline_rounded,
        ),
        AccountChoice(
          value: 'audio',
          label: videoFetchLabels['audio']!,
          subtitle: 'Nur den Ton – als Song, viel kleiner',
          icon: Icons.music_note_rounded,
        ),
        AccountChoice(
          value: 'video',
          label: videoFetchLabels['video']!,
          subtitle: 'Mit Bild – bei den Videos',
          icon: Icons.movie_rounded,
        ),
      ],
    );
    if (choice == null) return;
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(videoFetch: choice.value));
  }

  Future<void> _pickCategory(String mediaType) async {
    final List<Category> categories;
    try {
      categories = await ref.read(categoriesProvider.future);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final matching = categories.where((c) => c.mediaType == mediaType).toList()
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final fallback = matching.where((c) => c.isDefault).firstOrNull;
    final settings = ref.read(settingsProvider);
    final current = mediaType == 'audio' ? settings.audioCategoryId : settings.videoCategoryId;
    final selected = matching.any((c) => c.id == current) ? current : null;
    final isAudio = mediaType == 'audio';

    final choice = await showAccountChoiceSheet<int?>(
      context,
      title: isAudio ? 'Ziel-Rubrik für Musik' : 'Ziel-Rubrik für Videos',
      message: isAudio
          ? 'Hier landen Songs und Alben, die du von YouTube herunterlädst.'
          : 'Hier landen Videos, die du von YouTube herunterlädst.',
      selected: selected,
      options: [
        AccountChoice<int?>(
          value: null,
          label: 'Server-Standard',
          subtitle: fallback == null ? 'Wie auf dem Server eingestellt' : 'Zurzeit „${fallback.name}“',
          icon: Icons.dns_rounded,
        ),
        for (final category in matching)
          AccountChoice<int?>(
            value: category.id,
            label: category.name,
            subtitle: categoryCount(category),
            icon: categoryIcon(category),
          ),
      ],
    );
    if (choice == null) return;
    await ref.read(settingsProvider.notifier).update((s) => isAudio
        ? s.copyWith(audioCategoryId: () => choice.value)
        : s.copyWith(videoCategoryId: () => choice.value));
  }

  String _categorySubtitle(AsyncValue<List<Category>> categories, int? id, String mediaType) {
    final list = categories.value;
    if (list == null) {
      if (categories.hasError) return id == null ? 'Server-Standard' : 'Rubriken gerade nicht verfügbar';
      return 'Wird geladen …';
    }
    if (id != null) {
      final match = list.where((c) => c.id == id && c.mediaType == mediaType).firstOrNull;
      if (match != null) return match.name;
    }
    final fallback = list.where((c) => c.isDefault && c.mediaType == mediaType).firstOrNull;
    return fallback == null ? 'Server-Standard' : 'Server-Standard („${fallback.name}“)';
  }

  // ---------------------------------------------------------------- Verlauf

  Future<void> _clearHistory() async {
    final ok = await confirm(
      context,
      title: 'Hörverlauf löschen?',
      message: '„Zuletzt gehört“ und deine Empfehlungen auf der Startseite werden zurückgesetzt. '
          'Das kann nicht rückgängig gemacht werden.',
      confirmLabel: 'Löschen',
      danger: true,
    );
    if (!ok || !mounted) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      await api.clearHistory();
      ref.invalidate(homeProvider);
      ref.invalidate(recentProvider);
      ref.invalidate(historyProvider);
      if (mounted) showMessage(context, 'Dein Hörverlauf wurde gelöscht');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  // ---------------------------------------------------------------- Über

  Future<void> _copyServerUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) showMessage(context, 'Adresse kopiert');
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider).value;
    final user = ref.watch(currentUserProvider);
    final settings = ref.watch(settingsProvider);

    if (user == null) {
      // Gerade abgemeldet – der Router wechselt gleich zur Anmeldung.
      return Scaffold(appBar: AppBar(title: const Text('Einstellungen')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            _ProfileHeader(user: user, onEdit: () => _editName(user)),
            ..._accountSection(user),
            ..._playbackSection(settings),
            ..._offlineSection(settings),
            ..._downloadSection(user, settings),
            ..._historySection(),
            if (user.isAdmin) ..._adminSection(),
            ..._aboutSection(auth?.serverUrl),
            const _Footer(),
          ],
        ),
      ),
    );
  }

  List<Widget> _accountSection(User user) => [
        const AccountSectionTitle('Konto'),
        AccountTile(
          icon: Icons.badge_outlined,
          title: 'Anzeigename ändern',
          subtitle: user.displayName,
          onTap: () => _editName(user),
        ),
        AccountTile(
          icon: Icons.lock_outline_rounded,
          title: 'Passwort ändern',
          subtitle: 'Danach werden alle anderen Geräte abgemeldet',
          onTap: _changePassword,
        ),
        AccountTile(
          icon: Icons.devices_rounded,
          title: 'Angemeldete Geräte',
          subtitle: 'Sieh nach, wo du angemeldet bist',
          chevron: true,
          onTap: () => Nav.devices(context),
        ),
        AccountTile(
          icon: Icons.logout_rounded,
          title: 'Abmelden',
          subtitle: 'Angemeldet als @${user.username}',
          danger: true,
          onTap: () => _logout(user),
        ),
      ];

  List<Widget> _playbackSection(AppSettings settings) => [
        const AccountSectionTitle('Wiedergabe'),
        AccountTile(
          icon: Icons.wifi_rounded,
          title: 'Streaming-Qualität im WLAN',
          subtitle: _qualityLabel(settings.wifiQuality),
          onTap: () => _pickWifiQuality(settings),
        ),
        AccountTile(
          icon: Icons.signal_cellular_alt_rounded,
          title: 'Streaming-Qualität über mobile Daten',
          subtitle: _qualityLabel(settings.mobileQuality),
          onTap: () => _pickMobileQuality(settings),
        ),
        AccountSwitchTile(
          icon: Icons.all_inclusive_rounded,
          title: 'Autoplay',
          subtitle: 'Wenn die Warteschlange endet, passende Songs weiterspielen',
          value: settings.autoplay,
          onChanged: (value) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(autoplay: value)),
        ),
      ];

  List<Widget> _offlineSection(AppSettings settings) {
    final offline = ref.watch(offlineProvider);
    final count = offline.tracks.length;
    final pending = offline.pending.length;
    final String storage;
    if (!offline.loaded) {
      storage = 'Wird geladen …';
    } else if (count == 0) {
      storage = pending > 0 ? 'Wird aufs Gerät geladen …' : 'Noch nichts auf diesem Gerät';
    } else {
      storage = '${pluralSongs(count)} · ${formatBytes(offline.totalBytes)} belegt';
    }
    final subtitle = pending > 0 && count > 0 ? '$storage · $pending in der Warteschlange' : storage;

    return [
      const AccountSectionTitle('Offline'),
      AccountSwitchTile(
        icon: Icons.cloud_off_rounded,
        title: 'Offline-Modus',
        subtitle: 'Nur Musik auf diesem Gerät anzeigen und abspielen',
        value: settings.offlineMode,
        onChanged: (value) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineMode: value)),
      ),
      AccountTile(
        icon: Icons.high_quality_rounded,
        title: 'Qualität auf diesem Gerät',
        subtitle: _qualityLabel(settings.offlineQuality),
        onTap: () => _pickOfflineQuality(settings),
      ),
      AccountSwitchTile(
        icon: Icons.network_wifi_rounded,
        title: 'Nur im WLAN aufs Gerät laden',
        subtitle: 'Spart dein mobiles Datenvolumen',
        value: settings.offlineWifiOnly,
        onChanged: _setWifiOnly,
      ),
      AccountTile(
        icon: Icons.download_for_offline_rounded,
        title: 'Auf diesem Gerät',
        subtitle: subtitle,
        chevron: true,
        onTap: () => Nav.offline(context),
      ),
    ];
  }

  List<Widget> _downloadSection(User user, AppSettings settings) {
    final active = ref.watch(activeDownloadCountProvider);
    final categories = ref.watch(categoriesProvider);
    return [
      const AccountSectionTitle('YouTube-Downloads'),
      if (!user.canDownload)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: AccountNotice(
            icon: Icons.lock_outline_rounded,
            text: 'Downloads sind für dein Konto nicht freigeschaltet. '
                'Frag die Person, die euren Selfify-Server verwaltet.',
          ),
        )
      else ...[
        AccountTile(
          icon: Icons.smart_display_rounded,
          title: 'YouTube-Videos holen als',
          subtitle: videoFetchLabels[settings.videoFetch] ?? videoFetchLabels['ask'],
          onTap: () => _pickVideoFetch(settings),
        ),
        AccountTile(
          icon: Icons.library_music_rounded,
          title: 'Ziel-Rubrik für Musik',
          subtitle: _categorySubtitle(categories, settings.audioCategoryId, 'audio'),
          onTap: () => _pickCategory('audio'),
        ),
        AccountTile(
          icon: Icons.video_library_rounded,
          title: 'Ziel-Rubrik für Videos',
          subtitle: _categorySubtitle(categories, settings.videoCategoryId, 'video'),
          onTap: () => _pickCategory('video'),
        ),
      ],
      AccountTile(
        icon: Icons.downloading_rounded,
        title: 'Meine Downloads',
        subtitle: active > 0
            ? (active == 1 ? '1 Download läuft gerade' : '$active Downloads laufen gerade')
            : 'Fortschritt und fertige Downloads',
        chevron: true,
        onTap: () => Nav.downloads(context),
      ),
    ];
  }

  List<Widget> _historySection() => [
        const AccountSectionTitle('Verlauf'),
        AccountTile(
          icon: Icons.history_rounded,
          title: 'Hörverlauf löschen',
          subtitle: '„Zuletzt gehört“ und Empfehlungen zurücksetzen',
          onTap: _clearHistory,
        ),
      ];

  List<Widget> _adminSection() => [
        const AccountSectionTitle('Verwaltung'),
        AccountTile(
          icon: Icons.admin_panel_settings_rounded,
          title: 'Admin-Bereich',
          subtitle: 'Benutzer, Rubriken, Bibliothek und Downloader verwalten',
          chevron: true,
          onTap: () => Nav.admin(context),
        ),
      ];

  /// „Nach Updates suchen“ – zeigt eine neuere Version an und installiert sie auf Tippen.
  Widget _updateTile() {
    final update = ref.watch(availableUpdateProvider);
    final release = update.value;
    return AccountTile(
      icon: Icons.system_update_rounded,
      title: release == null ? 'Nach Updates suchen' : 'Update installieren',
      subtitle: switch (update) {
        AsyncValue(isLoading: true) => 'Wird geprüft …',
        AsyncValue(value: final r?) => 'Neu: ${r.label}',
        AsyncValue(hasError: true) => 'Prüfung fehlgeschlagen – tippen, um es erneut zu versuchen',
        _ => 'Du hast die neueste Version',
      },
      onTap: () async {
        if (_checkingUpdate) return; // Doppeltipp: nur ein Dialog
        _checkingUpdate = true;
        try {
          // immer frisch prüfen – eine gemerkte Version kann inzwischen überholt sein
          final AppRelease? found;
          try {
            found = await ref.read(availableUpdateProvider.notifier).refresh();
          } catch (_) {
            if (mounted) showMessage(context, 'Prüfung fehlgeschlagen – bist du online?');
            return;
          }
          if (!mounted) return;
          if (found == null) {
            showMessage(context, 'Du hast die neueste Version.');
          } else {
            await showUpdateDialog(context, found);
          }
        } finally {
          _checkingUpdate = false;
        }
      },
    );
  }

  List<Widget> _aboutSection(String? serverUrl) {
    final server = ref.watch(_serverInfoProvider);
    final package = ref.watch(_packageInfoProvider);
    final serverText = switch (server) {
      AsyncValue(value: final info?) => '${info.name} · Version ${info.version}',
      AsyncValue(hasError: true) => 'Gerade nicht erreichbar – tippen, um es erneut zu versuchen',
      _ => 'Wird geladen …',
    };
    final appText = switch (package) {
      AsyncValue(value: final info?) =>
        info.buildNumber.isEmpty ? 'Version ${info.version}' : 'Version ${info.version} (Build ${info.buildNumber})',
      AsyncValue(hasError: true) => 'Unbekannt',
      _ => 'Wird geladen …',
    };
    return [
      const AccountSectionTitle('Über'),
      AccountTile(
        icon: Icons.dns_rounded,
        title: 'Server',
        subtitle: serverText,
        onTap: server.hasError && server.value == null ? () => ref.invalidate(_serverInfoProvider) : null,
      ),
      if (serverUrl != null)
        AccountTile(
          icon: Icons.link_rounded,
          title: 'Server-Adresse',
          subtitle: serverUrl,
          trailing: IconButton(
            tooltip: 'Adresse kopieren',
            icon: const Icon(Icons.copy_rounded, size: 20, color: AppColors.textSecondary),
            onPressed: () => _copyServerUrl(serverUrl),
          ),
          onLongPress: () => _copyServerUrl(serverUrl),
        ),
      AccountTile(
        icon: Icons.phone_iphone_rounded,
        title: 'App-Version',
        subtitle: appText,
      ),
      if (ref.watch(appUpdateSourceProvider).supported) _updateTile(),
      AccountTile(
        icon: Icons.description_outlined,
        title: 'Open-Source-Lizenzen',
        chevron: true,
        onTap: () => showLicensePage(
          context: context,
          applicationName: 'Selfify',
          applicationVersion: package.value?.version,
          applicationLegalese: 'Deine Musik. Dein Server.',
        ),
      ),
    ];
  }
}

/// Kopfbereich mit Profilbild, Name und Benutzername.
class _ProfileHeader extends StatelessWidget {
  final User user;
  final VoidCallback onEdit;

  const _ProfileHeader({required this.user, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final color = avatarColor(user.username);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [darken(color, 0.15).withValues(alpha: 0.55), AppColors.background],
        ),
      ),
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 8, 20),
          child: Row(
            children: [
              AccountAvatar(name: user.displayName, seed: user.username, size: 72),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${user.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
                    ),
                    if (user.isAdmin || !user.canDownload) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (user.isAdmin) const _Pill(label: 'Admin', icon: Icons.shield_rounded),
                          if (!user.canDownload) const _Pill(label: 'Nur hören', icon: Icons.headphones_rounded),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Anzeigename ändern',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData icon;
  const _Pill({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 32, 16, 0),
      child: Column(
        children: [
          Icon(Icons.graphic_eq_rounded, color: AppColors.textMuted, size: 28),
          SizedBox(height: 6),
          Text(
            'Selfify · Deine Musik. Dein Server.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
