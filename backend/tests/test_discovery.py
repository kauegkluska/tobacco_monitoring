from types import SimpleNamespace

from core import discovery


def test_service_info_carries_every_ip_for_the_gateway():
    info = discovery.build_service_info(["192.168.0.14", "192.168.8.10"], 8000, "Monitor de Estufa")
    assert info.type == "_estufa._tcp.local."
    assert info.port == 8000
    assert info.properties[b"ips"] == b"192.168.0.14,192.168.8.10"
    assert info.properties[b"path"] == b"/readings/readings/"
    assert info.parsed_addresses() == ["192.168.0.14", "192.168.8.10"]


def test_only_usable_ipv4_addresses_are_announced(monkeypatch):
    adapters = [
        SimpleNamespace(ips=[SimpleNamespace(ip="127.0.0.1"), SimpleNamespace(ip=("::1", 0, 0))]),
        SimpleNamespace(ips=[SimpleNamespace(ip="169.254.10.2"), SimpleNamespace(ip="192.168.0.14")]),
        SimpleNamespace(ips=[SimpleNamespace(ip="192.168.0.14"), SimpleNamespace(ip="10.0.0.5")]),
    ]
    monkeypatch.setattr(discovery.ifaddr, "get_adapters", lambda: adapters)
    assert discovery.local_ipv4_addresses() == ["192.168.0.14", "10.0.0.5"]
