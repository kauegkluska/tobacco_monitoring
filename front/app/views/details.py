import flet as ft

from app.api_client import ApiClient, ApiError
from app.state import AppState
from app.ui.helpers import as_list, center_alignment, color, empty_state, error_banner, format_number, format_timestamp, page_shell, value_at
from app.views.base import BaseView
from app.views.dashboard import metric


class CuringUnitDetailsView(BaseView):
    def __init__(self, page: ft.Page, api: ApiClient, state: AppState, unit_id: str, logout):
        super().__init__(page, api, state, logout)
        self.unit_id = unit_id
        self.content = ft.Column(expand=True, spacing=16, scroll=ft.ScrollMode.AUTO)

    def build(self) -> ft.View:
        self.page.run_task(self.load)
        return ft.View(
            route=f"/curing-units/{self.unit_id}",
            padding=0,
            controls=[page_shell("Curing Unit Details", [self.content], actions=self.nav_actions())],
        )

    async def load(self):
        self.content.controls = [ft.Container(alignment=center_alignment(), content=ft.ProgressRing())]
        await self.page.update_async()

        try:
            unit = await self.api.curing_unit(self.unit_id)
            latest = await self.api.latest(self.unit_id)
            readings = as_list(await self.api.readings(self.unit_id))
            alerts = as_list(await self.api.unit_alerts(self.unit_id))
            self.state.selected_curing_unit = unit if isinstance(unit, dict) else self.state.selected_curing_unit
            self.content.controls = [
                self.summary(unit or {}, latest or {}),
                ft.Text("Latest readings", size=18, weight=ft.FontWeight.W_700),
                self.readings_list(readings),
                ft.Text("Alerts", size=18, weight=ft.FontWeight.W_700),
                self.alerts_list(alerts),
            ]
        except ApiError as exc:
            self.content.controls = [error_banner(exc.message)]
        finally:
            await self.page.update_async()

    def summary(self, unit: dict, latest: dict) -> ft.Control:
        name = value_at(unit, "name", "label", "description", default=f"Unit {self.unit_id}")
        stage = value_at(unit, "stage", "current_stage", default=value_at(latest, "stage", default="-"))
        temperature = value_at(latest, "temperature", "temp", default=None)
        humidity = value_at(latest, "humidity", "relative_humidity", default=None)
        return ft.Column(
            spacing=12,
            controls=[
                ft.Text(str(name), size=24, weight=ft.FontWeight.W_700),
                ft.Row(
                    wrap=True,
                    spacing=12,
                    controls=[
                        metric("Current temperature", format_number(temperature, " C")),
                        metric("Current humidity", format_number(humidity, "%")),
                        metric("Stage", str(stage)),
                    ],
                ),
            ],
        )

    def readings_list(self, readings: list) -> ft.Control:
        if not readings:
            return empty_state("No readings found for this curing unit.")
        rows = []
        for reading in readings[:20]:
            rows.append(
                ft.Container(
                    padding=12,
                    border_radius=8,
                    bgcolor=color("GREY_100"),
                    content=ft.Row(
                        wrap=True,
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                        controls=[
                            ft.Text(format_timestamp(value_at(reading, "timestamp", "created_at", default=""))),
                            ft.Text(format_number(value_at(reading, "temperature", "temp", default=None), " C")),
                            ft.Text(format_number(value_at(reading, "humidity", "relative_humidity", default=None), "%")),
                        ],
                    ),
                )
            )
        return ft.Column(spacing=8, controls=rows)

    def alerts_list(self, alerts: list) -> ft.Control:
        if not alerts:
            return empty_state("No alerts found for this curing unit.")
        return ft.Column(
            spacing=8,
            controls=[
                ft.Container(
                    padding=12,
                    border_radius=8,
                    bgcolor=color("RED_50") if value_at(alert, "is_active", "active", default=False) else color("GREY_100"),
                    content=ft.Column(
                        tight=True,
                        spacing=4,
                        controls=[
                            ft.Text(str(value_at(alert, "type", "alert_type", default="Alert")), weight=ft.FontWeight.W_700),
                            ft.Text(str(value_at(alert, "message", "description", default="-"))),
                            ft.Text(format_timestamp(value_at(alert, "timestamp", "created_at", default="")), size=12),
                        ],
                    ),
                )
                for alert in alerts[:20]
            ],
        )
