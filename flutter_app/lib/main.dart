import 'package:flutter/material.dart';

import 'home_page.dart';

void main() => runApp(const PhotoWatermarkApp());

class PhotoWatermarkApp extends StatelessWidget {
  const PhotoWatermarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JCV Watermarker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF05B2AE),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
