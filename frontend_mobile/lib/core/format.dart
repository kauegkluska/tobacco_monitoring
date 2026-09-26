// Formatação em português. A API trabalha em °C; a conversão para °F é só na exibição.

import 'prefs.dart';

String number(double? value, [int digits = 1]) {
  if (value == null || value.isNaN) return '--';
  return value.toStringAsFixed(digits).replaceAll('.', ',');
}

String integer(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

double toFahrenheit(double celsius) => celsius * 9 / 5 + 32;
double toCelsius(double fahrenheit) => (fahrenheit - 32) * 5 / 9;

String unitSymbol(TempUnit unit) => unit == TempUnit.fahrenheit ? '°F' : '°C';
TempUnit otherUnit(TempUnit unit) => unit == TempUnit.fahrenheit ? TempUnit.celsius : TempUnit.fahrenheit;

/// Converte °C para a unidade escolhida.
double? tempValue(double? celsius, TempUnit unit) {
  if (celsius == null) return null;
  return unit == TempUnit.fahrenheit ? toFahrenheit(celsius) : celsius;
}

/// Converte da unidade escolhida para °C (para enviar à API).
double tempToCelsius(double value, TempUnit unit) => unit == TempUnit.fahrenheit ? toCelsius(value) : value;

String temp(double? celsius, TempUnit unit, {int digits = 1}) {
  return '${number(tempValue(celsius, unit), digits)} ${unitSymbol(unit)}';
}

/// "98,6 °F (37,0 °C)"
String tempWithOther(double? celsius, TempUnit unit) {
  if (celsius == null) return '--';
  return '${temp(celsius, unit)} (${temp(celsius, otherUnit(unit))})';
}

String humidity(double? value, {int digits = 1}) => value == null ? '-- %' : '${number(value, digits)}%';

String _two(int value) => value.toString().padLeft(2, '0');

String dateTime(DateTime? value) {
  if (value == null) return '--';
  return '${_two(value.day)}/${_two(value.month)} ${_two(value.hour)}:${_two(value.minute)}';
}

String fullDate(DateTime? value) {
  if (value == null) return '--';
  return '${_two(value.day)}/${_two(value.month)}/${value.year} ${_two(value.hour)}:${_two(value.minute)}';
}

String time(DateTime? value) => value == null ? '--' : '${_two(value.hour)}:${_two(value.minute)}';

String dayMonth(DateTime value) => '${_two(value.day)}/${_two(value.month)}';

/// "agora", "há 12 s", "há 5 min", "há 2 h", "há 3 dias"
String relative(DateTime? value, {DateTime? now}) {
  if (value == null) return 'nunca';
  final seconds = (now ?? DateTime.now()).difference(value).inSeconds;
  if (seconds < 5) return 'agora';
  if (seconds < 60) return 'há $seconds s';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return 'há $minutes min';
  final hours = (minutes / 60).round();
  if (hours < 24) return 'há $hours h';
  final days = (hours / 24).round();
  return 'há $days dia${days == 1 ? '' : 's'}';
}

/// 29 → "1 d 5 h"; 5,4 → "5 h 24 min"
String duration(double? hours) {
  if (hours == null || hours.isNaN) return '--';
  final totalMinutes = (hours * 60).round().clamp(0, 1 << 31);
  final days = totalMinutes ~/ 1440;
  final h = (totalMinutes % 1440) ~/ 60;
  final m = totalMinutes % 60;
  if (days > 0) return h > 0 ? '$days d $h h' : '$days d';
  if (h > 0) return m > 0 ? '$h h $m min' : '$h h';
  return '$m min';
}

double? hoursSince(DateTime? value, {DateTime? now}) {
  if (value == null) return null;
  return (now ?? DateTime.now()).difference(value).inSeconds / 3600;
}

String plural(int count, String singular, [String? pluralForm]) {
  return '$count ${count == 1 ? singular : (pluralForm ?? '${singular}s')}';
}
