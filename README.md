# 🔐 SSH Telegram Server Monitor

Monitoramento de segurança para servidores Linux com foco em **acessos SSH**, envio de **alertas em tempo real via Telegram** e geração de **relatórios resumidos**.

Ideal para ambientes de produção, VPS e servidores críticos que precisam de visibilidade rápida sobre tentativas de acesso suspeitas.

---

## 🚀 Funcionalidades

- 🔍 Monitoramento contínuo de logs SSH (`auth.log`)
- 🚨 Alertas automáticos no Telegram para:
  - Tentativas de login inválidas
  - Ataques de força bruta
  - IPs suspeitos
- 📊 Relatório **summary** com:
  - Top IPs atacantes
  - Usuários mais visados
  - Quantidade de tentativas
- ⏱️ Detecção inteligente (envia alerta apenas se houver ataques recentes)
- ⚙️ Integração nativa com **systemd (service + timer)**
- 🧠 Script em **Shell Script puro** (sem Python ou dependências pesadas)

---

## 🧰 Tecnologias Utilizadas

- Bash (Shell Script)
- systemd
- Telegram Bot API
- Linux Auth Logs (`/var/log/auth.log`)

---

## 📁 Estrutura do Projeto

```text
ssh-telegram-server-monitor/
├── monitor.sh
├── install.sh
├── compilador.sh
├── ssh-monitor.service
├── ssh-monitor.timer
├── README.md
```

---

## ⚙️ Configuração

### 1️⃣ Criar um bot no Telegram
- Fale com **@BotFather**
- Gere o **TOKEN**

### 2️⃣ Obter o Chat ID
- Pode ser chat privado ou grupo
- Para grupos, o ID geralmente começa com `-100`

### 3️⃣ Variáveis de ambiente

Edite `/etc/environment`:

```bash
TG_TOKEN="SEU_TOKEN_DO_BOT"
TG_CHAT_ID="-100XXXXXXXXXX"
```

Depois recarregue:
```bash
source /etc/environment
```

---

## 🛠️ Instalação

```bash
git clone git@github.com:TiagoZocatelli/ssh-telegram-server-monitor.git
cd ssh-telegram-server-monitor
chmod +x *.sh
sudo ./install.sh
```

---

## ⏱️ Funcionamento

- O timer do systemd executa o monitor em intervalos definidos
- O script analisa os últimos minutos do log SSH
- Alertas são enviados apenas quando há atividade suspeita
- O modo summary gera um relatório consolidado

---

## 📬 Exemplo de Alerta

```
🚨 SSH ALERTA DETECTADO

Servidor: prod-server-01
Tentativas recentes: 12
Top IP atacante: 45.138.xxx.xxx
Usuário mais atacado: root
Horário: 2026-01-29 15:04
```

---

## 🔒 Segurança

- Nenhuma senha é armazenada
- Apenas leitura de logs
- Comunicação via HTTPS com Telegram

---

## 📄 Licença

MIT License

---

## ✨ Autor

Tiago Zocatelli
