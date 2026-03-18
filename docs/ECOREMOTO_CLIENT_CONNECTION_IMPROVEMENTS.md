# Análise de melhorias no processo de conexão do cliente EcoRemoto

Este documento resume melhorias práticas para aumentar a taxa de conexão bem-sucedida, reduzir tempo de suporte e melhorar visibilidade operacional do EcoRemoto.

## 1) Fluxo atual (visão resumida)

1. Cliente inicia e valida serviço local (Windows instalado + serviço EcoRemoto).
2. Cliente mantém sinalização de vida (heartbeat) para o painel.
3. Operador identifica cliente no painel e inicia sessão remota.
4. Conexão RustDesk depende de disponibilidade do cliente + infraestrutura de rendezvous/relay.

## 2) Gargalos típicos observados

- Picos sincronizados de heartbeat em viradas de minuto (muitos clientes enviando ao mesmo tempo).
- Falta de correlação entre incidente de conexão e causa raiz (rede local, API key, DNS, relay, serviço parado).
- Ausência de SLOs explícitos para tempo de conexão e disponibilidade percebida no painel.
- Falhas intermitentes sem trilha única de diagnóstico (cliente, painel e backend sem correlação por `client_id`).

## 3) Melhorias recomendadas (priorizadas)

### P0 — confiabilidade imediata

- **Jitter estável no heartbeat** para distribuir carga entre clientes e evitar bursts concentrados.
- **Padronização de código de erro operacional** no cliente (ex.: `ECO_CONN_TIMEOUT`, `ECO_APIKEY_INVALID`, `ECO_SERVICE_INACTIVE`).
- **Health checks sintéticos** a cada 1-5 min para endpoints críticos (painel API, hbbs, relay).

### P1 — redução de MTTR

- **Correlation ID por sessão**: gerar ID no início da tentativa de conexão e propagar em logs cliente/painel.
- **Dashboard de conexão** com funil: tentativa → autenticação → handshake → sessão ativa.
- **Runbook objetivo para suporte** com árvore de decisão de 5 passos (serviço, rede, DNS, API, relay).

### P2 — escala e previsibilidade

- **SLOs formais**:
  - Conexão estabelecida em até 10s (p95).
  - Heartbeat aceito em até 2s (p95).
  - Disponibilidade do fluxo de conexão >= 99.5%.
- **Alertas por tendência**, não só por queda total (ex.: aumento de timeout > 3x baseline).
- **Canary rollout** para atualizações de cliente (5% → 20% → 100%).

## 4) Instrumentação mínima sugerida

### Cliente

- Métricas:
  - `eco_connection_attempt_total`
  - `eco_connection_success_total`
  - `eco_connection_fail_total{reason=...}`
  - `eco_heartbeat_latency_ms`
- Logs com campos fixos:
  - `client_id`, `hostname`, `attempt`, `endpoint`, `result`, `error_code`, `latency_ms`

### Painel/API

- Métricas:
  - `api_heartbeat_requests_total{status=...}`
  - `api_heartbeat_rejected_total{reason=...}`
  - `kanban_online_clients`
- Auditoria:
  - timestamp de última conexão válida por cliente
  - origem do erro consolidada por categoria

## 5) Plano de execução (2 semanas)

### Semana 1

- Ativar jitter no heartbeat (cliente).
- Publicar dicionário de erros operacionais.
- Criar dashboard inicial de funil de conexão.

### Semana 2

- Implementar correlation ID ponta a ponta.
- Configurar alertas de tendência e SLOs iniciais.
- Rodar canary de versão com monitoramento comparativo.

## 6) Critérios de sucesso

- Queda de chamados de “cliente offline intermitente”.
- Redução de p95 de tempo de conexão.
- Redução de bursts de heartbeat no backend.
- Diagnóstico de incidente em < 15 min com causa classificada.
