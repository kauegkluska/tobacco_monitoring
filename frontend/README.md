# Painel web

Painel responsivo (computador, tablet e celular) para acompanhar as estufas. Não precisa de instalação nem de build: o backend serve estes arquivos.

## Abrir

Com o backend rodando (veja `backend/README.md`), acesse:

- No próprio computador: <http://127.0.0.1:8000/>
- Em outro aparelho da mesma rede: `http://<ip-do-computador>:8000/`

Para servir a pasta separadamente (por exemplo, durante o desenvolvimento), use `python -m http.server 5500 --directory frontend`. Nesse caso, informe o endereço da API em **Alterar servidor**, na tela de login.

## Telas

| Tela | O que mostra |
|---|---|
| **Início** | Situação da estufa em linguagem simples, temperatura e umidade com a faixa segura, controle da secagem (fase, duração prevista, iniciar/parar), gráfico das últimas 6 h e alertas ativos. Mostra os primeiros passos enquanto a configuração não está completa. |
| **Histórico** | Períodos de 1 h a 30 dias, temperatura ou umidade, mínima/média/máxima, gráfico com tooltip, tabela e exportação CSV. |
| **Alertas** | Ativos, resolvidos e todos, com valor esperado e encontrado. Permite reconhecer e resolver. |
| **Estufas** | Cadastro de estufas, vínculo do sensor ESP32 pelo ID do controlador, limites de temperatura e umidade e desvínculo. |
| **Perfil** | Nome, senha, unidade (°F/°C), tema (claro/escuro/automático), endereço do servidor e uma explicação de como o sistema funciona. |

## Estrutura

```
index.html
css/styles.css      tokens do design (claro e escuro) e componentes
js/main.js          sessão, menu e navegação (#/inicio, #/historico...)
js/api.js           cliente da API: token, renovação, mensagens de erro
js/chart.js         gráfico em SVG com faixa segura e tooltip
js/dom.js           ícones, diálogos, avisos e utilitários de interface
js/format.js        números, datas e conversão °C/°F em português
js/store.js         preferências deste navegador
js/data.js          dados compartilhados e regras de apresentação
js/pages/*.js       uma tela por arquivo
```

Sem dependências externas além da fonte Roboto Flex (Google Fonts). Sem internet, o painel usa a fonte do sistema.
