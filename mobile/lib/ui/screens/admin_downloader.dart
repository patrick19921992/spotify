import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../nav.dart';
import '../widgets/common.dart';
import 'admin_widgets.dart';

// Verwaltung › Downloader: Zustand von yt-dlp & Co. und die Einstellungen des Containers.

final _downloaderStatusProvider =
    FutureProvider.autoDispose<DownloaderStatus>((ref) => requireApi(ref).downloaderStatus());

String _audioFormatLabel(String format) => switch (format) {
      'best' => 'Original (Opus)',
      'm4a' => 'AAC (M4A)',
      'mp3' => 'MP3 320k',
      _ => format,
    };

String _videoCodecLabel(String codec) => switch (codec) {
      'compatible' => 'H.264/MP4 (überall abspielbar)',
      'best' => 'Beste Qualität (VP9/AV1)',
      _ => codec,
    };

/// Wie wichtig eine fehlende Komponente ist.
enum _Need { required, recommended, optional }

/// Tab „Downloader“.
class AdminDownloaderTab extends ConsumerStatefulWidget {
  const AdminDownloaderTab({super.key});

  @override
  ConsumerState<AdminDownloaderTab> createState() => _AdminDownloaderTabState();
}

class _AdminDownloaderTabState extends ConsumerState<AdminDownloaderTab> {
  bool _updating = false;

  Future<void> _refresh() => adminQuietly(ref.refresh(_downloaderStatusProvider.future));

  Future<void> _updateYtdlp() async {
    final api = ref.read(apiProvider);
    if (api == null || _updating) return;
    final before = ref.read(_downloaderStatusProvider).value?.ytdlpVersion;
    setState(() => _updating = true);
    try {
      final status = await api.updateYtdlp();
      if (!mounted) return;
      ref.invalidate(_downloaderStatusProvider);
      final version = status.ytdlpVersion;
      showMessage(
        context,
        version == null
            ? 'yt-dlp wurde aktualisiert.'
            : version == before
                ? 'yt-dlp ist schon aktuell (Version $version).'
                : 'yt-dlp wurde auf Version $version aktualisiert.',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNetwork) {
        // Die Aktualisierung kann länger dauern als die App wartet – sie läuft auf dem Server weiter.
        ref.invalidate(_downloaderStatusProvider);
        showMessage(context, 'Keine Antwort vom Server. Die Aktualisierung läuft eventuell noch – schau gleich noch mal nach.');
      } else {
        showError(context, e);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(_downloaderStatusProvider);
    return AsyncBody<DownloaderStatus>(
      value: value,
      onRetry: () => ref.invalidate(_downloaderStatusProvider),
      builder: (status) => RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: adminListPadding(context, top: 16),
          children: [
            _ReadyCard(status: status),
            const AdminSectionLabel('Komponenten'),
            _ComponentsCard(status: status),
            const AdminSectionLabel('Einstellungen'),
            _SettingsCard(status: status),
            const AdminSectionLabel('Warteschlange'),
            _QueueCard(status: status),
            const SizedBox(height: 24),
            AdminPrimaryButton(
              label: _updating ? 'yt-dlp wird aktualisiert …' : 'yt-dlp jetzt aktualisieren',
              icon: Icons.system_update_alt_rounded,
              busy: _updating,
              onPressed: _updateYtdlp,
            ),
            if (_updating) ...[
              const SizedBox(height: 8),
              const Text(
                'Das kann ein paar Sekunden bis zu einer Minute dauern.',
                style: AppText.caption,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => Nav.allDownloads(context),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)),
              icon: const Icon(Icons.downloading_rounded, size: 20),
              label: const Text('Alle Downloads ansehen', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 24),
            const _ContainerHint(),
          ],
        ),
      ),
    );
  }
}

