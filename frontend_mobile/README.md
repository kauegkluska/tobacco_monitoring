# Monitor de estufa de tabaco mobile

App Flutter inspirado no design Stitch. Inclui login, cadastro, painel da estufa, histórico de leituras, central de alertas e perfil. Mostra temperatura em Fahrenheit e umidade em português, atualizando a API periodicamente.

## Configuração

Edite `lib/main.dart` e confirme o IP do computador:

```dart
const apiUrl = 'http://192.168.1.2:8000/readings/readings/';
```

O celular/Android e o computador precisam estar na mesma rede Wi-Fi. A API deve estar iniciada com:

```powershell
cd backend/app
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

## Instalar Flutter e gerar APK

Depois de instalar o Flutter SDK e o Android SDK, abra um terminal nesta pasta:

```powershell
cd frontend_mobile
flutter pub get
flutter build apk --release
```

O APK será gerado em:

```text
build/app/outputs/flutter-apk/app-release.apk
```
