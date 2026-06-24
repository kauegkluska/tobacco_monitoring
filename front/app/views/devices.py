import flet as ft

from app.api_client import ApiClient, ApiError
from app.state import AppState
from app.ui.helpers import center_alignment, error_banner, icon, page_shell
from app.views.base import BaseView


class DeviceLinkView(BaseView):
    def __init__(self, page: ft.Page, api: ApiClient, state: AppState, logout):
        super().__init__(page, api, state, logout)
        self.device_id = ft.TextField(label="Device ID", autofocus=True)
        self.feedback = ft.Column(spacing=0)
        self.loading = ft.ProgressRing(visible=False)

    def build(self) -> ft.View:
        return ft.View(
            route="/devices/link",
            padding=0,
            controls=[
                page_shell(
                    "Link Device",
                    [
                        ft.Container(
                            width=520,
                            content=ft.Column(
                                spacing=14,
                                horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
                                controls=[
                                    self.feedback,
                                    self.device_id,
                                    ft.FilledButton(
                                        "Link device",
                                        icon=icon("LINK"),
                                        on_click=lambda _: self.page.run_task(self.submit),
                                    ),
                                    ft.Container(alignment=center_alignment(), content=self.loading),
                                ],
                            ),
                        )
                    ],
                    actions=self.nav_actions(),
                )
            ],
        )

    async def submit(self):
        self.feedback.controls.clear()
        value = (self.device_id.value or "").strip()
        if not value:
            self.feedback.controls = [error_banner("Enter a device ID.")]
            await self.page.update_async()
            return

        self.loading.visible = True
        await self.page.update_async()
        try:
            await self.api.link_device(value)
            self.device_id.value = ""
            self.page.snack_bar = ft.SnackBar(ft.Text("Device linked successfully."), open=True)
        except ApiError as exc:
            self.feedback.controls = [error_banner(exc.message)]
        finally:
            self.loading.visible = False
            await self.page.update_async()
