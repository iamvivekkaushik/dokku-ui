import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/platform.dart';
import 'state/core.dart';
import 'ui/shell/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final plain = await PrefsStore.open();
  final prefs = await Prefs.load(plain);
  runApp(ProviderScope(
    // Commands are never retried behind the user's back; screens refresh on
    // their own schedule and after every change.
    retry: (_, _) => null,
    overrides: [
      plainStoreProvider.overrideWithValue(plain),
      secureStoreProvider.overrideWithValue(const SecureStore()),
      initialPrefsProvider.overrideWithValue(prefs),
    ],
    child: const DokkuConsoleApp(),
  ));
}

class DokkuConsoleApp extends StatelessWidget {
  const DokkuConsoleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Dokku Console',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomeShell(),
      );
}
