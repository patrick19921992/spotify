import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'player/player.dart';
import 'player/windows_audio.dart';
import 'player/windows_media_controls.dart';
import 'state/auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupWindowsAudio(); // nur Windows: Wiedergabe über libmpv
  await initializeDateFormatting('de_DE');
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
  ));


  final prefs = await SharedPreferences.getInstance();
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  // Hintergrund-Wiedergabe mit Benachrichtigung/Sperrbildschirm
  final handler = await AudioService.init(
    builder: SelfifyAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'de.selfify.selfify.audio',
      androidNotificationChannelName: 'Wiedergabe',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  // nur Windows: Medientasten (auch ohne Fokus) und Windows-Medienübersicht
  await setupWindowsMediaControls(handler);

  runApp(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      audioHandlerProvider.overrideWithValue(handler),
    ],
    child: const SelfifyApp(),
  ));
}
