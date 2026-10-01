// Modelos da API. Temperaturas em °C; datas convertidas para o horário local.

double? _double(dynamic value) => value == null ? null : (value as num).toDouble();
int? _int(dynamic value) => value == null ? null : (value as num).toInt();
DateTime? _date(dynamic value) => value == null ? null : DateTime.tryParse(value.toString())?.toLocal();

/// As quatro fases da cura, na ordem: chave da API (usada nas cores) e nome.
const curingPhases = [
  (key: 'amarelacao', name: 'Amarelação'),
  (key: 'murchamento', name: 'Murchamento'),
  (key: 'secagem_folha', name: 'Secagem da folha'),
  (key: 'secagem_talo', name: 'Secagem do talo'),
];

const finishedStage = 'Finalizado';

final curingStages = ['Não iniciado', for (final phase in curingPhases) phase.name, finishedStage];

String? phaseKeyOf(String stage) {
  for (final phase in curingPhases) {
    if (phase.name == stage) return phase.key;
  }
  return null;
}

class PhaseCheck {
  PhaseCheck.fromJson(Map<String, dynamic> json)
      : label = json['label']?.toString() ?? '',
        ok = json['ok'] == true;

  final String label;
  final bool ok;
}

/// Fase em andamento (só com a secagem ligada): faixa de referência e o que falta para avançar.
class PhaseStatus {
  PhaseStatus.fromJson(Map<String, dynamic> json)
      : key = json['key']?.toString() ?? '',
        name = json['name']?.toString() ?? '',
        number = _int(json['number']) ?? 1,
        total = _int(json['total']) ?? 4,
        limits = Limits(
          tempMin: _double(json['temp_min'])!,
          tempMax: _double(json['temp_max'])!,
          humidityMin: _double(json['humidity_min'])!,
          humidityMax: _double(json['humidity_max'])!,
        ),
        minHours = _double(json['min_hours']) ?? 0,
        maxHours = _double(json['max_hours']) ?? 0,
        hours = _double(json['hours']) ?? 0,
        overdue = json['overdue'] == true,
        nextStage = json['next_stage']?.toString() ?? finishedStage,
        ready = json['ready'] == true,
        checks = ((json['checks'] as List?) ?? const []).map((item) => PhaseCheck.fromJson(item as Map<String, dynamic>)).toList(),
        visualCheck = json['visual_check']?.toString() ?? '';

  final String key;
  final String name;
  final int number;
  final int total;
  final Limits limits;
  final double minHours;
  final double maxHours;
  final double hours;
  final bool overdue;
  final String nextStage;
  final bool ready;
  final List<PhaseCheck> checks;
  final String visualCheck;

  bool get finishes => nextStage == finishedStage;
}

class CuringUnit {
  CuringUnit.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        name = json['name']?.toString() ?? 'Estufa',
        stage = json['curing_stage']?.toString() ?? 'Não iniciado',
        deviceId = _int(json['device_id']),
        stageStartedAt = _date(json['stage_started_at']),
        dryingStartedAt = _date(json['drying_started_at']),
        estimatedHours = _double(json['estimated_duration_hours']),
        estimatedCompletion = _date(json['estimated_completion_at']),
        deviceCode = json['device_code']?.toString(),
        deviceStatus = json['device_status']?.toString(),
        phase = json['phase'] == null ? null : PhaseStatus.fromJson(json['phase'] as Map<String, dynamic>);

  final int id;
  final String name;
  final String stage;
  final int? deviceId;
  final DateTime? stageStartedAt;
  final DateTime? dryingStartedAt;
  final double? estimatedHours;
  final DateTime? estimatedCompletion;
  final String? deviceCode;
  final String? deviceStatus;
  final PhaseStatus? phase;

  bool get isFinished => stage == finishedStage;

  /// Faixa segura: a da fase em andamento; sem secagem, os limites do dispositivo.
  Limits limitsWith(Device? device) => phase?.limits ?? device?.limits ?? Limits.defaults;

  bool get isDrying => dryingStartedAt != null;
}

class Limits {
  const Limits({required this.tempMin, required this.tempMax, required this.humidityMin, required this.humidityMax});

  static const defaults = Limits(tempMin: 35, tempMax: 75, humidityMin: 40, humidityMax: 90);

  final double tempMin;
  final double tempMax;
  final double humidityMin;
  final double humidityMax;
}

class Device {
  Device.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        code = json['device_code']?.toString() ?? 'ESP32-M${json['id']}',
        macAddress = json['mac_address']?.toString(),
        loraId = json['lora_id']?.toString(),
        hardwareModel = json['hardware_model']?.toString(),
        firmwareVersion = json['firmware_version']?.toString(),
        battery = _int(json['battery_level']),
        rssi = _int(json['rssi']),
        snr = _double(json['snr']),
        lastSeen = _date(json['last_seen_at']),
        online = json['status'] == 'online',
        unitId = _int(json['curing_unit_id']),
        unitName = json['curing_unit_name']?.toString(),
        limits = Limits(
          tempMin: _double(json['temp_min']) ?? Limits.defaults.tempMin,
          tempMax: _double(json['temp_max']) ?? Limits.defaults.tempMax,
          humidityMin: _double(json['humidity_min']) ?? Limits.defaults.humidityMin,
          humidityMax: _double(json['humidity_max']) ?? Limits.defaults.humidityMax,
        );

