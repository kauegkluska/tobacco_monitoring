import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.status = 0]);

  final String message;
  final int status;

  @override
  String toString() => message;
}

/// Endereço padrão: o emulador Android enxerga o computador em 10.0.2.2.
String defaultBaseUrl() {
  if (kIsWeb) {
    final base = Uri.base;
    if (base.scheme.startsWith('http') && base.port == 8000) return base.origin;
    return 'http://${base.host.isEmpty ? '127.0.0.1' : base.host}:8000';
  }
  if (defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:8000';
  return 'http://127.0.0.1:8000';
}

String _normalize(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

const _fieldNames = {
  'login': 'Login',
  'password': 'Senha',
  'new_password': 'Nova senha',
  'current_password': 'Senha atual',
  'name': 'Nome',
  'controller_id': 'ID do controlador',
  'device_code': 'ID do controlador',
  'mac_address': 'Endereço MAC',
  'temp_min': 'Temperatura mínima',
  'temp_max': 'Temperatura máxima',
  'humidity_min': 'Umidade mínima',
  'humidity_max': 'Umidade máxima',
  'estimated_duration_hours': 'Duração estimada',
  'curing_stage': 'Fase',
};

/// Traduz os erros de validação do FastAPI para frases curtas.
String? describeValidation(dynamic detail) {
  if (detail is! List) return null;
  return detail.map((item) {
    final map = item as Map<String, dynamic>;
    final loc = (map['loc'] as List?) ?? const [];
    final field = _fieldNames[loc.isEmpty ? '' : loc.last.toString()] ?? 'Campo';
    final ctx = (map['ctx'] as Map?) ?? const {};
    return switch (map['type']) {
      'string_too_short' => '$field: mínimo de ${ctx['min_length']} caracteres.',
      'string_too_long' => '$field: máximo de ${ctx['max_length']} caracteres.',
      'missing' => '$field: campo obrigatório.',
      'greater_than_equal' => '$field: o valor mínimo é ${ctx['ge']}.',
      'less_than_equal' => '$field: o valor máximo é ${ctx['le']}.',
      'greater_than' => '$field: deve ser maior que ${ctx['gt']}.',
      'float_parsing' || 'int_parsing' => '$field: informe um número.',
      'value_error' => map['msg'].toString().replaceFirst('Value error, ', ''),
      _ => '$field: ${map['msg']}',
    };
  }).join(' ');
}

/// Cliente da API FastAPI: guarda a sessão, renova o token e padroniza os erros.
class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  static const _timeout = Duration(seconds: 8);
  static const _baseKey = 'api_base_url';
  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';

  final http.Client _client;
  String baseUrl = defaultBaseUrl();
  String? _accessToken;
  String? _refreshToken;
  Future<bool>? _refreshing;

  /// Falso até o usuário (ou a busca na rede) escolher um servidor neste aparelho.
  bool hasSavedBaseUrl = false;

  /// Falso quando a última tentativa de falar com o servidor falhou.
  final ValueNotifier<bool> online = ValueNotifier(true);

  /// Chamado quando a sessão expira e não pode ser renovada.
  VoidCallback? onSessionExpired;

  bool get isAuthenticated => _accessToken != null || _refreshToken != null;

  Future<void> load() async {
    final storage = await SharedPreferences.getInstance();
    final saved = storage.getString(_baseKey);
    hasSavedBaseUrl = saved != null && saved.trim().isNotEmpty;
    if (hasSavedBaseUrl) baseUrl = _normalize(saved!);
    _accessToken = storage.getString(_accessKey);
    _refreshToken = storage.getString(_refreshKey);
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = _normalize(url);
    hasSavedBaseUrl = true;
    final storage = await SharedPreferences.getInstance();
    await storage.setString(_baseKey, baseUrl);
  }

  Future<bool> testConnection([String? url]) async {
    try {
      final response = await _client.get(Uri.parse('${_normalize(url ?? baseUrl)}/health')).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveTokens(Map<String, dynamic>? tokens) async {
    _accessToken = tokens?['access_token'] as String?;
    _refreshToken = tokens?['refresh_token'] as String?;
    final storage = await SharedPreferences.getInstance();
    if (_accessToken == null) {
      await storage.remove(_accessKey);
      await storage.remove(_refreshKey);
    } else {
      await storage.setString(_accessKey, _accessToken!);
      await storage.setString(_refreshKey, _refreshToken ?? '');
    }
  }

  Future<void> login(String login, String password) async {
    await _saveTokens(await postPublic('/auth/login', {'login': login, 'password': password}) as Map<String, dynamic>);
  }

  Future<void> register(String name, String login, String password) async {
    await _saveTokens(
      await postPublic('/auth/register', {'name': name, 'login': login, 'password': password}) as Map<String, dynamic>,
    );
  }

  Future<void> logout() => _saveTokens(null);

  Future<bool> _refresh() {
    final token = _refreshToken;
    if (token == null || token.isEmpty) return Future.value(false);
    return _refreshing ??= () async {
      try {
        final response = await _client
            .post(Uri.parse('$baseUrl/auth/refresh'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'refresh_token': token}))
            .timeout(_timeout);
        if (response.statusCode != 200) return false;
        await _saveTokens(jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true)) as Map<String, dynamic>);
        return true;
      } catch (_) {
        return false;
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<dynamic> _send(String method, String path, {Object? body, bool auth = true, bool retry = true}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (auth && _accessToken != null) headers['Authorization'] = 'Bearer $_accessToken';

    final request = http.Request(method, Uri.parse('$baseUrl$path'))..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);

    http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    } on TimeoutException {
      online.value = false;
      throw ApiException('O servidor demorou para responder ($baseUrl). Verifique a rede.');
    } catch (_) {
      online.value = false;
      throw ApiException('Não foi possível conectar ao servidor ($baseUrl). Verifique se o backend está ligado e se o celular está na mesma rede.');
    }
    online.value = true;

    if (response.statusCode == 401 && auth && retry) {
      if (await _refresh()) return _send(method, path, body: body, auth: auth, retry: false);
      await _saveTokens(null);
      onSessionExpired?.call();
      throw ApiException('Sua sessão expirou. Entre novamente.', 401);
    }

    // allowMalformed: uma resposta fora de UTF-8 (ex.: proxy) não derruba a tela.
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      dynamic detail;
      try {
        detail = (jsonDecode(text) as Map<String, dynamic>)['detail'];
      } catch (_) {
        detail = null;
      }
      final message = describeValidation(detail) ??
          (detail is String ? detail : null) ??
          (response.statusCode >= 500 ? 'O servidor encontrou um erro. Tente novamente em instantes.' : 'Erro ${response.statusCode} ao falar com o servidor.');
      throw ApiException(message, response.statusCode);
    }
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ApiException('Resposta inesperada do servidor ($baseUrl). Confira se o endereço é o da API.', response.statusCode);
    }
  }

  Future<dynamic> get(String path) => _send('GET', path);

  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body ?? const {});

  /// POST sem token (login, cadastro, recuperação de senha).
  Future<dynamic> postPublic(String path, Object body) => _send('POST', path, body: body, auth: false);

  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Igual a [get], mas devolve null quando o recurso não existe (404).
  Future<dynamic> getOrNull(String path) async {
    try {
      return await get(path);
    } on ApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }
}
