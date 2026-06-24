import flet as ft

from app.api_client import ApiClient, ApiError
from app.state import AppState
from app.ui.helpers import as_list, center_alignment, color, empty_state, error_banner, format_timestamp, page_shell, value_at
from app.views.base import BaseView


class AlertsView(BaseView):
    def __init__(self, page: ft.Page, api: ApiClient, state: AppState, logout):
        super().__init__(page, api, state, logout)
        self.content = ft.Column(expand=True, spacing=10, scroll=ft.ScrollMode.AUTO)

    def build(self) -> ft.View:
        self.page.run_task(self.load)
        return ft.View(
            route="/alerts",
            padding=0,
            controls=[page_shell("Alerts", [self.content], actions=self.nav_actions())],
        )

    async def load(self):
        self.content.controls = [ft.Container(alignment=center_alignment(), content=ft.ProgressRing())]
        await self.page.update_async()
        try:
            alerts = as_list(await self.api.alerts())
            if not alerts:
                self.content.controls = [empty_state("No alerts found.")]
            else:
                self.content.controls = [self.alert_card(alert) for alert in alerts]
        except ApiError as exc:
            self.content.controls = [error_banner(exc.message)]
        finally:
            await self.page.update_async()

    def alert_card(self, alert: dict) -> ft.Card:
        active = bool(value_at(alert, "is_active", "active", default=False))
        return ft.Card(
            elevation=1,
            content=ft.Container(
                padding=14,
                border_radius=8,
                content=ft.Column(
                    tight=True,
                    spacing=8,
                    controls=[
                        ft.Row(
                            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                            controls=[
                                ft.Text(str(value_at(alert, "type", "alert_type", default="Alert")), weight=ft.FontWeight.W_700),
                                ft.Text("Active" if active else "Inactive", color=color("RED_700") if active else color("GREY_700")),
                            ],
                        ),
                        ft.Text(str(value_at(alert, "message", "description", default="-"))),
                        ft.Text(format_timestamp(value_at(alert, "timestamp", "created_at", default="")), size=12),
                    ],
                ),
            ),
        )
