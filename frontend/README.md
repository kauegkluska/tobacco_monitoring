# Painel web

Painel responsivo (computador, tablet e celular) para acompanhar as estufas. Não precisa de instalação nem de build: o backend serve estes arquivos.

## Abrir

Com o backend rodando (veja `backend/README.md`), acesse:

- No próprio computador: <http://127.0.0.1:8000/>
- Em outro aparelho da mesma rede: `http://<ip-do-computador>:8000/`

Para servir a pasta separadamente (por exemplo, durante o desenvolvimento), use `python -m http.server 5500 --directory frontend`. Nesse caso, informe o endereço da API em **Alterar servidor**, na tela de login.

## Simulador LoRa (testes)

`http://127.0.0.1:8000/app/simulador.html` faz o papel do sender e do gateway sem hardware: você edita temperatura, umidade, ID, RSSI/SNR e relés, e a página faz o mesmo `POST /readings/readings/` que o `receiver.ino` (mesmo JSON, header `X-API-Key` e timeout de 3 s). Ela também mostra o pacote LoRa e o downlink `RELAY;...`, e pode enviar sozinha a cada 2 s.

## Telas

| Tela | O que mostra |
|---|---|
| **Estufas** (`#/estufas`) | Um cartão por estufa: situação (Normal, Fora da faixa, Atenção, Crítico, Sem sinal, Parada), fase, temperatura e umidade com a faixa esperada, alertas ativos. |
| **Estufa** (`#/estufa/<id>`) | Tudo da estufa: leituras, alertas ativos, cura (fases, condições para avançar, iniciar/parar), histórico (período, temperatura/umidade, mín/méd/máx, CSV), saídas e sensor (vincular, verificar, desvincular). Em **Opções**: renomear, duração prevista, corrigir fase e excluir. |
| **Alertas** (`#/alertas`) | Ativos, resolvidos e todos, com filtro por estufa e gravidade. Permite reconhecer e resolver. |
| **Ajustes** (`#/ajustes`) | Unidade (°F/°C), tema, aviso sonoro, conta, senha, servidor e legenda das situações. |

## Estrutura

```
index.html
css/styles.css      tokens do design (claro e escuro) e componentes
js/main.js          sessão, menu e navegação (#/estufas, #/estufa/3...)
js/api.js           cliente da API: token, renovação, mensagens de erro
js/chart.js         gráfico em SVG com faixa esperada e tooltip
js/dom.js           ícones, diálogos, avisos e utilitários de interface
js/format.js        números, datas e conversão °C/°F em português
js/store.js         preferências deste navegador
js/data.js          dados compartilhados e regras de apresentação
js/widgets.js       situação da estufa, leituras e alertas (usados em várias telas)
js/pages/*.js       uma tela por arquivo
```

Sem dependências externas além da fonte Roboto Flex (Google Fonts). Sem internet, o painel usa a fonte do sistema.
