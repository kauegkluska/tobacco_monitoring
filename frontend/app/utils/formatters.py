from app.theme import ACCENT_GREEN, ACCENT_ORANGE, ACCENT_RED, TEXT_MUTED


def status_color(status):
    return {
        "normal": ACCENT_GREEN,
        "alerta": ACCENT_ORANGE,
        "critico": ACCENT_RED,
    }.get(status, TEXT_MUTED)


def gravidade_color(gravidade):
    return {
        "ALTA": ACCENT_RED,
        "MEDIA": ACCENT_ORANGE,
        "BAIXA": ACCENT_GREEN,
    }.get(gravidade, TEXT_MUTED)


def pct(estufa):
    return min(1.0, estufa["horas_decorridas"] / estufa["duracao_total_h"])


def restantes_fmt(estufa):
    horas = max(0.0, estufa["duracao_total_h"] - estufa["horas_decorridas"])
    hh, mm = int(horas), int((horas % 1) * 60)
    return f"{hh}h {mm:02d}m"

