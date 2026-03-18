# EcoRemoto ↔ PainelAremoto heartbeat contract

Este documento define o contrato de heartbeat entre o cliente EcoRemoto e o endpoint atual do portal:

- Endpoint: `POST /api/heartbeat`
- Header obrigatório: `x-api-key`

Implementação de referência para o lado da API: `docs/PAINEL_HEARTBEAT_API_UPDATE.md`.

## Payload padrão (v2, compatível)

```json
{
  "client_id": "...",
  "hostname": "...",
  "username": "...",
  "alias": "...",
  "os": "...",
  "ip": "...",
  "version": "1.4.6",
  "timestamp": 1732666405,
  "client_version": "1.4.6"
}
```

### Regras de compatibilidade

- `client_version` é mantido para compatibilidade com versões legadas do painel.
- `version` passa a ser o campo padronizado preferencial.
- Campos ausentes devem usar fallback no painel (não quebrar clientes antigos).

## Regras de envio no cliente

Parâmetros do cliente EcoRemoto:

- `eco-panel-url` (default para produção)
- `eco-panel-api-key` (default para produção)

Confiabilidade implementada no cliente:

- Intervalo mínimo entre heartbeats: `30s`
- Timeout por requisição: `10s`
- Retry automático por ciclo: `2` tentativas
- Delay entre tentativas: `2s`
- Em Windows instalado, envio só deve ocorrer com serviço EcoRemoto ativo.

## Regras de status no painel

Status recomendado (complementar, sem quebrar dados existentes):

- `ONLINE`: heartbeat dentro da janela recente
- `DELAY`: heartbeat com atraso moderado
- `OFFLINE`: sem heartbeat por tempo definido

Sugestão inicial de janelas:

- ONLINE: `<= 60s`
- DELAY: `> 60s` e `<= 180s`
- OFFLINE: `> 180s`

## Observabilidade mínima

Cliente:

- log de envio com sucesso (periódico)
- log de falha por tentativa
- log de recuperação após falhas consecutivas

API:

- log de recebimento
- log de rejeição por `x-api-key` ausente/inválida
