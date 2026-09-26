import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

// Acha o servidor na rede Wi-Fi sem digitar o IP, como o gateway faz:
// 1. mDNS: o backend se anuncia como "_estufa._tcp" com os IPs do computador no TXT "ips";
// 2. se o mDNS estiver bloqueado na rede, procura a porta da API nos endereços da rede do celular.
// Todo candidato é confirmado com GET /health antes de aparecer na lista.

const serviceType = '_estufa._tcp.local';
const defaultPort = 8000;

class DiscoveredServer {
  const DiscoveredServer({required this.baseUrl, required this.name, required this.viaMdns});

  final String baseUrl;
  final String name;

  /// Achado pelo anúncio mDNS (e não pela varredura da rede).
  final bool viaMdns;

  String get host => Uri.parse(baseUrl).authority;
}

/// Disponível no app instalado; no navegador o endereço já é o da própria página.
bool get discoverySupported => !kIsWeb;

const _settings = MethodChannel('monitor/settings');

/// Placas de rede com IPv4 privado, com o Wi-Fi primeiro.
Future<List<(NetworkInterface, InternetAddress)>> _rankedInterfaces() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  final found = <(int, NetworkInterface, InternetAddress)>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final bytes = address.rawAddress;
      final private = bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168);
      if (!private || address.isLoopback || address.isLinkLocal) continue;
      final name = interface.name.toLowerCase();
      // "wlan0" no Android; "Wi-Fi" no Windows. Dados móveis (rmnet, ccmni) ficam por último.
      final rank = name.contains('wlan') || name.contains('wi-fi') || name.contains('wifi')
          ? 0
          : name.contains('rmnet') || name.contains('ccmni') || name.contains('pdp')
              ? 2
              : 1;
      found.add((rank, interface, address));
    }
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final item in found) (item.$2, item.$3)];
}

/// IPv4 privados deste aparelho, com a rede Wi-Fi primeiro.
Future<List<InternetAddress>> localNetworks() async => [for (final (_, address) in await _rankedInterfaces()) address];

/// Posição da rede do aparelho que contém [ip] (Wi-Fi primeiro); fora de todas fica por último.
int _networkRank(String ip, List<InternetAddress> networks) {
  final prefix = ip.split('.').take(3).join('.');
  final index = networks.indexWhere((network) => network.address.split('.').take(3).join('.') == prefix);
  return index < 0 ? networks.length : index;
}

Future<bool> _isApi(http.Client client, String baseUrl, Duration timeout) async {
  try {
    final response = await client.get(Uri.parse('$baseUrl/health')).timeout(timeout);
    return response.statusCode == 200 && response.body.contains('ok');
  } catch (_) {
    return false;
  }
}

/// Windows não aceita reusePort; Android e iOS aceitam.
Future<RawDatagramSocket> _bindSocket(dynamic host, int port, {bool reuseAddress = true, bool reusePort = true, int ttl = 255}) {
  return RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: reusePort && !Platform.isWindows, ttl: ttl);
}

/// Inicia o cliente mDNS numa única placa de rede, a melhor que aceitar o multicast.
/// Entrar no grupo em todas as placas falha em algumas (VPN, máquinas virtuais).
Future<MDnsClient?> _startClient() async {
  for (final (interface, _) in await _rankedInterfaces()) {
    final client = MDnsClient(rawDatagramSocketFactory: _bindSocket);
    try {
      await client.start(interfacesFactory: (_) async => [interface]);
      return client;
    } catch (error) {
      debugPrint('mDNS indisponível em ${interface.name}: $error');
      try {
        client.stop();
      } catch (_) {}
    }
  }
  return null;
}

/// Respostas do anúncio mDNS: nome do serviço, porta e IPs anunciados.
Future<List<(String, int, List<String>)>> _queryMdns(Duration timeout) async {
  final results = <(String, int, List<String>)>[];
  // O Android descarta multicast sem esta trava do Wi-Fi.
  if (Platform.isAndroid) await _settings.invokeMethod<bool>('multicastLock', true).catchError((_) => false);
  final client = await _startClient();
  try {
    if (client == null) return results;
    final seen = <String>{};
    await for (final ptr in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(serviceType), timeout: timeout)) {
      if (!seen.add(ptr.domainName)) continue;
      final name = ptr.domainName.split('._estufa').first;
      await for (final srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName), timeout: timeout)) {
        final ips = <String>[];
        await for (final txt in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName), timeout: timeout)) {
          for (final entry in txt.text.split('\n')) {
            if (entry.startsWith('ips=')) ips.addAll(entry.substring(4).split(',').map((ip) => ip.trim()).where((ip) => ip.isNotEmpty));
          }
        }
        await for (final record in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: timeout)) {
          if (!ips.contains(record.address.address)) ips.add(record.address.address);
        }
        results.add((name, srv.port, ips));
      }
    }
  } catch (error) {
    debugPrint('mDNS indisponível: $error');
  } finally {
    client?.stop();
    if (Platform.isAndroid) await _settings.invokeMethod<bool>('multicastLock', false).catchError((_) => false);
  }
  return results;
}

/// Procura a porta da API em toda a rede /24 de cada endereço do aparelho (no máximo duas redes).
Future<List<DiscoveredServer>> _scanNetworks(http.Client client, List<InternetAddress> networks, int port) async {
  final found = <DiscoveredServer>[];
  const timeout = Duration(milliseconds: 900);
  const parallel = 48;
  for (final network in networks.take(2)) {
    final bytes = network.rawAddress;
    final hosts = [for (var last = 1; last < 255; last++) '${bytes[0]}.${bytes[1]}.${bytes[2]}.$last'];
    for (var start = 0; start < hosts.length; start += parallel) {
      final batch = hosts.skip(start).take(parallel);
      final checks = await Future.wait(batch.map((host) async {
        final base = 'http://$host:$port';
        return await _isApi(client, base, timeout) ? base : null;
      }));
      for (final base in checks.whereType<String>()) {
        found.add(DiscoveredServer(baseUrl: base, name: 'Servidor em ${Uri.parse(base).host}', viaMdns: false));
      }
    }
    if (found.isNotEmpty) break;
  }
  return found;
}

/// Procura servidores da API na rede local. Lista vazia quando nada respondeu.
Future<List<DiscoveredServer>> discoverServers({http.Client? client, bool useMdns = true, bool scanFallback = true}) async {
  if (!discoverySupported) return const [];
  final http_ = client ?? http.Client();
  try {
    final networks = await localNetworks();
    final found = <String, DiscoveredServer>{};

    final announced = useMdns ? await _queryMdns(const Duration(seconds: 3)) : const <(String, int, List<String>)>[];
    for (final (name, port, ips) in announced) {
      // IPs da rede Wi-Fi do celular primeiro; o computador pode ter várias placas de rede.
      final ordered = [...ips]..sort((a, b) => _networkRank(a, networks).compareTo(_networkRank(b, networks)));
      for (final ip in ordered) {
        final base = 'http://$ip:$port';
        if (await _isApi(http_, base, const Duration(milliseconds: 1500))) {
          found.putIfAbsent(name, () => DiscoveredServer(baseUrl: base, name: name, viaMdns: true));
          break;
        }
      }
    }

    if (found.isEmpty && scanFallback) {
      for (final server in await _scanNetworks(http_, networks, defaultPort)) {
        found.putIfAbsent(server.baseUrl, () => server);
      }
    }
    return found.values.toList();
  } finally {
    if (client == null) http_.close();
  }
}
