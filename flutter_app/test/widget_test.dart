import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:photo_watermark/main.dart';

void main() {
  testWidgets('App starts', (WidgetTester tester) async {
    await tester.pumpWidget(const PhotoWatermarkApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}