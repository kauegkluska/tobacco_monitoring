import flet as ft

from app.theme import ACCENT_GREEN, BG_DARK
from app.views.alertas import screen_alertas
from app.views.dashboard import screen_dashboard
from app.views.estufa import screen_estufa
from app.views.login import screen_login


def _configure_window(page):
    if hasattr(page, "window"):
        page.window.width = 420
        page.window.height = 820
    else:
        page.window_width = 420
        page.window_height = 820


def main(page: ft.Page):
    page.title = "EstufaMonitor"
    page.bgcolor = BG_DARK
    page.theme_mode = ft.ThemeMode.DARK
    page.theme = ft.Theme(color_scheme_seed=ACCENT_GREEN)
    page.padding = 0
    _configure_window(page)

    state = {}

    def navigate(route: str):
        page.views.clear()
        builders = {
            "/login": screen_login,
            "/dashboard": screen_dashboard,
            "/estufa": screen_estufa,
            "/alertas": screen_alertas,
        }
        builder = builders.get(route, screen_login)
        view = builder(page, state, navigate)
        if view:
            page.views.append(view)
        page.update()

    def on_route(event):
        route = event.route if event.route and event.route != "/" else "/login"
        navigate(route)

    page.on_route_change = on_route
    navigate("/login")

