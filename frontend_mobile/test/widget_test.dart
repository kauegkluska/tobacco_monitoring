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
import 'package:monitor_ambiental/widgets/common.dart';
import 'package:monitor_ambiental/pages/login_page.dart';
import 'package:monitor_ambiental/pages/qr_scanner_page.dart';
import 'package:monitor_ambiental/pages/shell.dart';
import 'package:monitor_ambiental/pages/unit_page.dart';
import 'package:monitor_ambiental/pages/units_page.dart';
import 'package:monitor_ambiental/widgets/line_chart.dart';
import 'package:monitor_ambiental/widgets/server_dialog.dart';
import 'package:monitor_ambiental/widgets/unit_widgets.dart';
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
      expect(f.tempRange(35, 40, TempUnit.celsius), '35 a 40 °C');
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
    expect(describeOutputEvent(outputs.events.last, TempUnit.celsius), 'Ventoinha desligou (secagem parada)');
  });

  testWidgets('tela de login', (tester) async {
    await tester.pumpWidget(_wrap(LoginPage(onAuthenticated: () {})));

    expect(find.text('Entrar'), findsNWidgets(3));
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

  test('fases da cura na API', () {
    final unit = CuringUnit.fromJson({
      'id': 1,
      'name': 'Estufa 01',
      'curing_stage': 'Murchamento',
      'stage_started_at': '2026-09-30T10:00:00Z',
      'drying_started_at': '2026-09-29T10:00:00Z',
      'phase': {
        'key': 'murchamento',
        'name': 'Murchamento',
        'number': 2,
        'total': 4,
        'temp_min': 40,
        'temp_max': 48,
        'humidity_min': 65,
        'humidity_max': 85,
        'min_hours': 12,
        'max_hours': 24,
        'hours': 13.5,
        'overdue': false,
        'next_stage': 'Secagem da folha',
        'ready': false,
        'checks': [
          {'label': 'Pelo menos 12 h nesta fase', 'ok': true},
          {'label': 'Temperatura em 115 °F (46 °C) ou mais', 'ok': false},
        ],
        'visual_check': 'Folhas completamente murchas, moles ao toque.',
      },
    });
    expect(unit.phase!.number, 2);
    expect(unit.limitsWith(null).tempMax, 48);
    expect(unit.phase!.checks.where((check) => check.ok).length, 1);
    expect(unit.phase!.finishes, isFalse);
    expect(phaseKeyOf('Secagem do talo'), 'secagem_talo');
    expect(curingStages, ['Não iniciado', 'Amarelação', 'Murchamento', 'Secagem da folha', 'Secagem do talo', 'Finalizado']);

    final stopped = CuringUnit.fromJson({'id': 2, 'curing_stage': 'Não iniciado', 'stage_started_at': '2026-09-30T10:00:00Z'});
    expect(stopped.phase, isNull);
    expect(stopped.limitsWith(null).tempMax, Limits.defaults.tempMax);

    final series = Series.fromJson({
      'since': '2026-09-29T00:00:00Z',
      'until': '2026-09-30T00:00:00Z',
      'bucket_seconds': 360,
      'points': [],
      'stats': {'count': 0},
      'phases': [
        {'stage': 'Amarelação', 'key': 'amarelacao', 'started_at': '2026-09-29T00:00:00Z', 'ended_at': '2026-09-29T12:00:00Z', 'temp_min': 35, 'temp_max': 40},
        {'stage': 'Murchamento', 'key': 'murchamento', 'started_at': '2026-09-29T12:00:00Z', 'ended_at': '2026-09-30T00:00:00Z', 'temp_min': 40, 'temp_max': 48},
      ],
    });
    expect(series.phaseAt(DateTime.utc(2026, 9, 29, 6).toLocal())?.stage, 'Amarelação');
    expect(series.phaseAt(DateTime.utc(2026, 9, 29, 18).toLocal())?.key, 'murchamento');

    final alert = AlertItem.fromJson({'id': 1, 'type': 'Temperatura alta', 'severity': 'emergency', 'is_active': true, 'curing_unit_id': 1});
    expect(alert.isCritical, isTrue);
    expect(alert.severityLabel, 'Emergência');
  });

  testWidgets('gráfico mostra a fase do ponto tocado', (tester) async {
    final start = DateTime(2026, 9, 25, 6);
    final points = [for (var i = 0; i < 30; i++) ChartPoint(start.add(Duration(minutes: 10 * i)), 36 + i * 0.4)];
    final middle = start.add(const Duration(hours: 2));
    await tester.pumpWidget(_wrap(Scaffold(
      body: SizedBox(
        width: 360,
        child: LineChart(
          points: points,
          start: start,
          end: points.last.time,
          phases: [
            ChartPhase(start: start, end: middle, name: 'Amarelação', color: AppColors.light.phase('amarelacao'), min: 35, max: 40),
            ChartPhase(start: middle, end: points.last.time, name: 'Murchamento', color: AppColors.light.phase('murchamento'), min: 40, max: 48),
          ],
          format: (value) => '${f.number(value)} °C',
        ),
      ),
    )));

    await tester.tapAt(tester.getTopLeft(find.byType(LineChart)) + const Offset(40, 120));
    await tester.pump();
    expect(find.text('Amarelação'), findsOneWidget);
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

  group('situação da estufa', () {
    final drying = {
      'id': 1,
      'name': 'Estufa 01',
      'curing_stage': 'Amarelação',
      'device_id': 3,
      'stage_started_at': '2026-09-30T10:00:00Z',
      'drying_started_at': '2026-09-30T10:00:00Z',
      'phase': {
        'key': 'amarelacao', 'name': 'Amarelação', 'number': 1, 'total': 4,
        'temp_min': 35, 'temp_max': 40, 'humidity_min': 80, 'humidity_max': 95,
        'min_hours': 24, 'max_hours': 48, 'hours': 2, 'overdue': false, 'next_stage': 'Murchamento', 'ready': false,
        'checks': [
          {'label': 'Temperatura em 38 °C ou mais', 'ok': false, 'metric': 'temperature', 'target': 38},
        ],
        'visual_check': 'Folhas amarelas.',
      },
    };
    Device device({bool online = true}) => Device.fromJson({'id': 3, 'device_code': 'ESP32-TOBACCO-01', 'status': online ? 'online' : 'offline'});
    Reading reading(double temperature, double humidity) =>
        Reading.fromJson({'temperature': temperature, 'humidity': humidity, 'timestamp': DateTime.now().toUtc().toIso8601String()});

    test('da mais urgente para a mais tranquila', () {
      final unit = CuringUnit.fromJson(drying);
      String label(Device? d, Reading? r, {int active = 0, int critical = 0}) =>
          unitStatus(unit: unit, device: d, latest: r, activeAlerts: active, criticalAlerts: critical).label;

      expect(label(null, null), 'Sem sensor');
      expect(label(device(online: false), reading(37, 85), active: 1, critical: 1), 'Crítico');
      expect(label(device(online: false), reading(37, 85)), 'Sem sinal');
      expect(label(device(), reading(37, 85), active: 1), 'Atenção');
      expect(label(device(), reading(41, 85)), 'Fora da faixa');
      expect(label(device(), reading(37, 85)), 'Normal');
      final stopped = CuringUnit.fromJson({...drying, 'drying_started_at': null, 'phase': null});
      expect(unitStatus(unit: stopped, device: device(), latest: null, activeAlerts: 0, criticalAlerts: 0).label, 'Parada');
    });

    test('alvo de temperatura segue a unidade escolhida', () {
      final check = CuringUnit.fromJson(drying).phase!.checks.single;
      expect(phaseCheckLabel(check, TempUnit.celsius), 'Temperatura em 38 °C ou mais');
      expect(phaseCheckLabel(check, TempUnit.fahrenheit), 'Temperatura em 100 °F ou mais');
    });

    testWidgets('lista mostra temperatura, umidade e alertas de cada estufa', (tester) async {
      final api = ApiClient(
        client: MockClient((request) async {
          final body = switch (request.url.path) {
            '/curing_units/' => [
                {
                  ...drying,
                  'latest': {'id': 9, 'temperature': 41.0, 'humidity': 85.0, 'timestamp': DateTime.now().toUtc().toIso8601String(), 'curing_unit_id': 1},
                  'active_alerts': 2,
                  'critical_alerts': 1,
                },
              ],
            '/devices/' => [
                {'id': 3, 'device_code': 'ESP32-TOBACCO-01', 'status': 'online', 'curing_unit_id': 1},
              ],
            _ => <dynamic>[],
          };
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }),
      );
      var alertCount = 0;
      final actions = ShellActions(goTo: (_) {}, setAlertCount: (count) => alertCount = count, logout: () async {});
      await tester.pumpWidget(_wrap(Scaffold(body: UnitsPage(actions: actions)), api: api));
      await tester.pump();
      await tester.pump();

      expect(find.text('Estufa 01'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is StatusBadge && widget.label == 'Crítico'), findsOneWidget);
      expect(find.text('105,8'), findsOneWidget);
      expect(find.text('85,0'), findsOneWidget);
      expect(find.text('Esperado 95 a 104 °F'), findsOneWidget);
      expect(find.textContaining('2 alertas ativos'), findsOneWidget);
      expect(alertCount, 2);
    });

    testWidgets('tela da estufa cabe num celular de 360 dp', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now().toUtc();
      final output = {'relay': 1, 'pin': 'GPIO2', 'mode': 'auto', 'trigger': 'humidity_out', 'on': false, 'reason': 'Liga quando a umidade sair da faixa esperada.', 'in_sync': false};
      final api = ApiClient(
        client: MockClient((request) async {
          final path = request.url.path;
          final Object body = switch (path) {
            '/curing_units/1' => drying,
            '/devices/' => [
                {'id': 3, 'device_code': 'ESP32-TOBACCO-01', 'status': 'online', 'rssi': -80, 'snr': 7.5, 'firmware_version': '1.2.0', 'curing_unit_id': 1, 'last_seen_at': now.toIso8601String()},
              ],
            '/curing_units/1/latest' => {'id': 9, 'temperature': 41.2, 'humidity': 88.0, 'timestamp': now.toIso8601String(), 'curing_unit_id': 1},
            '/curing_units/1/alerts' => [
                {'id': 4, 'type': 'Temperatura alta', 'severity': 'warning', 'is_active': true, 'message': 'Temperatura acima do limite na fase de Amarelação.', 'value': 41.2, 'threshold': 40, 'timestamp': now.toIso8601String(), 'curing_unit_id': 1},
              ],
            '/curing_units/1/outputs' => {
                'curing_unit_id': 1, 'is_drying': true, 'confirmed_at': null,
                'humidity': {...output, 'name': 'Ventoinhas'},
                'target_temperature': 38,
                'temperature': {...output, 'name': 'Ventoinha', 'relay': 2, 'pin': 'GPIO3', 'trigger': 'temperature_target'},
                'last_buzzer': null, 'events': [],
              },
            '/curing_units/1/series' => {
                'since': now.subtract(const Duration(hours: 6)).toIso8601String(), 'until': now.toIso8601String(), 'bucket_seconds': 120,
                'points': [], 'stats': {'count': 0}, 'phases': [],
              },
            _ => <dynamic>[],
          };
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }),
      );
      await tester.pumpWidget(_wrap(const UnitPage(unitId: 1), api: api));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Estufa 01'), findsOneWidget);
      expect(find.text('Esperado 95 a 104 °F'), findsOneWidget);
      expect(find.text('Temperatura alta'), findsOneWidget);
      expect(find.text('Avançar fase'), findsOneWidget);
      // A ventoinha segue o alvo: aparece na temperatura e nas saídas.
      expect(find.text('Alvo 100,4 °F'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Desvincular'), 300);
      expect(find.text('Ventoinhas'), findsOneWidget);
      expect(find.text('Alvo  100,4 °F', findRichText: true), findsOneWidget);
      expect(find.text('Alterar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('secagem parada no meio pergunta se continua ou começa outra estufada', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now().toUtc();
      final paused = {
        ...drying,
        'curing_stage': 'Murchamento',
        'drying_started_at': null,
        'phase': null,
        'stage_hours': 16.95,
        'cycle_hours': 40.0,
        'interrupted': true,
        'paused_at': now.subtract(const Duration(hours: 2)).toIso8601String(),
      };
      final posts = <String>[];
      final api = ApiClient(
        client: MockClient((request) async {
          if (request.method == 'POST') posts.add(request.url.toString());
          final Object body = switch (request.url.path) {
            '/curing_units/1' || '/curing_units/1/start-drying' => paused,
            '/devices/' => [
                {'id': 3, 'device_code': 'ESP32-TOBACCO-01', 'status': 'online', 'curing_unit_id': 1},
              ],
            '/curing_units/1/latest' => <String, dynamic>{},
            '/curing_units/1/outputs' => {
                'curing_unit_id': 1, 'is_drying': false,
                'humidity': {'name': 'Flap', 'relay': 1, 'mode': 'auto', 'trigger': 'humidity_out', 'on': false, 'reason': ''},
                'temperature': {'name': 'Ventoinha', 'relay': 2, 'mode': 'auto', 'trigger': 'temperature_target', 'on': false, 'reason': ''},
                'events': [],
              },
            '/curing_units/1/series' => {
                'since': now.subtract(const Duration(hours: 6)).toIso8601String(), 'until': now.toIso8601String(), 'bucket_seconds': 120,
                'points': [], 'stats': {'count': 0}, 'phases': [],
              },
            _ => <dynamic>[],
          };
          if (request.url.path == '/curing_units/1/latest') return http.Response('', 404);
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }),
      );
      await tester.pumpWidget(_wrap(const UnitPage(unitId: 1), api: api));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Parada em Murchamento'), findsOneWidget);
      expect(find.text('16 h 57 min'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Iniciar secagem'), 200);
      await tester.tap(find.text('Iniciar secagem'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Continuar a secagem?'), findsOneWidget);

      await tester.tap(find.text('Nova estufada'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(posts.single, endsWith('/curing_units/1/start-drying?new_batch=true'));
    });
  });
}
