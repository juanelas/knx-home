// Root Material app configuration.
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'screens/dashboard.dart';

class KnxHomeApp extends StatelessWidget {
  const KnxHomeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'KNX home',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: dark,
        primary: dark,
        surface: paper,
      ),
      fontFamily: 'Arial',
    ),
    home: const Dashboard(),
  );
}
