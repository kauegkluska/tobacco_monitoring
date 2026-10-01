import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Dados lidos do QR code do sender.
class ScannedDevice {
  const ScannedDevice({required this.raw, this.code, this.mac});

  final String raw;
  final String? code;
  final String? mac;
}

/// Interpreta os formatos aceitos: JSON ({"controller_id": ...}), "ID=ESP32-...;..." ou só o ID.
ScannedDevice parseDeviceQr(String raw) {
  final text = raw.trim();
  String? code;
  String? mac;
  if (text.startsWith('{')) {
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      code = (data['controller_id'] ?? data['device_code'] ?? data['id'])?.toString();
      mac = (data['mac_address'] ?? data['mac'])?.toString();
    } catch (_) {
      // Não é JSON válido; tenta os outros formatos.
    }
  }
  code ??= RegExp(r'(?:ID|controller_id)=([A-Za-z0-9\-_]+)', caseSensitive: false).firstMatch(text)?.group(1);
  code ??= RegExp(r'(ESP32-[A-Za-z0-9\-_]+)', caseSensitive: false).firstMatch(text)?.group(1);
  mac ??= RegExp(r'([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}').firstMatch(text)?.group(0)?.toUpperCase();
  if (code == null && !text.contains(' ') && text.length < 40) code = text;
  return ScannedDevice(raw: text, code: code, mac: mac);
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool done = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (done) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      done = true;
      Navigator.pop(context, parseDeviceQr(raw));
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Ler QR code do sensor'),
        actions: [
          IconButton(tooltip: 'Lanterna', icon: const Icon(Icons.flashlight_on_outlined), onPressed: controller.toggleTorch),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Não foi possível abrir a câmera. Libere a permissão nas configurações ou digite o ID.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)),
            ),
          ),
          const Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Text(
              'Aponte para o QR code do sensor.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
