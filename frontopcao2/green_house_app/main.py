import flet as ft
from utils.theme import get_theme
from views.login_view import LoginView
from views.register_view import RegisterView
from views.home_view import HomeView
from views.device_view import DeviceView
from views.monitor_view import MonitorView

def main(page: ft.Page):
    page.title = "GreenMonitor - Gestão de Estufas"
    page.theme = get_theme()
    page.window_width = 400
    page.window_height = 800
    page.theme_mode = ft.ThemeMode.LIGHT

    def route_change(route):
        page.views.clear()
        
        # Roteamento simples
        if page.route == "/login":
            page.views.append(LoginView(page))
        elif page.route == "/register":
            page.views.append(RegisterView(page))
        elif page.route == "/home":
            page.views.append(HomeView(page))
        elif page.route == "/devices":
            page.views.append(DeviceView(page))
        elif page.route.startswith("/monitor/"):
            unit_id = page.route.split("/")[-1]
            page.views.append(MonitorView(page, unit_id))
        else:
            # Rota padrão: Login
            page.go("/login")
            
        page.update()

    def view_pop(view):
        page.views.pop()
        top_view = page.views[-1]
        page.go(top_view.route)

    page.on_route_change = route_change
    page.on_view_pop = view_pop
    
    # Iniciar na tela de login
    page.go("/login")

if __name__ == "__main__":
    ft.app(target=main)
