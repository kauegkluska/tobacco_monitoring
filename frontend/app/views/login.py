import flet as ft

from app.data.mock_data import MOCK_USER
from app.theme import ACCENT_GREEN, ACCENT_RED, BG_CARD, BG_CARD2, BG_DARK, BORDER_COLOR, TEXT_MUTED, TEXT_PRIMARY


def screen_login(page, state, navigate):
    email = ft.TextField(
        label="E-mail",
        prefix_icon=ft.icons.EMAIL_OUTLINED,
        keyboard_type=ft.KeyboardType.EMAIL,
        border_color=BORDER_COLOR,
        focused_border_color=ACCENT_GREEN,
        color=TEXT_PRIMARY,
        label_style=ft.TextStyle(color=TEXT_MUTED),
        bgcolor=BG_CARD2,
        border_radius=10,
    )
    senha = ft.TextField(
        label="Senha",
        prefix_icon=ft.icons.LOCK_OUTLINE,
        password=True,
        can_reveal_password=True,
        border_color=BORDER_COLOR,
        focused_border_color=ACCENT_GREEN,
        color=TEXT_PRIMARY,
        label_style=ft.TextStyle(color=TEXT_MUTED),
        bgcolor=BG_CARD2,
        border_radius=10,
    )
    erro = ft.Text("", color=ACCENT_RED, size=12, visible=False)
    spinner = ft.ProgressRing(color=ACCENT_GREEN, width=24, height=24, visible=False)

    def do_login(e):
        erro.visible = False
        spinner.visible = True
        page.update()
        if email.value and senha.value:
            state["user"] = MOCK_USER
            spinner.visible = False
            navigate("/dashboard")
        else:
            erro.value = "Preencha e-mail e senha."
            erro.visible = True
            spinner.visible = False
            page.update()

    senha.on_submit = do_login

    return ft.View(
        route="/login",
        bgcolor=BG_DARK,
        scroll=ft.ScrollMode.AUTO,
        controls=[
            ft.Container(
                ft.Column(
                    [
                        ft.Container(height=60),
                        ft.Column(
                            [
                                ft.Container(
                                    ft.Icon(ft.icons.GRAIN, color=ACCENT_GREEN, size=48),
                                    bgcolor=f"{ACCENT_GREEN}18",
                                    border_radius=20,
                                    padding=16,
                                    width=80,
                                    height=80,
                                    alignment=ft.Alignment(0, 0),
                                ),
                                ft.Container(height=12),
                                ft.Text("EstufaMonitor", size=28, color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD),
                                ft.Text("Monitoramento LoRaWAN de Estufas", size=12, color=TEXT_MUTED),
                            ],
                            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                            spacing=4,
                        ),
                        ft.Container(height=36),
                        ft.Container(
                            ft.Column(
                                [
                                    ft.Text("Acesse sua conta", size=15, color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD),
                                    ft.Container(height=20),
                                    email,
                                    ft.Container(height=12),
                                    senha,
                                    ft.Container(height=6),
                                    erro,
                                    ft.Container(height=16),
                                    ft.ElevatedButton(
                                        "Entrar",
                                        on_click=do_login,
                                        bgcolor=ACCENT_GREEN,
                                        color=BG_DARK,
                                        width=float("inf"),
                                        height=46,
                                        style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=10)),
                                    ),
                                    ft.Container(height=10),
                                    ft.Row([spinner], alignment=ft.MainAxisAlignment.CENTER),
                                    ft.Container(height=12),
                                    ft.Row(
                                        [
                                            ft.TextButton(
                                                "Criar nova conta",
                                                style=ft.ButtonStyle(color=TEXT_MUTED),
                                            ),
                                        ],
                                        alignment=ft.MainAxisAlignment.CENTER,
                                    ),
                                ],
                                spacing=0,
                            ),
                            bgcolor=BG_CARD,
                            border_radius=16,
                            padding=28,
                            border=ft.border.all(1, BORDER_COLOR),
                            width=380,
                        ),
                        ft.Container(height=36),
                        ft.Text("v1.0.0 - IFSC / Sistema Embarcado", color=TEXT_MUTED, size=10),
                    ],
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                    spacing=0,
                ),
                expand=True,
                alignment=ft.Alignment(0, -1),
            )
        ],
    )

