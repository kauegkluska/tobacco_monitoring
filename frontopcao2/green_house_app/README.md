# GreenMonitor Frontend (Flet)

Este é o frontend completo para o sistema de monitoramento de estufas, desenvolvido em **Flet (Python)**.

## Estrutura do Projeto
- `main.py`: Ponto de entrada e gerenciamento de rotas.
- `views/`: Contém as telas do aplicativo (Login, Registro, Home, Monitoramento, Dispositivos).
- `utils/`: Contém o tema visual e o cliente de simulação da API.
- `components/`: Espaço para componentes reutilizáveis.

## Funcionalidades Implementadas
1. **Autenticação**: Telas de Login e Registro com validação visual.
2. **Gestão de Estufas**: Listagem, adição e remoção manual de estufas.
3. **Monitoramento**: Visualização de temperatura, umidade e tempo estimado de secagem.
4. **Gráficos**: Histórico de leituras usando Matplotlib integrado ao Flet.
5. **Dispositivos**: Tela para vinculação de novos dispositivos via "simulação de QR Code".
6. **Alertas**: Visualização de notificações de temperatura/umidade fora do padrão.

## Como Executar
1. Certifique-se de ter o Python instalado.
2. Instale as dependências:
   ```bash
   pip install flet matplotlib pandas requests
   ```
3. Execute o aplicativo:
   ```bash
   python main.py
   ```

## Integração com o Backend
O arquivo `utils/api_client.py` contém uma classe `APIClient` que simula as respostas da sua API FastAPI. Para conectar ao seu backend real:
1. Altere a `BASE_URL` no `api_client.py`.
2. Substitua os métodos de simulação por chamadas reais usando a biblioteca `requests`.
