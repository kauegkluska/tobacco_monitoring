import 'package:flutter/widgets.dart';

import 'api.dart';
import 'models.dart';
import 'prefs.dart';

/// Disponibiliza o cliente da API e as preferências para todas as telas.
class AppScope extends InheritedWidget {
  const AppScope({required this.api, required this.prefs, required super.child, super.key});

  final ApiClient api;
  final AppPrefs prefs;

  static AppScope of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope não encontrado');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => api != oldWidget.api || prefs != oldWidget.prefs;
}

/// Estufas e dispositivos do usuário, carregados juntos.
class Overview {
  Overview(this.units, this.devices);

  final List<CuringUnit> units;
  final List<Device> devices;

  Device? deviceFor(CuringUnit? unit) {
    final id = unit?.deviceId;
    if (id == null) return null;
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// Estufa escolhida pelo usuário (lembrada no aparelho) ou a primeira.
  CuringUnit? pick(int? unitId) {
    if (units.isEmpty) return null;
    return units.firstWhere((unit) => unit.id == unitId, orElse: () => units.first);
  }
}

Future<Overview> loadOverview(ApiClient api) async {
  final results = await Future.wait([api.get('/curing_units/'), api.get('/devices/')]);
  return Overview(
    (results[0] as List).map((item) => CuringUnit.fromJson(item as Map<String, dynamic>)).toList(),
    (results[1] as List).map((item) => Device.fromJson(item as Map<String, dynamic>)).toList(),
  );
}