  final int id;
  final String code;
  final String? macAddress;
  final String? loraId;
  final String? hardwareModel;
  final String? firmwareVersion;
  final int? battery;
  final int? rssi;
  final double? snr;
  final DateTime? lastSeen;
  final bool online;
  final int? unitId;
  final String? unitName;
  final Limits limits;

  bool get batteryLow => battery != null && battery! <= 25;

  String get signalQuality {
    final value = rssi;
    if (value == null) return 'Não informado';
    if (value >= -70) return 'Ótimo';
    if (value >= -85) return 'Bom';
    if (value >= -100) return 'Fraco';
    return 'Muito fraco';
  }
}

class Reading {
  Reading.fromJson(Map<String, dynamic> json)
      : temperature = _double(json['temperature'])!,
        humidity = _double(json['humidity'])!,
        timestamp = _date(json['timestamp']) ?? DateTime.now();

  final double temperature;
  final double humidity;
  final DateTime timestamp;
}

class AlertItem {
  AlertItem.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        type = json['type']?.toString() ?? 'Ocorrência',
        message = json['message']?.toString() ?? '',
        severity = json['severity']?.toString() ?? 'warning',
        isActive = json['is_active'] == true,
        value = _double(json['value']),
        threshold = _double(json['threshold']),
        timestamp = _date(json['timestamp']) ?? DateTime.now(),
        acknowledgedAt = _date(json['acknowledged_at']),
        resolvedAt = _date(json['resolved_at']),
        unitId = json['curing_unit_id'] as int,
        unitName = json['curing_unit_name']?.toString();

  final int id;
  final String type;
  final String message;
  final String severity;
  final bool isActive;
  final double? value;
  final double? threshold;
  final DateTime timestamp;
  final DateTime? acknowledgedAt;
  final DateTime? resolvedAt;
  final int unitId;
  final String? unitName;

  /// Crítico ou emergência: pede ação imediata.
  bool get isCritical => severity == 'critical' || severity == 'emergency';
  bool get isEmergency => severity == 'emergency';
  String get severityLabel => isEmergency ? 'Emergência' : (isCritical ? 'Crítico' : 'Atenção');
  bool get isTemperature => type.startsWith('Temperatura');
  bool get isHigh => type.endsWith('alta');
}

class SeriesPoint {
  SeriesPoint.fromJson(Map<String, dynamic> json)
      : time = _date(json['timestamp'])!,
        temperature = _double(json['temperature'])!,
        temperatureMin = _double(json['temperature_min'])!,
        temperatureMax = _double(json['temperature_max'])!,
        humidity = _double(json['humidity'])!,
        humidityMin = _double(json['humidity_min'])!,
        humidityMax = _double(json['humidity_max'])!,
        count = json['count'] as int;

  final DateTime time;
  final double temperature;
  final double temperatureMin;
  final double temperatureMax;
  final double humidity;
  final double humidityMin;
  final double humidityMax;
  final int count;
}

class SeriesStats {
  SeriesStats.fromJson(Map<String, dynamic> json)
      : count = json['count'] as int? ?? 0,
        temperatureMin = _double(json['temperature_min']),
        temperatureAvg = _double(json['temperature_avg']),
        temperatureMax = _double(json['temperature_max']),
        humidityMin = _double(json['humidity_min']),
        humidityAvg = _double(json['humidity_avg']),
        humidityMax = _double(json['humidity_max']),
        lastAt = _date(json['last_at']);

  final int count;
  final double? temperatureMin;
  final double? temperatureAvg;
  final double? temperatureMax;
  final double? humidityMin;
  final double? humidityAvg;
  final double? humidityMax;
  final DateTime? lastAt;
}

/// Trecho do período em que a estufa ficou numa fase da cura.
class SeriesPhase {
  SeriesPhase.fromJson(Map<String, dynamic> json)
      : stage = json['stage']?.toString() ?? '',
        key = json['key']?.toString(),
        start = _date(json['started_at'])!,
        end = _date(json['ended_at'])!,
        tempMin = _double(json['temp_min']),
        tempMax = _double(json['temp_max']),
        humidityMin = _double(json['humidity_min']),
        humidityMax = _double(json['humidity_max']);

  final String stage;
  final String? key;
  final DateTime start;
  final DateTime end;
  final double? tempMin;
  final double? tempMax;
  final double? humidityMin;
  final double? humidityMax;

  bool contains(DateTime time) => !time.isBefore(start) && !time.isAfter(end);
}

