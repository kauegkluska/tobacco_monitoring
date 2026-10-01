import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide NotificationVisibility;

import 'api.dart';
import 'buzzer.dart';
import 'format.dart' as f;
import 'models.dart';
import 'prefs.dart';

// Avisos com o app fechado (Android): um serviço em primeiro plano consulta a API
// a cada 15 s e mostra uma notificação quando o gateway toca o aviso sonoro ou um
// alerta abre. Não depende de Firebase: basta o celular alcançar o servidor.

const _interval = Duration(seconds: 15);
const _serviceId = 417;
AndroidNotificationDetails _alertDetails(String ticker) => AndroidNotificationDetails(
      'avisos_estufa',
      'Avisos da estufa',
      channelDescription: 'Aviso sonoro do gateway (uma saída ligou) e alertas de temperatura e umidade.',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      color: const Color(0xff2e7d32),
      ticker: ticker,
    );
const _icon = NotificationIcon(metaDataName: 'com.example.monitor_ambiental.NOTIFICATION_ICON', backgroundColor: Color(0xff2e7d32));

@pragma('vm:entry-point')
void backgroundMonitorCallback() {
  FlutterForegroundTask.setTaskHandler(_MonitorTaskHandler());
}

class _MonitorTaskHandler extends TaskHandler {
  final _api = ApiClient();
  final _notifications = FlutterLocalNotificationsPlugin();
  final _prefs = AppPrefs();
  int? _lastEventId;
  int? _lastAlertId;
  bool _busy = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _api.load();
    await _prefs.load();
    _api.onSessionExpired = _sessionExpired;
    await _notifications.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_monitor')),
    );
    // Primeira consulta só marca onde parou: o que já aconteceu não vira notificação.
    await _check(notify: false);
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _check(notify: true);

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/');

  Future<void> _check({required bool notify}) async {
    if (_busy) return;
    _busy = true;
    try {
      final after = _lastEventId;
      final path = after == null ? '/output-events/?limit=1' : '/output-events/?after_id=$after&buzzer=true&limit=20';
      final events = (await _api.get(path) as List).map((item) => OutputEvent.fromJson(item as Map<String, dynamic>)).toList();
      final alerts = (await _api.get('/alerts/?active=true&limit=100') as List)
          .map((item) => AlertItem.fromJson(item as Map<String, dynamic>))
          .toList();

      final newEvents = after == null ? const <OutputEvent>[] : events.where((event) => event.buzzer).toList();
      final lastAlert = _lastAlertId;
      final newAlerts = lastAlert == null ? const <AlertItem>[] : alerts.where((alert) => alert.id > lastAlert).toList();
      _lastEventId = events.fold<int>(after ?? 0, (value, event) => math.max(value, event.id));
      _lastAlertId = alerts.fold<int>(lastAlert ?? 0, (value, alert) => math.max(value, alert.id));

      // Com o app aberto, a própria tela já avisa (e bipa).
      if (notify && !await FlutterForegroundTask.isAppOnForeground) {
        for (final event in newEvents) {
          await _show(
            100000 + event.id,
            'Aviso sonoro${event.unitName == null ? '' : ' · ${event.unitName}'}',
            describeOutputEvent(event, _prefs.unit),
          );
        }
        for (final alert in newAlerts) {
          await _show(
            200000 + alert.id,
            '${alert.isEmergency ? 'Emergência' : alert.isCritical ? 'Alerta crítico' : 'Alerta'}${alert.unitName == null ? '' : ' · ${alert.unitName}'}',
            alert.message,
          );
        }
      }

      final count = alerts.length;
      FlutterForegroundTask.updateService(
        notificationTitle: count == 0 ? 'Estufa monitorada' : f.plural(count, 'alerta ativo', 'alertas ativos'),
        notificationText: 'Última verificação às ${f.time(DateTime.now())}. Avisos chegam mesmo com o app fechado.',
      );
    } on ApiException catch (error) {
      if (error.status == 401) return;
      FlutterForegroundTask.updateService(
        notificationTitle: 'Sem conexão com o servidor',
        notificationText: 'Tentando de novo a cada ${_interval.inSeconds} s. Confira o Wi-Fi do celular.',
      );
    } catch (_) {
      // Resposta inesperada: tenta de novo na próxima rodada.
    } finally {
      _busy = false;
    }
  }

  Future<void> _show(int id, String title, String body) {
    return _notifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: _alertDetails(title)),
    );
  }

  void _sessionExpired() {
    _show(1, 'Entre novamente no app', 'A sessão expirou e os avisos em segundo plano foram pausados.');
    FlutterForegroundTask.stopService();
  }
}

/// Situação atual dos avisos em segundo plano, para a tela de Perfil.
class BackgroundStatus {
  const BackgroundStatus({required this.running, required this.permission, required this.batteryUnrestricted});

  final bool running;
  final NotificationPermission permission;
  final bool batteryUnrestricted;

  bool get permissionGranted => permission == NotificationPermission.granted;
}

/// Liga e desliga o monitoramento em segundo plano a partir do app.
class BackgroundMonitor {
  static const _settings = MethodChannel('monitor/settings');

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void init() {
    if (!supported) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'monitor_servico',
        channelName: 'Monitoramento em segundo plano',
        channelDescription: 'Aviso fixo enquanto o app acompanha a estufa com ele fechado.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(_interval.inMilliseconds),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<BackgroundStatus?> status() async {
    if (!supported) return null;
    return BackgroundStatus(
      running: await FlutterForegroundTask.isRunningService,
      permission: await FlutterForegroundTask.checkNotificationPermission(),
      batteryUnrestricted: await FlutterForegroundTask.isIgnoringBatteryOptimizations,
    );
  }

  /// Pede as permissões e liga o serviço. Devolve nulo ou a explicação do problema.
  static Future<String?> start() async {
    if (!supported) return 'Disponível só no app Android.';
    var permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      permission = await FlutterForegroundTask.requestNotificationPermission();
    }
    if (permission != NotificationPermission.granted) {
      return permission == NotificationPermission.permanently_denied
          ? 'As notificações deste app estão bloqueadas. Toque em "Abrir configurações" e ative-as.'
          : 'Sem a permissão de notificações o app não consegue avisar com ele fechado.';
    }
    // Sem esta liberação o Android pode pausar o serviço para economizar bateria.
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    // Reinicia para o serviço ler a sessão e o servidor atuais.
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.specialUse],
      notificationTitle: 'Estufa monitorada',
      notificationText: 'Avisos chegam mesmo com o app fechado.',
      notificationIcon: _icon,
      callback: backgroundMonitorCallback,
    );
    return result is ServiceRequestFailure ? 'Não foi possível iniciar o monitoramento (${result.error}).' : null;
  }

  static Future<void> stop() async {
    if (supported && await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
  }

  /// Depois de entrar, trocar de servidor ou reabrir o app: mantém o serviço com a sessão atual.
  static Future<void> sync(AppPrefs prefs, {required bool signedIn}) async {
    if (!supported) return;
    try {
      if (!signedIn || !prefs.backgroundAlerts) {
        await stop();
      } else if (!await FlutterForegroundTask.isRunningService) {
        await start();
      }
    } catch (error) {
      debugPrint('Monitoramento em segundo plano: $error');
    }
  }

  static Future<void> openNotificationSettings() async {
    try {
      await _settings.invokeMethod<bool>('notifications');
    } on PlatformException catch (_) {
      await _settings.invokeMethod<bool>('app');
    }
  }

  static Future<void> openBatterySettings() => FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
}
