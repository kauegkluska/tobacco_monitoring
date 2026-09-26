import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TempUnit { fahrenheit, celsius }

/// Preferências deste aparelho: unidade de temperatura, tema, estufa selecionada e aviso sonoro.
class AppPrefs extends ChangeNotifier {
  TempUnit unit = TempUnit.fahrenheit;
  ThemeMode themeMode = ThemeMode.system;
  int? unitId;

  /// Toca e vibra o celular quando o gateway aciona o aviso sonoro (uma saída ligou).
  bool phoneBuzzer = true;

  /// Notificações com o app fechado (serviço em segundo plano no Android). O usuário ativa no Perfil.
  bool backgroundAlerts = false;

  Future<void> load() async {
    final storage = await SharedPreferences.getInstance();
    unit = storage.getString('pref_unit') == 'C' ? TempUnit.celsius : TempUnit.fahrenheit;
    themeMode = switch (storage.getString('pref_theme')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    unitId = storage.getInt('pref_unit_id');
    phoneBuzzer = storage.getBool('pref_phone_buzzer') ?? true;
    backgroundAlerts = storage.getBool('pref_background_alerts') ?? false;
  }

  Future<void> setUnit(TempUnit value) async {
    unit = value;
    notifyListeners();
    final storage = await SharedPreferences.getInstance();
    await storage.setString('pref_unit', value == TempUnit.celsius ? 'C' : 'F');
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
    final storage = await SharedPreferences.getInstance();
    await storage.setString('pref_theme', value.name);
  }

  Future<void> setUnitId(int? value) async {
    if (unitId == value) return;
    unitId = value;
    notifyListeners();
    final storage = await SharedPreferences.getInstance();
    if (value == null) {
      await storage.remove('pref_unit_id');
    } else {
      await storage.setInt('pref_unit_id', value);
    }
  }

  Future<void> setPhoneBuzzer(bool value) async {
    phoneBuzzer = value;
    notifyListeners();
    final storage = await SharedPreferences.getInstance();
    await storage.setBool('pref_phone_buzzer', value);
  }

  Future<void> setBackgroundAlerts(bool value) async {
    backgroundAlerts = value;
    notifyListeners();
    final storage = await SharedPreferences.getInstance();
    await storage.setBool('pref_background_alerts', value);
  }
}
