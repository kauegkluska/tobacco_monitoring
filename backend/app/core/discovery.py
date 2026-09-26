"""Anuncia a API na rede local por mDNS, para o gateway ESP32 achar o servidor sem IP fixo.

O receiver procura o serviço "_estufa._tcp", lê os IPs no TXT "ips", escolhe o que está na
mesma rede Wi-Fi que ele e confirma com GET /health.
"""

import ipaddress
import logging
import socket

import ifaddr
from zeroconf import IPVersion, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

from core.config import settings

SERVICE_TYPE = "_estufa._tcp.local."
READINGS_PATH = "/readings/readings/"

logger = logging.getLogger("uvicorn.error")


def local_ipv4_addresses() -> list[str]:
    """IPv4 das placas de rede, sem loopback nem endereço automático (169.254.x.x)."""
    found: list[str] = []
    for adapter in ifaddr.get_adapters():
        for ip in adapter.ips:
            if not isinstance(ip.ip, str):
                continue
            address = ipaddress.IPv4Address(ip.ip)
            if address.is_loopback or address.is_link_local or address.is_unspecified:
                continue
            if ip.ip not in found:
                found.append(ip.ip)
    return found


def build_service_info(addresses: list[str], port: int, name: str) -> ServiceInfo:
    host = socket.gethostname().split(".")[0] or "monitor-estufa"
    return ServiceInfo(
        SERVICE_TYPE,
        f"{name}.{SERVICE_TYPE}",
        port=port,
        addresses=[socket.inet_aton(address) for address in addresses],
        # O TXT leva todos os IPs: a biblioteca mDNS do ESP32 só expõe um endereço por resposta.
        properties={"path": READINGS_PATH, "ips": ",".join(addresses), "v": "1"},
        server=f"{host}.local.",
    )


class DiscoveryAnnouncer:
    def __init__(self) -> None:
        self._zeroconf: AsyncZeroconf | None = None
        self._info: ServiceInfo | None = None

    async def start(self) -> None:
        if not settings.MDNS_ENABLED:
            return
        addresses = local_ipv4_addresses()
        if not addresses:
            logger.warning("mDNS: nenhuma placa de rede com IPv4; o gateway precisará do IP fixo.")
            return
        try:
            self._zeroconf = AsyncZeroconf(ip_version=IPVersion.V4Only)
            self._info = build_service_info(addresses, settings.API_PORT, settings.MDNS_NAME)
            await self._zeroconf.async_register_service(self._info, allow_name_change=True)
            logger.info("mDNS: API anunciada como %s na porta %s (%s)", SERVICE_TYPE, settings.API_PORT, ", ".join(addresses))
        except Exception as error:  # noqa: BLE001 - a API funciona mesmo sem o anúncio
            logger.warning("mDNS: não foi possível anunciar a API (%s). O gateway precisará do IP fixo.", error)
            await self.stop()

    async def stop(self) -> None:
        if self._zeroconf is None:
            return
        try:
            if self._info is not None:
                await self._zeroconf.async_unregister_service(self._info)
            await self._zeroconf.async_close()
        finally:
            self._zeroconf = None
            self._info = None
