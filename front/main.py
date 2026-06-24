import flet as ft

from app.api_client import ApiClient
from app.state import AppState
from app.views.alerts import AlertsView
from app.views.auth import LoginView, RegisterView
from app.views.dashboard import DashboardView
from app.views.devices import DeviceLinkView
from app.views.details import CuringUnitDetailsView


async def main(page: ft.Page):
    page.title = "Estufas IoT"
    page.theme_mode = ft.ThemeMode.LIGHT
    page.padding = 0
    page.window_width = 420
    page.window_height = 800

    api = ApiClient()
    state = AppState()

    # -------------------------
    # LOGOUT
    # -------------------------
    async def logout(e=None):
        state.clear()
        try:
            await api.close()
        except Exception:
            pass
        page.go("/login")

    # -------------------------
    # AUTH CHECK
    # -------------------------
    def require_auth():
        if not state.jwt_token:
            page.go("/login")
            return False
        return True

    # -------------------------
    # ROUTING
    # -------------------------
    def route_change(e):
        page.views.clear()
        route = page.route or "/login"

        if route == "/register":
            page.views.append(RegisterView(page, api, state).build())

        elif route == "/login":
            page.views.append(LoginView(page, api, state).build())

        elif route == "/dashboard":
            if not require_auth():
                return
            page.views.append(DashboardView(page, api, state, logout).build())

        elif route == "/alerts":
            if not require_auth():
                return
            page.views.append(AlertsView(page, api, state, logout).build())

        elif route == "/devices/link":
            if not require_auth():
                return
            page.views.append(DeviceLinkView(page, api, state, logout).build())

        elif route.startswith("/curing-units/"):
            if not require_auth():
                return
            unit_id = route.replace("/curing-units/", "")
            page.views.append(
                CuringUnitDetailsView(page, api, state, unit_id, logout).build()
            )

        else:
            # fallback seguro
            page.go("/login")
            return

        page.update()

    # -------------------------
    # BACK NAVIGATION
    # -------------------------
    def view_pop(e):
        if len(page.views) > 1:
            page.views.pop()
            top_view = page.views[-1]
            page.go(top_view.route)
        else:
            page.go("/dashboard" if state.jwt_token else "/login")

    # -------------------------
    # EVENT BINDING
    # -------------------------
    page.on_route_change = route_change
    page.on_view_pop = view_pop

    # start safe
    page.go("/login")


if __name__ == "__main__":
    ft.app(target=main)