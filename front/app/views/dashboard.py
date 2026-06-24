import flet as ft

from app.api_client import ApiClient, ApiError
from app.state import AppState
from app.ui.helpers import as_list, center_alignment, color, empty_state, error_banner, format_number, icon, page_shell, value_at
from app.views.base import BaseView


class DashboardView(BaseView):
    def __init__(self, page: ft.Page, api: ApiClient, state: AppState, logout):
        super().__init__(page, api, state, logout)
        self.content = ft.Column(expand=True, spacing=12, scroll=ft.ScrollMode.AUTO)
        self.loading = ft.ProgressRing()

    def build(self) -> ft.View:
        self.page.run_task(self.load)
        return ft.View(
            route="/dashboard",
            padding=0,
            controls=[
                page_shell(
                    "Curing Units",
                    [self.content],
                    actions=self.nav_actions(),
                )
            ],
        )

    async def load(self):
        self.content.controls = [ft.Container(alignment=center_alignment(), content=self.loading)]
        await self.page.update_async()
        try:
            units = as_list(await self.api.curing_units())
            if not units:
                self.content.controls = [empty_state("No curing units found.")]
                return

            cards: list[ft.Control] = []
            for unit in units:
                unit_id = str(value_at(unit, "id", "curing_unit_id", default=""))
                latest = await self.api.latest(unit_id) if unit_id else {}
                cards.append(self.unit_card(unit, latest))
            self.content.controls = cards
        except ApiError as exc:
            self.content.controls = [error_banner(exc.message)]
        finally:
            await self.page.update_async()

    def unit_card(self, unit: dict, latest: dict) -> ft.Card:
        unit_id = str(value_at(unit, "id", "curing_unit_id", default=""))
        name = value_at(unit, "name", "label", "description", default=f"Unit {unit_id}")
        temperature = value_at(latest, "temperature", "temp", default=None)
        humidity = value_at(latest, "humidity", "relative_humidity", default=None)

        def open_unit(_):
            self.state.selected_curing_unit = unit
            self.page.go(f"/curing-units/{unit_id}")

        return ft.Card(
            elevation=1,
            content=ft.Container(
                padding=16,
                border_radius=8,
                on_click=open_unit,
                content=ft.Column(
                    spacing=12,
                    controls=[
                        ft.Row(
                            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                            controls=[
                                ft.Text(str(name), size=18, weight=ft.FontWeight.W_600),
                                ft.Icon(icon("CHEVRON_RIGHT")),
                            ],
                        ),
                        ft.Row(
                            wrap=True,
                            spacing=12,
                            controls=[
                                metric("Temperature", format_number(temperature, " C")),
                                metric("Humidity", format_number(humidity, "%")),
                            ],
                        ),
                    ],
                ),
            ),
        )


def metric(label: str, value: str) -> ft.Container:
    return ft.Container(
        width=160,
        padding=12,
        border_radius=8,
        bgcolor=color("GREY_100"),
        content=ft.Column(
            tight=True,
            spacing=4,
            controls=[
                ft.Text(label, size=12, color=color("GREY_700")),
                ft.Text(value, size=22, weight=ft.FontWeight.W_700),
            ],
        ),
    )
