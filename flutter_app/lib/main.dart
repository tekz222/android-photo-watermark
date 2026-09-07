import 'package:flutter/material.dart';

import 'home_page.dart';

void main() => runApp(const PhotoWatermarkApp());

class PhotoWatermarkApp extends StatelessWidget {
  const PhotoWatermarkApp({super.key});

  /// Desktop look: no ripple circle on click, compact spacing.
  ThemeData _theme(Brightness brightness) {
    return ThemeData(
      colorSchemeSeed: const Color(0xFF05B2AE),
      brightness: brightness,
      useMaterial3: true,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JCV Watermarker',
      debugShowCheckedModeBanner: false,
      // Forced dark mode.
      themeMode: ThemeMode.dark,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      // Slightly smaller text than the touch defaults (mouse + keyboard UI).
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.85)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const HomePage(),
    );
  }
}
