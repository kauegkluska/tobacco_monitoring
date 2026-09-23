// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monitor_ambiental/app.dart';

void main() {
  testWidgets('exibe o monitor de estufa', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiService())));

    expect(find.text('Monitor de Estufa'), findsOneWidget);
    expect(find.text('Entrar na plataforma'), findsOneWidget);
    expect(find.text('Criar conta de produtor'), findsOneWidget);
  });
}
