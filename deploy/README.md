# Implantação no servidor (Oracle Cloud)

Comandos para a máquina virtual onde a API roda (`/opt/estufa/tobacco_monitoring`, usuário `opc`). O código chega
sozinho pelo `estufa-update.timer` (`git pull` a cada 2 min); o que está aqui é a configuração que fica fora do git.

## 1. Chave do gateway e modo de produção

Fora de `ENVIRONMENT=development` a API só aceita leituras com o header `X-API-Key` igual a `GATEWAY_API_KEY`; sem a
chave configurada, recusa todas (503). Em `development` ela também devolve o código de redefinição de senha na resposta,
então o servidor exposto à internet deve ficar em `production`.

Conferir sem mostrar a chave:

```bash
cd /opt/estufa/tobacco_monitoring/backend
grep '^ENVIRONMENT=' .env
grep -c '^GATEWAY_API_KEY=..' .env   # 1: tem chave; 0: não tem
```

Sem chave, gerar uma e acrescentar:

```bash
echo "GATEWAY_API_KEY=$(venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(24))')" >> .env
grep '^GATEWAY_API_KEY=' .env   # copie o valor para GATEWAY_API_KEY no gateway/receiver/segredos.h
```

Depois, `ENVIRONMENT=production` no `.env` e `sudo systemctl restart estufa`. Só ligue o modo de produção quando o
gateway já estiver gravado com a mesma chave, senão as leituras param (o log avisa: `journalctl -u estufa -n 20`).

## 2. Backup automático do banco

Cópia a cada 6 h em `~/backup-estufa/auto/`, compactada, guardando 14 dias. A cópia usa a API de backup do SQLite, então
não precisa parar a API.

```bash
cd /opt/estufa/tobacco_monitoring
sudo cp deploy/backup/estufa-backup.service deploy/backup/estufa-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now estufa-backup.timer
sudo systemctl start estufa-backup.service   # primeira cópia agora
journalctl -u estufa-backup -n 5 --no-pager
ls -lh ~/backup-estufa/auto/
```

A cópia fica na mesma máquina: protege contra erro no banco, não contra perder a máquina. Durante uma secagem, traga
uma cópia para o computador de vez em quando (no PowerShell):

```powershell
scp -i $chave "opc@137.131.176.80:backup-estufa/auto/*.gz" .
```

Restaurar: `sudo systemctl stop estufa`, `gunzip -c ARQUIVO.db.gz > backend/data/monitor.db`, `sudo systemctl start estufa`.

## 3. HTTPS

O app e o painel mandam login e token; em HTTP eles passam abertos pela internet. O Caddy fica na frente da API, obtém
o certificado da Let's Encrypt e o renova sozinho. O nome `137-131-176-80.sslip.io` aponta para o IP do servidor sem
precisar comprar domínio.

1. Na Oracle Cloud: **Networking > Virtual Cloud Networks > (rede da VM) > Security Lists > Default** e acrescente
   regras de entrada TCP para as portas **80** e **443** (origem `0.0.0.0/0`).
2. Na VM:

```bash
sudo dnf install -y 'dnf-command(copr)'
sudo dnf copr enable -y @caddy/caddy
sudo dnf install -y caddy
sudo cp /opt/estufa/tobacco_monitoring/deploy/https/Caddyfile /etc/caddy/Caddyfile
sudo firewall-cmd --permanent --add-service=http --add-service=https
sudo firewall-cmd --reload
sudo systemctl enable --now caddy
sleep 20
curl -s https://137-131-176-80.sslip.io/health; echo
```

O resultado esperado é `{"status":"ok"}`. Se falhar, `journalctl -u caddy -n 30 --no-pager` mostra o motivo (o mais
comum é a porta 80 ainda fechada na Security List: a Let's Encrypt precisa dela para emitir o certificado).

Com o HTTPS funcionando:

- Painel web: `https://137-131-176-80.sslip.io/app/`.
- App: o endereço padrão passa a ser o HTTPS (`frontend_mobile/lib/core/api.dart`); em versões antigas, troque em
  **Ajustes > Servidor**.
- O gateway continua na porta 8000, em HTTP: o ESP32 não valida certificados sem configuração extra. A chave dele passa
  aberta na internet; fechar a porta 8000 para tudo que não seja `/readings` fica como melhoria futura.
