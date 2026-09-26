# App Monitor de Estufa (Flutter)

App para celular e tablet com as mesmas telas do painel web:

| Tela | O que mostra |
|---|---|
| **Início** | Situação da estufa em linguagem simples, temperatura e umidade com a faixa segura, **saídas e aviso sonoro** (relés do sender com nome editável, como "Ventoinhas"; modo automático/ligada/desligada; regra do automático; confirmação do sender; último aviso e últimas mudanças), controle da secagem, gráfico das últimas 6 h e alertas ativos. Mostra os primeiros passos enquanto a configuração não está completa. |
| **Histórico** | Períodos de 1 h a 30 dias, temperatura ou umidade, mínima/média/máxima, gráfico (toque ou arraste para ver os valores) e registros. |
| **Alertas** | Ativos, resolvidos e todos, com valor esperado e encontrado. Permite reconhecer e resolver. |
| **Estufas** | Cadastro de estufas e vínculo do sensor ESP32 lendo o QR code com a câmera ou digitando o ID do controlador. Também edita limites e desvincula. |
| **Perfil** | Nome, senha, unidade (°F/°C), tema (claro/escuro/automático), aviso sonoro no celular (liga/desliga e teste), notificações com o app fechado, endereço do servidor e uma explicação de como o sistema funciona. |

Quando o gateway toca o aviso sonoro (uma saída ligou), o app mostra um aviso na tela e, se ativado no Perfil, bipa e vibra o celular.

## Notificações com o app fechado (Android)

Em **Perfil > Notificações com o app fechado**, o app liga um serviço em primeiro plano que consulta o servidor a cada 15 s e notifica quando o gateway toca o aviso sonoro ou um alerta abre. Não usa Firebase: o celular só precisa alcançar o servidor. Enquanto ativo, o Android mostra o aviso fixo "Estufa monitorada". O serviço volta sozinho depois de reiniciar o celular.

Permissões pedidas e por quê:

| Permissão | Quando | Para quê |
|---|---|---|
| Internet, tráfego `http` | Sempre | Falar com a API na rede local |
| Multicast do Wi-Fi | Automática | Procurar o servidor na rede (mDNS) |
| Câmera | Ao abrir o leitor de QR code | Ler o QR code do sensor |
| Notificações (Android 13+) | Ao ativar as notificações | Mostrar os avisos |
| Ignorar otimização de bateria | Ao ativar as notificações | Evitar que o Android pause o monitoramento |
| Serviço em primeiro plano (`specialUse`), inicialização, vibração | Automáticas | Manter o monitoramento ativo e vibrar |

Se o usuário negar uma permissão, o Perfil mostra o que falta e um botão para abrir as configurações do Android.

No celular a navegação fica na barra inferior; em telas largas (tablet), num menu lateral. Todas as listas atualizam ao puxar para baixo.

## Servidor

Não é preciso digitar o IP: com o celular no mesmo Wi-Fi do computador, o app procura o servidor sozinho na primeira abertura, como o gateway faz.

1. **mDNS:** o backend se anuncia como `_estufa._tcp` com os IPs do computador. O app escolhe o IP da rede Wi-Fi do celular.
2. **Varredura da rede:** se a rede bloquear mDNS, o app procura a porta `8000` nos endereços da rede do celular (leva alguns segundos).

Todo servidor encontrado é confirmado com `GET /health`. Se houver mais de um, o app mostra a lista para escolher.

- **Login > Alterar** e **Perfil > Servidor > Procurar na rede** abrem a busca e também aceitam o endereço digitado, por exemplo `http://192.168.0.14:8000`.
- Se o computador ganhar outro IP, a tela "Servidor indisponível" tem **Procurar servidor na rede**, que acha o novo endereço e reconecta.
- No emulador Android, o computador é `http://10.0.2.2:8000`.
- Na versão aberta pelo navegador (`/mobile/`), o endereço já é o da própria página e a busca não aparece.

A API deve estar rodando com:

```powershell
cd backend/app
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

## Instalar no celular

**Pelo navegador (sem instalar nada no computador):** gere a versão web e abra pelo celular, na mesma rede Wi-Fi do computador.

```powershell
flutter build web --release --base-href /mobile/
```

Com a API rodando, abra `http://<ip-do-computador>:8000/mobile/` no Chrome do Android e escolha **Adicionar à tela inicial**. Nessa versão o leitor de QR code não funciona (a câmera exige HTTPS); digite o ID do controlador.

**APK Android:** requer o Android SDK (Android Studio). Depois de instalado:

```powershell
flutter build apk --release
```

Copie `build/app/outputs/flutter-apk/app-release.apk` para o celular e abra o arquivo, permitindo a instalação de fontes desconhecidas. Com o celular em modo de depuração USB, `flutter install` instala direto.

## Desenvolvimento

Requer Flutter 3.35 ou mais novo (Dart 3.9).

```powershell
cd frontend_mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

No Windows, o build de desktop com plugins pede o **Modo de desenvolvedor** ativado (Configurações > Privacidade e segurança > Para desenvolvedores). Não é necessário para Android nem para os testes.

## Estrutura

```
lib/
  main.dart, app.dart     inicialização, tema, sessão e português do Brasil
  core/api.dart           cliente da API: token, renovação e mensagens de erro
  core/models.dart        modelos tipados (estufa, dispositivo, leitura, alerta, série)
  core/format.dart        números, datas e conversão °C/°F
  core/prefs.dart         preferências do aparelho (unidade, tema, estufa)
  core/theme.dart         cores do DESIGN.md para tema claro e escuro
  core/app_scope.dart     acesso à API e às preferências em qualquer tela
  core/buzzer.dart        aviso sonoro no celular (assets/sounds/buzzer.wav) e textos das saídas
  core/background.dart    notificações com o app fechado (serviço em primeiro plano no Android)
  core/discovery.dart     busca do servidor na rede (mDNS e varredura)
  widgets/server_dialog.dart  escolha do servidor: busca na rede ou endereço manual
  widgets/common.dart     selos, avisos, cartões, estados vazios e formulários
  widgets/line_chart.dart gráfico com faixa segura e seleção por toque
  pages/                  uma tela por arquivo
test/widget_test.dart
```
