import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:monitor_ambiental/core/api.dart';
import 'package:monitor_ambiental/core/app_scope.dart';
import 'package:monitor_ambiental/core/buzzer.dart';
import 'package:monitor_ambiental/core/format.dart' as f;
import 'package:monitor_ambiental/core/models.dart';
import 'package:monitor_ambiental/core/prefs.dart';
import 'package:monitor_ambiental/core/theme.dart';
import 'package:monitor_ambiental/pages/login_page.dart';
import 'package:monitor_ambiental/pages/qr_scanner_page.dart';
import 'package:monitor_ambiental/widgets/line_chart.dart';
import 'package:monitor_ambiental/widgets/server_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child, {ApiClient? api}) {
  return AppScope(
    api: api ?? ApiClient(),
    prefs: AppPrefs(),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: child),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('formatação', () {
    test('números e temperaturas em português', () {
      expect(f.number(98.64), '98,6');
      expect(f.temp(37, TempUnit.fahrenheit), '98,6 °F');
      expect(f.temp(37, TempUnit.celsius), '37,0 °C');
      expect(f.tempWithOther(37, TempUnit.fahrenheit), '98,6 °F (37,0 °C)');
      expect(f.integer(1234567), '1.234.567');
    });

    test('durações e tempo relativo', () {
      expect(f.duration(29), '1 d 5 h');
      expect(f.duration(5.4), '5 h 24 min');
      final now = DateTime(2026, 9, 25, 12);
      expect(f.relative(now.subtract(const Duration(seconds: 12)), now: now), 'há 12 s');
      expect(f.relative(now.subtract(const Duration(minutes: 5)), now: now), 'há 5 min');
      expect(f.relative(null), 'nunca');
    });
  });

  test('QR code do sensor é interpretado em vários formatos', () {
    expect(parseDeviceQr('{"controller_id":"ESP32-TOBACCO-01","mac_address":"24:6F:28:B1:09:4A"}').code, 'ESP32-TOBACCO-01');
    expect(parseDeviceQr('ID=ESP32-TOBACCO-02;N=4;T=25.3;H=61.2').code, 'ESP32-TOBACCO-02');
    expect(parseDeviceQr('ESP32-TOBACCO-03').code, 'ESP32-TOBACCO-03');
    expect(parseDeviceQr('mac 24-6f-28-b1-09-4a').mac, '24-6F-28-B1-09-4A');
  });

  test('erros de validação da API viram frases curtas', () {
    final message = describeValidation([
      {'type': 'string_too_short', 'loc': ['body', 'password'], 'ctx': {'min_length': 6}, 'msg': ''},
    ]);
    expect(message, 'Senha: mínimo de 6 caracteres.');
  });

  test('saídas e avisos sonoros da API', () {
    final outputs = Outputs.fromJson({
      'curing_unit_id': 1,
      'is_drying': true,
      'confirmed_at': '2026-09-26T12:05:02Z',
      'humidity': {
        'name': 'Ventoinhas', 'relay': 1, 'pin': 'GPIO2', 'mode': 'auto', 'trigger': 'temperature_high', 'on': true,
        'reason': 'Automático: ligada porque a temperatura passou do máximo.', 'confirmed_on': true, 'in_sync': true,
      },
      'temperature': {
        'name': 'Saída de temperatura', 'relay': 2, 'pin': 'GPIO3', 'mode': 'off', 'trigger': 'temperature_out', 'on': false,
        'reason': 'Desligada manualmente no app.', 'confirmed_on': null, 'in_sync': false,
      },
      'last_buzzer': {
        'id': 7, 'timestamp': '2026-09-26T12:00:00Z', 'output': 'humidity', 'output_name': 'Saída de umidade',
        'turned_on': true, 'buzzer': true, 'cause': 'auto', 'metric': 'humidity', 'value': 95.0,
        'curing_unit_id': 1, 'curing_unit_name': 'Estufa 01',
      },
      'events': [
        {
          'id': 8, 'timestamp': '2026-09-26T12:05:00Z', 'output': 'humidity', 'output_name': 'Ventoinhas', 'turned_on': true,
          'buzzer': true, 'cause': 'auto', 'metric': 'temperature', 'value': 80.0, 'curing_unit_id': 1,
        },
        {'id': 6, 'timestamp': '2026-09-26T11:00:00Z', 'output': 'temperature', 'turned_on': false, 'buzzer': false, 'cause': 'stopped', 'curing_unit_id': 1},
      ],
    });
    expect(outputs.humidity.on, isTrue);
    expect(outputs.humidity.relayLabel, 'Relé 1 · GPIO2');
    expect(outputs.humidity.inSync, isTrue);
    expect(outputs.temperature.confirmedOn, isNull);
    expect(outputTriggers[outputs.humidity.trigger], 'Temperatura acima do máximo');
    expect(outputs.temperature.mode, 'off');
    expect(outputs.lastBuzzer!.unitName, 'Estufa 01');
    expect(describeOutputEvent(outputs.lastBuzzer!, TempUnit.celsius), 'Saída de umidade ligou (automático, 95,0%)');
    expect(describeOutputEvent(outputs.events.first, TempUnit.fahrenheit), 'Ventoinhas ligou (automático, 176,0 °F)');
    expect(describeOutputEvent(outputs.events.last, TempUnit.celsius), 'Saída de temperatura desligou (secagem parada)');
  });

  testWidgets('tela de login', (tester) async {
    await tester.pumpWidget(_wrap(LoginPage(onAuthenticated: () {})));

    expect(find.text('Entrar na plataforma'), findsOneWidget);
    expect(find.text('Criar conta'), findsOneWidget);
    expect(find.text('Esqueci minha senha'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
    await tester.pump();
    expect(find.text('Informe o login.'), findsOneWidget);
  });

  testWidgets('login mostra a mensagem de erro da API', (tester) async {
    final api = ApiClient(
      client: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode({'detail': 'Login ou senha inválidos'})),
            401,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )),
    );
    await tester.pumpWidget(_wrap(LoginPage(onAuthenticated: () {}), api: api));

    await tester.enterText(find.widgetWithText(TextFormField, 'Login'), 'produtor');
    await tester.enterText(find.widgetWithText(TextFormField, 'Senha'), 'errada');
    await tester.tap(find.widgetWithText(FilledButton, 'Entrar'));
    await tester.pumpAndSettle();

    expect(find.text('Login ou senha inválidos'), findsOneWidget);
  });

  testWidgets('gráfico desenha e mostra o valor tocado', (tester) async {
    final start = DateTime(2026, 9, 25, 6);
    final points = [for (var i = 0; i < 30; i++) ChartPoint(start.add(Duration(minutes: 10 * i)), 95 + i * 0.5)];
    await tester.pumpWidget(_wrap(Scaffold(
      body: SizedBox(
        width: 360,
        child: LineChart(
          points: points,
          start: start,
          end: points.last.time,
          limitMin: 95,
          limitMax: 113,
          format: (value) => '${f.number(value)} °F',
        ),
      ),
    )));

    expect(find.byType(CustomPaint), findsWidgets);
    await tester.tapAt(tester.getTopLeft(find.byType(LineChart)) + const Offset(40, 120));
    await tester.pump();
    expect(find.text('95,0 °F'), findsOneWidget);
  });

  testWidgets('gráfico vazio explica o motivo', (tester) async {
    await tester.pumpWidget(_wrap(Scaffold(
      body: LineChart(
        points: const [],
        start: DateTime(2026),
        end: DateTime(2026, 1, 2),
        format: (value) => '$value',
        emptyText: 'Nenhuma leitura neste período.',
      ),
    )));
    expect(find.text('Nenhuma leitura neste período.'), findsOneWidget);
  });

  testWidgets('diálogo do servidor oferece a busca na rede e o endereço manual', (tester) async {
    final api = ApiClient(client: MockClient((request) async => http.Response('{"status":"ok"}', 200)));
    String? saved;
    await tester.pumpWidget(_wrap(Builder(
      builder: (context) => Scaffold(
        body: TextButton(onPressed: () async => saved = await showServerDialog(context, api), child: const Text('abrir')),
      ),
    ), api: api));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.text('Procurar na rede'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'URL da API'), 'http://192.168.0.14:8000/');
    await tester.tap(find.widgetWithText(FilledButton, 'Testar e salvar'));
    await tester.pumpAndSettle();

    expect(saved, 'http://192.168.0.14:8000');
    expect(api.hasSavedBaseUrl, isTrue);
  });
}
