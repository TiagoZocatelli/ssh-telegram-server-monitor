# 🛡️ ZK Monitors (SSH Security + Server/Process Monitor)

Este repositório reúne **dois scripts independentes** (2 projetos) voltados para monitoramento de servidor e envio de alertas via **Telegram** (e, no monitor de processos, também por **E-mail via API**).

- **Projeto 1 — `zksecmon`**: monitoramento de **ataques SSH** (com janela de tempo) + **summary** periódico + status de serviços ZKBI + integração opcional com Fail2ban.
- **Projeto 2 — `zkmonitor`**: monitoramento de **disco / CPU / load / processos .l** (configurável via `.ini` com assistente em `dialog`) + alertas Telegram para **múltiplos chats** + limpeza automática de mensagens + “ping ativo” periódico + alerta por e-mail quando processos estiverem fechados.

---

## 📦 Sugestão de nome do repositório (se quiser renomear)
- `zk-monitor-suite`
- `zk-telegram-monitors`
- `zksecmon-zkmonitor`
- `zk-server-monitoring-suite`

Se você mantiver o nome atual `ssh-telegram-server-monitor`, este README já funciona também.

---

# ✅ Requisitos

## Comuns
- Linux com `bash`
- `curl`
- `systemd` (para service/timer)
- Telegram Bot Token + Chat ID(s)
- Permissão para ler logs/arquivos usados (ex.: `/var/log/auth.log`)

## Projeto 1 (SSH)
- Opcional: `fail2ban-client` (para listar IPs banidos do jail)
- Log padrão: `/var/log/auth.log` (Debian/Ubuntu). Em outras distros pode variar.

## Projeto 2 (Server/Process)
- Opcional: `dialog` (assistente de configuração)
- Opcional: `jq` (para envio de e-mail via API com payload JSON)
- Arquivo INI: padrão `/etc/zk_cliente.ini`
- Arquivo ENV: `/etc/environment`

---

# 🔐 Variáveis de ambiente (Telegram)

Ambos os projetos leem do `ENV_FILE=/etc/environment`.

Defina:

```bash
TG_TOKEN="SEU_TOKEN_DO_BOT"
TG_CHAT_ID="-100XXXXXXXXXX"
```

No **Projeto 2**, `TG_CHAT_ID` pode conter **vários chats** separados por vírgula:
```bash
TG_CHAT_ID="-1001111111111,-1002222222222,123456789"
```

Recarregar (quando necessário):
```bash
source /etc/environment
```

---

# 🧩 Projeto 1 — ZK Security Monitor (SSH) — `zksecmon`

## O que ele faz
- Procura sinais de ataque no `AUTH_LOG` (por padrão `/var/log/auth.log`):
  - `Failed password`
  - `Invalid user`
  - `authentication failure`
  - `Did not receive identification`
  - `Connection closed by authenticating user`
- **RUN**: envia alerta **somente se houver ataques nos últimos X segundos**
- **SUMMARY**: envia um resumo completo com histórico (Top IPs), última tentativa, fail2ban banidos, usuários conectados (`who`), e status de serviços ZKBI.
- Cria **2 timers**:
  - `zksecmon-run.timer` (a cada 60s)
  - `zksecmon-summary.timer` (a cada 1h)

## Configurações (por variáveis)
- `AUTH_LOG` (padrão `/var/log/auth.log`)
- `JAIL` (padrão `sshd` — usado no `fail2ban-client status`)
- `WINDOW_SECS` (padrão `300` = 5 minutos)
- `TOP_N` (padrão `15`)

Exemplo:
```bash
export WINDOW_SECS=600
export TOP_N=20
```

## Serviços verificados (ZKBI)
O script inclui:
- `zkbi-api.service`
- `zkbi-server.service`

Ele envia o status `active/inactive/failed/unknown` no alerta.

## Uso
```bash
./zksecmon.sh run
./zksecmon.sh summary
./zksecmon.sh install
./zksecmon.sh uninstall
./zksecmon.sh status
```

## Instalação via systemd (recomendado)
```bash
sudo ./zksecmon.sh install
```

Timers criados:
- `/etc/systemd/system/zksecmon-run.service`
- `/etc/systemd/system/zksecmon-run.timer`
- `/etc/systemd/system/zksecmon-summary.service`
- `/etc/systemd/system/zksecmon-summary.timer`

Ver status:
```bash
systemctl status zksecmon-run.timer --no-pager
systemctl status zksecmon-summary.timer --no-pager
```

## Exemplo de alerta (RUN)
- Só dispara se encontrou ataques na janela (`WINDOW_SECS`)
- Exibe IPs recentes (contagem por IP)

## Exemplo de alerta (SUMMARY)
- Top IPs (histórico)
- Última linha de tentativa
- Fail2ban banidos
- `who`
- Serviços ZKBI

---

# 🖥️ Projeto 2 — ZK Monitor (Server/Process/Disk/CPU) — `zkmonitor`

