import flet as ft


BG_DARK = "#0F1923"
BG_CARD = "#1A2535"
BG_CARD2 = "#1E2D3D"
ACCENT_GREEN = "#2ECC71"
ACCENT_BLUE = "#3498DB"
ACCENT_ORANGE = "#E67E22"
ACCENT_RED = "#E74C3C"
TEXT_PRIMARY = "#ECF0F1"
TEXT_MUTED = "#7F8C9A"
BORDER_COLOR = "#243447"


def pad(left=0, top=0, right=0, bottom=0):
    return ft.Padding(left=left, top=top, right=right, bottom=bottom)


def padxy(horizontal=0, vertical=0):
    return ft.Padding(left=horizontal, right=horizontal, top=vertical, bottom=vertical)


def mar(left=0, top=0, right=0, bottom=0):
    return ft.Margin(left=left, top=top, right=right, bottom=bottom)

