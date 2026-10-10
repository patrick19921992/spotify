import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../widgets/common.dart';
import 'account_widgets.dart';

/// Angemeldete Geräte des eigenen Kontos – dieses Gerät zuerst, dann nach letzter Nutzung.
final deviceSessionsProvider = FutureProvider.autoDispose<List<DeviceSession>>((ref) async {
  final sessions = await requireApi(ref).sessions();
  return [...sessions]
    ..sort((a, b) {
      if (a.current != b.current) return a.current ? -1 : 1;
      return b.lastUsedAt.compareTo(a.lastUsedAt);
    });
});

String _deviceName(DeviceSession session) {
  final name = session.deviceName.trim();
  return name.isEmpty ? 'Unbekanntes Gerät' : name;
}

/// "vor 5 Min." bleibt so, ältere Angaben werden zu "am 3. Okt. 2026".
String _lastActive(DateTime date) {
  final relative = formatRelative(date);
  final isRelative = relative.startsWith('vor ') || relative == 'gerade eben';
  return 'Zuletzt aktiv ${isRelative ? relative : 'am $relative'}';
}

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final _busy = <int>{};
  bool _loggingOutAll = false;

  Future<void> _refresh() async {
    try {
      final reload = ref.refresh(deviceSessionsProvider.future);
      await reload;
    } catch (_) {
      // Fehler zeigt die Liste selbst an
    }
  }

  Future<void> _logout(DeviceSession session) async {
    final name = _deviceName(session);
    final ok = await confirm(
      context,
      title: 'Gerät abmelden?',
      message: '„$name“ wird abgemeldet. Dort musst du dich neu anmelden, um Selfify weiter zu nutzen.',
      confirmLabel: 'Abmelden',
      danger: true,
    );
    if (!ok || !mounted) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() => _busy.add(session.id));
    try {
      await api.deleteSession(session.id);
      if (!mounted) return;
      showMessage(context, '„$name“ wurde abgemeldet');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() => _busy.remove(session.id));
        ref.invalidate(deviceSessionsProvider);
      }
    }
  }

  Future<void> _logoutOthers(List<DeviceSession> others) async {
    final ok = await confirm(
      context,
      title: 'Alle anderen Geräte abmelden?',
      message: '${others.length} Geräte werden abgemeldet. Nur dieses Gerät bleibt angemeldet.',
      confirmLabel: 'Alle abmelden',
      danger: true,
    );
    if (!ok || !mounted) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _loggingOutAll = true;
      _busy.addAll(others.map((s) => s.id));
    });
    var failed = 0;
    Object? lastError;
    for (final session in others) {
      try {
        await api.deleteSession(session.id);
      } catch (e) {
        failed++;
        lastError = e;
      }
    }
    if (!mounted) return;
    setState(() {
      _loggingOutAll = false;
      _busy.removeAll(others.map((s) => s.id));
    });
    ref.invalidate(deviceSessionsProvider);
    if (failed == 0) {
      showMessage(context, 'Alle anderen Geräte wurden abgemeldet');
    } else {
      showMessage(
        context,
        failed == others.length
            ? errorText(lastError!)
            : '$failed von ${others.length} Geräten konnten nicht abgemeldet werden: ${errorText(lastError!)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(deviceSessionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Angemeldete Geräte')),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _refresh,
        child: sessions.when(
          skipLoadingOnRefresh: true,
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _Scrollable(
            child: ErrorView(
              message: errorText(error),
              onRetry: () => ref.invalidate(deviceSessionsProvider),
            ),
          ),
          data: (list) => list.isEmpty
              ? const _Scrollable(
                  child: EmptyState(
                    icon: Icons.devices_rounded,
                    title: 'Keine Geräte gefunden',
                    message: 'Zieh nach unten, um die Liste neu zu laden.',
                  ),
                )
              : _list(list),
        ),
      ),
    );
  }

  Widget _list(List<DeviceSession> sessions) {
    final current = sessions.where((s) => s.current).toList();
    final others = sessions.where((s) => !s.current).toList();
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(bottom: 32 + bottom),
      children: [
        const _Intro(),
        if (current.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final session in current) _DeviceCard(session: session),
        ],
        _GroupTitle(others.isEmpty ? 'Andere Geräte' : 'Andere Geräte (${others.length})'),
        if (others.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Icon(Icons.verified_user_rounded, color: AppColors.accent, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Du bist auf keinem anderen Gerät angemeldet.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                  ),
                ),
              ],
            ),
          )
        else
          for (final session in others)
            _DeviceCard(
              session: session,
              busy: _busy.contains(session.id),
              onLogout: _loggingOutAll ? null : () => _logout(session),
            ),
        if (others.length >= 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Center(
              child: OutlinedButton.icon(
                onPressed: _loggingOutAll || _busy.isNotEmpty ? null : () => _logoutOthers(others),
                icon: _loggingOutAll
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Alle anderen Geräte abmelden'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Text(
            'Tipp: Wenn du dein Passwort änderst, werden alle anderen Geräte automatisch abgemeldet.',
            style: AppText.caption,
          ),
        ),
      ],
    );
  }
}

/// Damit "Herunterziehen zum Aktualisieren" auch bei Fehlern/Leere funktioniert.
class _Scrollable extends StatelessWidget {
  final Widget child;
  const _Scrollable({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(Icons.devices_rounded, color: AppColors.accent, size: 28),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              'Hier siehst du, wo du angemeldet bist. Melde verlorene Geräte ab.',
              style: TextStyle(color: Colors.white, fontSize: 14, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupTitle extends StatelessWidget {
  final String title;
  const _GroupTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DeviceSession session;
  final bool busy;
  final VoidCallback? onLogout;

  const _DeviceCard({required this.session, this.busy = false, this.onLogout});

  @override
  Widget build(BuildContext context) {
    final current = session.current;
    final client = deviceClient(session);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: current ? AppColors.accent.withValues(alpha: 0.55) : AppColors.surfaceHighest,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: current ? AppColors.accent.withValues(alpha: 0.16) : AppColors.surfaceHighest,
            ),
            child: Icon(deviceIcon(session), color: current ? AppColors.accent : Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _deviceName(session),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    ),
                    if (current) ...[
                      const SizedBox(width: 8),
                      const _CurrentBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                _InfoLine(icon: Icons.schedule_rounded, text: _lastActive(session.lastUsedAt)),
                _InfoLine(
                  icon: Icons.lan_outlined,
                  text: session.ipAddress.isEmpty ? 'IP-Adresse unbekannt' : 'IP-Adresse ${session.ipAddress}',
                ),
                _InfoLine(icon: Icons.login_rounded, text: 'Angemeldet seit ${formatDate(session.createdAt)}'),
                if (client != null) _InfoLine(icon: Icons.apps_rounded, text: client),
                if (!current) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 36,
                    child: OutlinedButton(
                      onPressed: busy ? null : onLogout,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                      child: busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Abmelden'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentBadge extends StatelessWidget {
  const _CurrentBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(20)),
      child: const Text(
        'Dieses Gerät',
        style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: AppText.tileSubtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
