import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import 'home_page.dart';

void main() => runApp(const PhotoWatermarkApp());

class PhotoWatermarkApp extends StatelessWidget {
  const PhotoWatermarkApp({super.key});

  /// Desktop look: Windows system font, flat squared buttons, no ripple circle
  /// on click, compact controls.
  ThemeData _theme(Brightness brightness) {
    final base = ThemeData(
      colorSchemeSeed: const Color(0xFF05B2AE),
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'Segoe UI',
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final scheme = base.colorScheme;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
    const buttonText = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    const buttonPad = EdgeInsets.symmetric(horizontal: 14, vertical: 11);
    final text = base.textTheme;
    return base.copyWith(
      scaffoldBackgroundColor:
          brightness == Brightness.dark ? const Color(0xFF1B1B1D) : null,
      textTheme: text.copyWith(
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 14.5),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 13.5),
        bodySmall: text.bodySmall
            ?.copyWith(fontSize: 12.5, color: scheme.onSurfaceVariant),
        titleSmall: text.titleSmall?.copyWith(fontSize: 13.5),
        titleMedium: text.titleMedium?.copyWith(fontSize: 15),
        labelLarge: text.labelLarge?.copyWith(fontSize: 13),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: shape,
          padding: buttonPad,
          textStyle: buttonText,
          minimumSize: const Size(0, 36),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shape,
          padding: buttonPad,
          textStyle: buttonText,
          minimumSize: const Size(0, 36),
          side: BorderSide(color: scheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: shape,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          textStyle: buttonText,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: shape,
          textStyle: const TextStyle(fontSize: 12.5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          visualDensity: VisualDensity.compact,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: shape,
        labelStyle: const TextStyle(fontSize: 12.5),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        showCheckmark: false,
      ),
      sliderTheme: base.sliderTheme.copyWith(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: SliderComponentShape.noOverlay,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        labelStyle: const TextStyle(fontSize: 13),
      ),
      dividerTheme:
          DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
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
      // Let the mouse drag scrollables (page viewer, thumbnail strips, lists);
      // Flutter only enables touch/stylus dragging by default.
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      home: const HomePage(),
    );
  }
}