/// Gesamtzustand oben: bereit oder nicht.
class _ReadyCard extends StatelessWidget {
  final DownloaderStatus status;
  const _ReadyCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final ready = status.ytdlpVersion != null && status.ffmpegAvailable;
    final complete = ready && status.denoAvailable;
    final color = !ready ? AppColors.danger : (complete ? AppColors.accent : adminWarningColor);
    final title = !ready
        ? 'Downloads funktionieren gerade nicht'
        : (complete ? 'Der Downloader ist bereit' : 'Der Downloader ist eingeschränkt bereit');
    final subtitle = !ready
        ? 'Es fehlt ${status.ytdlpVersion == null ? 'yt-dlp' : 'ffmpeg'} im Container.'
        : (complete
            ? '${status.activeJobs} aktiv · ${status.queuedJobs} in der Warteschlange'
            : 'Ohne Deno lassen sich manche YouTube-Videos nicht laden.');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.28), AppColors.surface],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(
              !ready ? Icons.priority_high_rounded : (complete ? Icons.check_rounded : Icons.warning_amber_rounded),
              color: Colors.black,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(subtitle, style: AppText.tileSubtitle),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ComponentsCard extends StatelessWidget {
  final DownloaderStatus status;
  const _ComponentsCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final lastUpdate = status.lastUpdate;
    final lastResult = status.lastUpdateResult?.trim();
    final updateFailed = lastResult != null && lastResult.startsWith('Fehler');
    return AdminCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          _CheckRow(
            ok: status.ytdlpVersion != null,
            need: _Need.required,
            title: 'yt-dlp',
            subtitle: status.ytdlpVersion != null
                ? 'Version ${status.ytdlpVersion}'
                : 'Nicht gefunden – ohne yt-dlp gibt es keine Downloads',
          ),
          _CheckRow(
            ok: status.denoAvailable,
            need: _Need.recommended,
            title: 'JavaScript-Laufzeit (Deno)',
            subtitle: status.denoAvailable
                ? 'Vorhanden – nötig für viele YouTube-Videos'
                : 'Fehlt – manche Videos lassen sich nicht laden',
          ),
          _CheckRow(
            ok: status.ffmpegAvailable,
            need: _Need.required,
            title: 'ffmpeg',
            subtitle: status.ffmpegAvailable
                ? 'Vorhanden – wandelt um und bettet Cover ein'
                : 'Fehlt – Downloads können nicht verarbeitet werden',
          ),
          _CheckRow(
            ok: status.cookiesConfigured,
            need: _Need.optional,
            title: 'Cookies (Premium-Qualität)',
            subtitle: status.cookiesConfigured
                ? 'Eingerichtet – Downloads in YouTube-Premium-Qualität'
                : 'Nicht eingerichtet (optional)',
          ),
          _CheckRow(
            ok: status.autoUpdate,
            need: _Need.optional,
            title: 'Automatische Aktualisierung',
            subtitle: status.autoUpdate ? 'yt-dlp wird täglich aktualisiert' : 'Aus – aktualisiere yt-dlp von Hand',
            detail: lastUpdate == null
                ? 'Seit dem Serverstart noch nicht aktualisiert'
                : 'Zuletzt ${formatDateTime(lastUpdate)}${lastResult == null || lastResult.isEmpty ? '' : ' – $lastResult'}',
            detailColor: updateFailed ? AppColors.danger : null,
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final bool ok;
  final _Need need;
  final String title;
  final String subtitle;
  final String? detail;
  final Color? detailColor;

  const _CheckRow({
    required this.ok,
    required this.need,
    required this.title,
    required this.subtitle,
    this.detail,
    this.detailColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = ok
        ? AppColors.accent
        : switch (need) {
            _Need.required => AppColors.danger,
            _Need.recommended => adminWarningColor,
            _Need.optional => AppColors.textMuted,
          };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, color: color, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.tileTitle),
                const SizedBox(height: 2),
                Text(subtitle, style: AppText.tileSubtitle),
                if (detail != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: detailColor ?? AppColors.textMuted),
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

class _SettingsCard extends StatelessWidget {
  final DownloaderStatus status;
  const _SettingsCard({required this.status});

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          _InfoRow(
            icon: Icons.graphic_eq_rounded,
            title: 'Audio-Format',
            subtitle: _audioFormatLabel(status.audioFormat),
          ),
          _InfoRow(
            icon: Icons.videocam_rounded,
            title: 'Video',
            subtitle: [
              _videoCodecLabel(status.videoCodec),
              if (status.videoMaxHeight > 0) 'bis ${status.videoMaxHeight}p',
            ].join(' · '),
          ),
          _InfoRow(
            icon: Icons.call_split_rounded,
            title: 'Gleichzeitige Downloads',
            trailing: '${status.workers}',
          ),
        ],
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  final DownloaderStatus status;
  const _QueueCard({required this.status});

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          _InfoRow(icon: Icons.downloading_rounded, title: 'Gerade aktiv', trailing: '${status.activeJobs}'),
          _InfoRow(icon: Icons.queue_music_rounded, title: 'In der Warteschlange', trailing: '${status.queuedJobs}'),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;

  const _InfoRow({required this.icon, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.tileTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: AppText.tileSubtitle),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Text(trailing!, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ],
        ],
      ),
    );
  }
}

/// Hinweis: Einstellungen werden über die Variablen des Unraid-Containers geändert.
class _ContainerHint extends StatelessWidget {
  const _ContainerHint();

  static const _variables = [
    ('YTDL_AUDIO_FORMAT', 'best (Original/Opus), m4a (AAC) oder mp3'),
    ('YTDL_VIDEO_CODEC', 'compatible (H.264/MP4) oder best (VP9/AV1)'),
    ('YTDL_VIDEO_MAX_HEIGHT', 'höchste Auflösung, z. B. 720, 1080 oder 2160'),
    ('DOWNLOAD_WORKERS', 'wie viele Downloads gleichzeitig laufen (1–8)'),
  ];

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      color: AppColors.surfaceHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: AppColors.textSecondary, size: 20),
              SizedBox(width: 10),
              Expanded(child: Text('Einstellungen ändern', style: AppText.tileTitle)),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Format, Qualität und Anzahl der Downloads stellst du in Unraid ein: Docker → Selfify → '
            '„Bearbeiten“, dann diese Variablen des Containers anpassen:',
            style: AppText.tileSubtitle,
          ),
          const SizedBox(height: 12),
          for (final (name, description) in _variables)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(name, style: adminMonospace.copyWith(color: Colors.white, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(description, style: AppText.caption),
                ],
              ),
            ),
          const SizedBox(height: 2),
          const Text(
            'Nach dem Übernehmen startet der Container neu. Für Premium-Qualität legst du deine YouTube-Cookies '
            'als „youtube-cookies.txt“ in den Datenordner (/data).',
            style: AppText.caption,
          ),
        ],
      ),
    );
  }
}
