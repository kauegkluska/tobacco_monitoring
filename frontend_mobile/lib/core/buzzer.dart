import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'format.dart' as f;
import 'models.dart';
import 'prefs.dart';

/// Repete no celular o aviso sonoro do gateway: três bipes curtos e vibração.
class PhoneBuzzer {
  AudioPlayer? _player;

  Future<void> play() async {
    try {
      final player = _player ??= AudioPlayer()..setReleaseMode(ReleaseMode.stop);
      await player.stop();
      await player.play(AssetSource('sounds/buzzer.wav'), volume: 1);
    } catch (error) {
      // Sem áudio (navegador bloqueou, plugin indisponível): a vibração e o aviso na tela bastam.
      debugPrint('Aviso sonoro indisponível: $error');
    }
    try {
      await HapticFeedback.vibrate();
    } catch (_) {}
  }

  Future<void> dispose() async => _player?.dispose();
}

/// Texto curto de uma mudança de saída, ex.: "Ventoinhas ligou (automático, 46,0 °C)".
String describeOutputEvent(OutputEvent event, TempUnit unit) {
  final action = event.turnedOn ? 'ligou' : 'desligou';
  final value = event.value == null
      ? null
      : event.metric == 'temperature'
          ? f.temp(event.value, unit)
          : f.humidity(event.value);
  final cause = switch (event.cause) {
    'manual' => 'pelo app',
    'stopped' => 'secagem parada',
    _ => value == null ? 'automático' : 'automático, $value',
  };
  return '${event.displayName} $action ($cause)';
}
