from typing import Any

import httpx

from app.config import API_BASE_URL, REQUEST_TIMEOUT_SECONDS


class ApiError(Exception):
    def __init__(self, message: str, status_code: int | None = None):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


class ApiClient:
    def __init__(self, base_url: str = API_BASE_URL):
        self.base_url = base_url.rstrip("/")
        self.token: str | None = None
        self._client = httpx.AsyncClient(
            base_url=self.base_url,
            timeout=REQUEST_TIMEOUT_SECONDS,
        )

    def set_token(self, token: str | None) -> None:
        self.token = token

    async def close(self) -> None:
        if not self._client.is_closed:
            await self._client.aclose()

    def _headers(self) -> dict[str, str]:
        if not self.token:
            return {}
        return {"Authorization": f"Bearer {self.token}"}

    async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        try:
            response = await self._client.request(
                method,
                path,
                headers=self._headers(),
                **kwargs,
            )
        except httpx.ConnectError as exc:
            raise ApiError("Could not connect to the API at http://localhost:8000.") from exc
        except httpx.TimeoutException as exc:
            raise ApiError("The API request timed out. Please try again.") from exc
        except httpx.HTTPError as exc:
            raise ApiError("Network error while contacting the API.") from exc

        if response.status_code >= 400:
            raise ApiError(self._error_message(response), response.status_code)

        if not response.content:
            return None

        try:
            return response.json()
        except ValueError as exc:
            raise ApiError("The API returned an invalid JSON response.", response.status_code) from exc

    @staticmethod
    def _error_message(response: httpx.Response) -> str:
        try:
            payload = response.json()
        except ValueError:
            return response.text or f"Request failed with status {response.status_code}."

        detail = payload.get("detail") if isinstance(payload, dict) else None
        if isinstance(detail, str):
            return detail
        if isinstance(detail, list):
            return "; ".join(str(item.get("msg", item)) for item in detail)
        if isinstance(payload, dict):
            for key in ("message", "error"):
                if payload.get(key):
                    return str(payload[key])
        return f"Request failed with status {response.status_code}."

    async def register(self, name: str, login: str, password: str) -> Any:
        return await self._request("POST", "/auth/register", json={"name": name, "login": login, "password": password})

    async def login(self, login: str, password: str) -> Any:
        return await self._request("POST", "/auth/login", json={"login": login, "password": password})

    async def me(self) -> Any:
        return await self._request("GET", "/users/me")

    async def curing_units(self) -> Any:
        return await self._request("GET", "/curing_units")

    async def curing_unit(self, unit_id: str) -> Any:
        return await self._request("GET", f"/curing_units/{unit_id}")

    async def readings(self, unit_id: str) -> Any:
        return await self._request("GET", f"/curing_units/{unit_id}/readings")

    async def latest(self, unit_id: str) -> Any:
        return await self._request("GET", f"/curing_units/{unit_id}/latest")

    async def alerts(self) -> Any:
        return await self._request("GET", "/alerts")

    async def unit_alerts(self, unit_id: str) -> Any:
        return await self._request("GET", f"/curing_units/{unit_id}/alerts")

    async def link_device(self, device_id: str) -> Any:
        return await self._request("POST", "/devices/link", json={"device_id": device_id})
