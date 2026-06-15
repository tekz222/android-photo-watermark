import 'package:flutter/material.dart';

import 'home_page.dart';

void main() => runApp(const PhotoWatermarkApp());

class PhotoWatermarkApp extends StatelessWidget {
  const PhotoWatermarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photo Watermark',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F51B5),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
