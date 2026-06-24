from typing import Awaitable, Callable

import flet as ft

from app.api_client import ApiClient, ApiError
from app.state import AppState
from app.ui.helpers import icon


class BaseView:
    def __init__(
        self,
        page: ft.Page,
        api: ApiClient,
        state: AppState,
        logout: Callable[[], Awaitable[None]] | None = None,
    ):
        self.page = page
        self.api = api
        self.state = state
        self.logout = logout

    async def show_error(self, message: str) -> None:
        self.page.snack_bar = ft.SnackBar(ft.Text(message), open=True)
        await self.page.update_async()

    async def run_api(self, action):
        try:
            return await action()
        except ApiError as exc:
            await self.show_error(exc.message)
            return None

    def nav_actions(self) -> list[ft.Control]:
        return [
            ft.IconButton(
                icon=icon("HOME"),
                tooltip="Dashboard",
                on_click=lambda _: self.page.go("/dashboard"),
            ),
            ft.IconButton(
                icon=icon("NOTIFICATIONS"),
                tooltip="Alerts",
                on_click=lambda _: self.page.go("/alerts"),
            ),
            ft.IconButton(
                icon=icon("QR_CODE_SCANNER"),
                tooltip="Link device",
                on_click=lambda _: self.page.go("/devices/link"),
            ),
            ft.IconButton(
                icon=icon("LOGOUT"),
                tooltip="Logout",
                on_click=lambda _: self.page.run_task(self.logout) if self.logout else None,
            ),
        ]