class Series {
  Series.fromJson(Map<String, dynamic> json)
      : since = _date(json['since'])!,
        until = _date(json['until'])!,
        bucketSeconds = json['bucket_seconds'] as int,
        points = (json['points'] as List).map((item) => SeriesPoint.fromJson(item as Map<String, dynamic>)).toList(),
        stats = SeriesStats.fromJson(json['stats'] as Map<String, dynamic>),
        phases = ((json['phases'] as List?) ?? const []).map((item) => SeriesPhase.fromJson(item as Map<String, dynamic>)).toList();

  final DateTime since;
  final DateTime until;
  final int bucketSeconds;
  final List<SeriesPoint> points;
  final SeriesStats stats;
  final List<SeriesPhase> phases;

  SeriesPhase? phaseAt(DateTime time) {
    for (final phase in phases) {
      if (phase.contains(time)) return phase;
    }
    return null;
  }
}

class UserProfile {
  UserProfile.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        name = json['name']?.toString() ?? '',
        login = json['login']?.toString() ?? '';

  final int id;
  final String name;
  final String login;
}

/// "ok" | "high" | "low" | null
String? rangeState(double? value, double min, double max) {
  if (value == null) return null;
  if (value > max) return 'high';
  if (value < min) return 'low';
  return 'ok';
}

/// Regras do modo automático das saídas (mesmos códigos da API).
const outputTriggers = {
  'humidity_out': 'Umidade fora da faixa segura',
  'humidity_high': 'Umidade acima do máximo',
  'humidity_low': 'Umidade abaixo do mínimo',
  'temperature_out': 'Temperatura fora da faixa segura',
  'temperature_high': 'Temperatura acima do máximo',
  'temperature_low': 'Temperatura abaixo do mínimo',
};

/// Saída (relé do sender) comandada pela API: "auto" segue [trigger]; "on"/"off" são manuais.
class OutputState {
  OutputState.fromJson(Map<String, dynamic> json)
      : name = json['name']?.toString() ?? 'Saída',
        relay = _int(json['relay']) ?? 1,
        pin = json['pin']?.toString() ?? '',
        mode = json['mode']?.toString() ?? 'auto',
        trigger = json['trigger']?.toString() ?? 'humidity_out',
        on = json['on'] == true,
        reason = json['reason']?.toString() ?? '',
        confirmedOn = json['confirmed_on'] as bool?,
        inSync = json['in_sync'] == true;

  final String name;
  final int relay;
  final String pin;
  final String mode;
  final String trigger;

  /// Comando enviado ao gateway.
  final bool on;
  final String reason;

  /// Estado informado pelo sender; nulo enquanto ele não informar.
  final bool? confirmedOn;

  /// O sender informou há pouco o mesmo estado do comando.
  final bool inSync;

  String get relayLabel => pin.isEmpty ? 'Relé $relay' : 'Relé $relay · $pin';
}

/// Mudança no comando de uma saída. Quando ela liga, o gateway toca o aviso sonoro por 2 s.
class OutputEvent {
  OutputEvent.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        timestamp = _date(json['timestamp']) ?? DateTime.now(),
        output = json['output']?.toString() ?? 'humidity',
        outputName = json['output_name']?.toString(),
        turnedOn = json['turned_on'] == true,
        buzzer = json['buzzer'] == true,
        cause = json['cause']?.toString() ?? 'auto',
        metric = json['metric']?.toString(),
        value = _double(json['value']),
        unitId = json['curing_unit_id'] as int,
        unitName = json['curing_unit_name']?.toString();

  final int id;
  final DateTime timestamp;
  final String output;
  final String? outputName;
  final bool turnedOn;
  final bool buzzer;
  final String cause;

  /// Grandeza de [value]: "temperature" (°C) ou "humidity" (%).
  final String? metric;
  final double? value;
  final int unitId;
  final String? unitName;

  String get displayName => outputName ?? (output == 'temperature' ? 'Saída de temperatura' : 'Saída de umidade');
}

class Outputs {
  Outputs.fromJson(Map<String, dynamic> json)
      : unitId = json['curing_unit_id'] as int,
        isDrying = json['is_drying'] == true,
        confirmedAt = _date(json['confirmed_at']),
        humidity = OutputState.fromJson(json['humidity'] as Map<String, dynamic>),
        temperature = OutputState.fromJson(json['temperature'] as Map<String, dynamic>),
        lastBuzzer = json['last_buzzer'] == null ? null : OutputEvent.fromJson(json['last_buzzer'] as Map<String, dynamic>),
        events = ((json['events'] as List?) ?? const []).map((item) => OutputEvent.fromJson(item as Map<String, dynamic>)).toList();

  final int unitId;
  final bool isDrying;

  /// Última vez que o sender informou o estado dos relés.
  final DateTime? confirmedAt;
  final OutputState humidity;
  final OutputState temperature;
  final OutputEvent? lastBuzzer;
  final List<OutputEvent> events;
}
