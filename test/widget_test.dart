// Basic smoke test for TartilApp.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_app/main.dart';

void main() {
  testWidgets('App loads without error', (WidgetTester tester) async {
    await tester.pumpWidget(const TartilApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