## O que ele faz
- **Assistente de configuração** (dialog) para:
  - TG_TOKEN
  - TG_CHAT_ID (1 ou mais chats)
  - caminho base (ex.: `/mnt/basesg`)
  - lista de executáveis `.l` para monitorar
- Cria/atualiza um INI padrão `/etc/zk_cliente.ini` com:
  - `[parame]` caminho do `parame.ini`
  - `[disk]` mount e thresholds
  - `[cpu]` thresholds
  - `[process_1]`, `[process_2]`... (monitor de processos)
- Executa monitoramento periódico:
  - Disco: total/usado/livre/% e nível (OK/ATENCAO/CRITICO)
  - CPU% e Load 1/5/15
  - Processos: identifica se `.l` está rodando via `pgrep -af`
- Envia alertas para **múltiplos chats** via Telegram
- Faz **limpeza automática** das mensagens enviadas (deleteMessage) a cada X horas
- Envia “✅ Monitor ATIVO” (ping) a cada X horas com dados do cliente/host/ip
- Quando detecta processos fechados, pode enviar e-mail via API (se configurado no INI)

## Principais arquivos e diretórios
- INI: `/etc/zk_cliente.ini`
- ENV: `/etc/environment`
- State: `/var/lib/zkmonitor_alerta_final`
  - `messages.log` (mensagens para limpeza)
  - `telegram_errors.log` (falhas de envio)
  - `last_clean.ts` (controle de limpeza)
  - `active_ping.ts` (controle de ping ativo)

## Configurações (variáveis úteis)
- `ACTIVE_PING_HOURS` (padrão 24)
- `CLEAN_HOURS` (padrão 24)

## Configuração do INI (exemplo)
```ini
[parame]
path=/mnt/basesg/parame.ini

[disk]
mount=/mnt/basesg
warn_used_pct=90
crit_used_pct=95
warn_free_gb=20
crit_free_gb=10

[cpu]
cpu_pct_max=90
load1_max=6.0
load5_max=4.0

[process_1]
name=hmenu
exec=/mnt/basesg/hmenu.l
```

## Seção de e-mail (opcional)
O script lê:
- `api_url`
- `responsaveis` (lista)
- `token`

Exemplo:
```ini
[email]
api_url=https://seu-endpoint/send-email
responsaveis=tiago@empresa.com.br,ops@empresa.com.br
token=SEU_TOKEN_DA_API
```

Observações:
- Para essa parte funcionar bem, é recomendado ter `jq` instalado.
- Se não houver `email` configurado, o script só segue com Telegram.

## Uso
```bash
./zkmonitor.sh config
./zkmonitor.sh run
./zkmonitor.sh install 60
./zkmonitor.sh status
./zkmonitor.sh uninstall
```

Compatível também com INI explícito:
```bash
./zkmonitor.sh /etc/zk_cliente.ini config
./zkmonitor.sh /etc/zk_cliente.ini install 60
```

## Instalação via systemd
```bash
sudo ./zkmonitor.sh install 60
```

Cria:
- `/etc/systemd/system/zkmonitor.service`
- `/etc/systemd/system/zkmonitor.timer`

Ver status:
```bash
systemctl status zkmonitor.timer --no-pager
```

---

# 📁 Organização recomendada do repositório

Sugestão para deixar profissional e fácil de manter:

```text
.
├── zksecmon/
│   └── zksecmon.sh
├── zkmonitor/
│   └── zkmonitor.sh
├── LICENSE
└── README.md
```

Se você preferir, dá para manter os scripts na raiz, mas separar por pasta ajuda bastante.

---

# 🧪 Testes rápidos

## Telegram funcionando
No servidor:
```bash
source /etc/environment
curl -sS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"   -d "chat_id=${TG_CHAT_ID}"   --data-urlencode "text=Teste Telegram OK"
```

## Verificar jail do fail2ban (Projeto 1)
```bash
fail2ban-client status sshd
```

## Verificar log SSH
```bash
tail -n 50 /var/log/auth.log
```

---

# 🧯 Troubleshooting

## GitHub pedindo usuário/senha no push
Troque o remote para SSH:
```bash
git remote set-url origin git@github.com:TiagoZocatelli/ssh-telegram-server-monitor.git
```

## `chat not found` no Telegram
- O bot precisa estar no grupo/canal
- Em grupos, desative privacidade se necessário (`/setprivacy` no BotFather)
- Confirme o Chat ID correto (muitos grupos começam com `-100`)

## systemd não executa o script
- Garanta permissão:
```bash
chmod +x zksecmon.sh zkmonitor.sh
```
- Veja logs:
```bash
journalctl -u zksecmon-run.service -n 100 --no-pager
journalctl -u zkmonitor.service -n 100 --no-pager
```

---

# 📄 Licença
MIT (se você quiser, posso gerar um `LICENSE` completo).

---

# ✨ Autor
Tiago Zocatelli
