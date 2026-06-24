import flet as ft

class AppColors:
    PRIMARY = "#2E7D32"  # Green 800
    SECONDARY = "#81C784" # Green 300
    BACKGROUND = "#F5F5F5"
    TEXT = "#212121"
    WHITE = "#FFFFFF"
    ACCENT = "#FFA000" # Amber 700
    DANGER = "#D32F2F"

def get_theme():
    return ft.Theme(
        color_scheme=ft.ColorScheme(
            primary=AppColors.PRIMARY,
            secondary=AppColors.SECONDARY,
            surface=AppColors.WHITE,
            background=AppColors.BACKGROUND,
            on_primary=AppColors.WHITE,
            on_secondary=AppColors.TEXT,
        )
    )
