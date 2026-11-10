"""Textos do controle do flap e do soprador e dos alertas que dependem deles.

Sem números nem unidades: os valores vão em campos à parte (°C) e o app formata. "Umidade", nunca "bulbo úmido".
{flap} e {fan} são os nomes que o produtor deu às saídas; {phase} é o nome da fase.
"""

# Motivos exibidos no cartão de cada saída.
FLAP_OPEN = "{flap} aberto: umidade acima do limite da fase."  # M1
FLAP_CLOSED = "{flap} fechado: umidade dentro do alvo."  # M2
FLAP_YELLOWING = "{flap} fechado: na {phase} ele fica fechado no automático."
RAMP_FROZEN = (  # M3
    "A umidade não baixa com {flap} aberto. O sistema segurou o aumento de temperatura; não coloque mais lenha agora."
)
FLAP_DROP_CLOSED = "{flap} foi fechado porque a estufa estava esfriando."  # M4
TARGET_LIMITED = "O alvo de {fan} foi limitado ao máximo da fase."  # M5 e alerta A4
RAMP = "A temperatura vai subir aos poucos até o alvo."  # M6
SENSOR_FALLBACK = (  # M7
    "O sensor está com leitura suspeita: o sistema desligou {fan}. Cuide do fogo à mão até a leitura voltar."
)
FAN_CEILING = "{fan} desligado: a temperatura chegou ao máximo da fase."
FAN_RATE = "{fan} desligado: a temperatura está subindo rápido demais."

# "Umidade alta", pelo estado do flap.
WET_HIGH_OPEN = "Umidade alta com {flap} aberto: não aumente o fogo."
WET_HIGH_LOCKED = "Umidade alta: {flap} foi fechado porque a estufa esfriou. Ele reabre quando a temperatura se recuperar."
WET_HIGH_SOON = "Umidade alta: {flap} reabre em instantes."
WET_HIGH_CLOSED = "Umidade alta: abra {flap}."

# "Ar seco na Amarelação", pelo estado do flap.
DRY_CLOSED = "Ar seco: confira portas e frestas; não aumente o fogo."
DRY_OPEN = "Ar seco: feche {flap}."

# "Umidade baixa" no Murchamento.
LOW_WILTING = "Ar seco: se os estaleiros de cima ainda não amarelaram, segure a temperatura."

# "Aquecimento rápido", pelo estado do soprador.
HEATING_FAN_OFF = (
    "A temperatura está subindo mais rápido que o recomendado para a fase, com {fan} desligado: coloque menos lenha."
)
HEATING_CUT = "A temperatura está subindo rápido demais: o sistema desligou {fan}. Coloque menos lenha."
HEATING_MANUAL = "A temperatura está subindo rápido demais com {fan} ligado à mão: desligue-o ou coloque menos lenha."

# "Temperatura em queda", pela causa.
DROP_FLAP_OPEN = "A estufa está esfriando com {flap} aberto para tirar umidade: mantenha o fogo."
DROP_AFTER_FLAP = "A estufa continua esfriando depois que {flap} fechou: confira o fogo."
DROP = "A temperatura caiu. Veja a fornalha, a lenha e o ventilador. Ao retomar, suba a temperatura aos poucos, em degraus."

# Alertas novos (informativos).
VERY_WET = "Estufa muito úmida: se o fumo estiver suando, abra {flap} por poucos minutos."  # A1
WET_LOAD = "Se o fumo entrou molhado, deixe {flap} em Ligada até as folhas enxugarem; depois volte para o Automático."  # A2
MANUAL_FLAP = (  # A3
    "{flap} continua aberto à mão. Se as folhas já enxugaram, volte para o Automático: "
    "ar demais na amarelação pode deixar o fumo verde."
)
WEAK_FIRE = "O fogo não está acompanhando a ventilação."  # A5

ALL = tuple(value for name, value in dict(globals()).items() if name.isupper() and isinstance(value, str))


def text(template: str, flap: str = "", fan: str = "", phase: str = "") -> str:
    return template.format(flap=flap, fan=fan, phase=phase)
