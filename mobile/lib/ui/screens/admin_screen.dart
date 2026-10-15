import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/settings.dart';
import '../shell.dart';
import '../widgets/common.dart';
import 'admin_categories.dart';
import 'admin_downloader.dart';
import 'admin_library.dart';
import 'admin_users.dart';

/// Verwaltung für Admins: Benutzer, Rubriken, Bibliothek und Downloader.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> with SingleTickerProviderStateMixin {
  static const _tabTitles = ['Benutzer', 'Rubriken', 'Bibliothek', 'Downloader'];

  late final TabController _tabs = TabController(length: _tabTitles.length, vsync: this)..addListener(_onTab);
  int _index = 0;

  void _onTab() {
    if (_tabs.index != _index) setState(() => _index = _tabs.index);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  Widget? _fab() => switch (_index) {
        0 => FloatingActionButton.extended(
            key: const ValueKey('admin-fab-users'),
            heroTag: 'admin-fab-users',
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.black,
            onPressed: () => showCreateUserSheet(context),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Benutzer anlegen', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        1 => FloatingActionButton.extended(
            key: const ValueKey('admin-fab-categories'),
            heroTag: 'admin-fab-categories',
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.black,
            onPressed: () => showCreateCategorySheet(context),
            icon: const Icon(Icons.create_new_folder_rounded),
            label: const Text('Rubrik anlegen', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        _ => null,
      };

  /// Einfache Seite ohne Tabs (kein Admin, offline).
  Widget _plain(Widget body) => Scaffold(
        appBar: AppBar(title: const Text('Verwaltung')),
        body: SafeArea(top: false, child: body),
      );

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final offline = ref.watch(isOfflineProvider);
    final offlineMode = ref.watch(settingsProvider.select((s) => s.offlineMode));

    if (user == null || !user.isAdmin) {
      return _plain(
        EmptyState(
          icon: Icons.admin_panel_settings_outlined,
          title: 'Nur für Admins',
          message: 'Benutzer, Rubriken, Bibliothek und Downloader können nur Admins verwalten.',
          action: OutlinedButton(onPressed: _back, child: const Text('Zurück')),
        ),
      );
    }
    if (offline) {
      return _plain(
        const EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Du bist offline',
          message: 'Für die Verwaltung brauchst du eine Verbindung zum Server.',
        ),
      );
    }
    if (offlineMode) {
      return _plain(
        EmptyState(
          icon: Icons.offline_pin_rounded,
          title: 'Offline-Modus ist an',
          message: 'Für die Verwaltung braucht die App eine Verbindung zum Server.',
          action: FilledButton(
            onPressed: () => ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineMode: false)),
            child: const Text('Offline-Modus ausschalten'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verwaltung'),
        actions: const [DownloadsAction(), SizedBox(width: 4)],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: AppColors.accent,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: AppColors.textSecondary,
          labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          dividerColor: AppColors.surfaceHighest,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tabs: [for (final title in _tabTitles) Tab(text: title)],
        ),
      ),
      floatingActionButton: _fab(),
      body: SafeArea(
        top: false,
        bottom: false,
        child: TabBarView(
          controller: _tabs,
          children: const [
            AdminUsersTab(),
            AdminCategoriesTab(),
            AdminLibraryTab(),
            AdminDownloaderTab(),
          ],
        ),
      ),
    );
  }
}
