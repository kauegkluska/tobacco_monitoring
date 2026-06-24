import flet as ft
from utils.theme import AppColors
from utils.api_client import api

def LoginView(page: ft.Page):
    username_field = ft.TextField(label="Usuário", width=300, prefix_icon=ft.icons.PERSON)
    password_field = ft.TextField(label="Senha", width=300, password=True, can_reveal_password=True, prefix_icon=ft.icons.LOCK)
    
    error_text = ft.Text(color=AppColors.DANGER, visible=False)

    def login_click(e):
        success, message = api.login(username_field.value, password_field.value)
        if success:
            page.go("/home")
        else:
            error_text.value = message
            error_text.visible = True
            page.update()

    return ft.View(
        "/login",
        controls=[
            ft.Container(
                content=ft.Column(
                    [
                        ft.Icon(ft.icons.ECO, size=100, color=AppColors.PRIMARY),
                        ft.Text("GreenMonitor", size=30, weight=ft.FontWeight.BOLD, color=AppColors.PRIMARY),
                        ft.Text("Acesse sua estufa inteligente", size=16, color=ft.colors.GREY_700),
                        ft.Container(height=20),
                        username_field,
                        password_field,
                        error_text,
                        ft.ElevatedButton(
                            "Entrar", 
                            on_click=login_click, 
                            width=300, 
                            style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=10))
                        ),
                        ft.TextButton("Não tem uma conta? Registre-se", on_click=lambda _: page.go("/register")),
                    ],
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                alignment=ft.alignment.center,
                expand=True
            )
        ],
        bgcolor=AppColors.BACKGROUND
    )
