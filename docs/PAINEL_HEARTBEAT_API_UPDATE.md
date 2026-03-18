# PainelAremoto API update plan for EcoRemoto heartbeat compatibility

Este guia implementa de forma incremental e segura a atualização da API `/api/heartbeat`
para aceitar o contrato novo do cliente EcoRemoto **sem quebrar clientes antigos**.

## Etapa 1 — Schema de entrada compatível

Regras:

- aceitar `version` (novo) **ou** `client_version` (legado)
- se `version` ausente, usar `client_version`
- se `timestamp` ausente, gerar no servidor

Exemplo (FastAPI + Pydantic):

```python
from datetime import datetime, timezone
from typing import Optional
from pydantic import BaseModel, Field, root_validator


class HeartbeatIn(BaseModel):
    client_id: str = Field(min_length=1)
    hostname: Optional[str] = ""
    username: Optional[str] = ""
    alias: Optional[str] = ""
    os: Optional[str] = ""
    ip: Optional[str] = ""
    version: Optional[str] = None
    client_version: Optional[str] = None
    timestamp: Optional[int] = None

    @root_validator(pre=False)
    def normalize_fields(cls, values):
        version = (values.get("version") or "").strip()
        legacy = (values.get("client_version") or "").strip()
        if not version and not legacy:
            raise ValueError("version or client_version is required")
        values["version"] = version or legacy
        values["client_version"] = legacy or values["version"]
        values["timestamp"] = values.get("timestamp") or int(datetime.now(tz=timezone.utc).timestamp())
        return values
```

## Etapa 2 — Autenticação obrigatória por `x-api-key`

Regras:

- header obrigatório
- rejeitar request sem chave ou com chave inválida (`401`)
- logar rejeição sem expor segredo completo

Exemplo:

```python
from fastapi import Header, HTTPException
import logging

logger = logging.getLogger("painel.heartbeat")


def validate_api_key(x_api_key: str | None, expected_key: str) -> None:
    if not x_api_key:
        logger.warning("heartbeat rejected: missing x-api-key")
        raise HTTPException(status_code=401, detail="missing api key")
    if x_api_key != expected_key:
        suffix = x_api_key[-4:] if len(x_api_key) >= 4 else "***"
        logger.warning("heartbeat rejected: invalid x-api-key suffix=%s", suffix)
        raise HTTPException(status_code=401, detail="invalid api key")
```

## Etapa 3 — Persistência com fallback não destrutivo

- persistir `version` normalizado
- manter suporte ao campo legado
- não remover colunas/estrutura atual sem migração planejada

Exemplo de normalização para banco:

```python
record = {
    "client_id": hb.client_id,
    "hostname": hb.hostname or "",
    "username": hb.username or "",
    "alias": hb.alias or "",
    "os": hb.os or "",
    "ip": hb.ip or "",
    "version": hb.version,
    "last_heartbeat_ts": hb.timestamp,
}
```

## Etapa 4 — Status inteligente (ONLINE / DELAY / OFFLINE)

Recomendação inicial (configurável por env):

- `ONLINE`: atraso `<= 60s`
- `DELAY`: atraso `> 60s` e `<= 180s`
- `OFFLINE`: atraso `> 180s`

Exemplo:

```python

def compute_status(now_ts: int, last_heartbeat_ts: int, online_s: int = 60, delay_s: int = 180) -> str:
    lag = max(0, now_ts - last_heartbeat_ts)
    if lag <= online_s:
        return "ONLINE"
    if lag <= delay_s:
        return "DELAY"
    return "OFFLINE"
```

## Etapa 5 — Endpoint final incremental (exemplo)

```python
@router.post("/api/heartbeat")
def heartbeat(payload: HeartbeatIn, x_api_key: str | None = Header(default=None, alias="x-api-key")):
    validate_api_key(x_api_key, settings.ECO_PANEL_API_KEY)

    # persist/update do heartbeat
    upsert_client_heartbeat(payload)

    logger.info(
        "heartbeat accepted client_id=%s version=%s ts=%s",
        payload.client_id,
        payload.version,
        payload.timestamp,
    )
    return {"ok": True}
```

## Observabilidade mínima

- INFO: recebimento com `client_id`, `version`, `timestamp`
- WARNING: rejeição por auth/payload inválido
- (opcional) métricas: total recebidos, rejeitados, latência

## Rollout seguro em produção

1. Deploy API com schema/fallback novo.
2. Monitorar logs de rejeição e payload inválido.
3. Confirmar que clientes legados continuam aceitos.
4. Só depois evoluir dashboards/status com os thresholds.


## Etapa 6 — Integração prática no repo do painel

Como este repositório não contém o código do painel, foi adicionado um módulo de referência pronto para uso:

- `tools/painelaremoto/heartbeat_reference.py`

Sugestão de integração no painel (repo `wasinf/painelaremoto`):

1. Copiar o módulo para `app/heartbeat_contract.py`.
2. No endpoint `POST /api/heartbeat`, usar:
   - `HeartbeatIn` para parsing + fallback (`version`/`client_version`, `timestamp`)
   - `validate_api_key` para autenticação
   - `normalize_for_storage` para persistência compatível
   - `compute_status` para ONLINE/DELAY/OFFLINE
   - `log_accept` para observabilidade

## Etapa 7 — Smoke tests de compatibilidade (curl)

### Novo payload (com `version`)

```bash
curl -i -X POST "https://painelaremoto.portalecomdo.com.br/api/heartbeat" \
  -H "Content-Type: application/json" \
  -H "x-api-key: <API_KEY>" \
  -d '{
    "client_id":"123456789",
    "hostname":"pc-01",
    "username":"admin",
    "alias":"Financeiro",
    "os":"Windows 11",
    "ip":"10.0.0.15",
    "version":"1.4.6",
    "timestamp":1732666405
  }'
```

### Payload legado (somente `client_version`)

```bash
curl -i -X POST "https://painelaremoto.portalecomdo.com.br/api/heartbeat" \
  -H "Content-Type: application/json" \
  -H "x-api-key: <API_KEY>" \
  -d '{
    "client_id":"123456789",
    "hostname":"pc-01",
    "client_version":"1.4.5"
  }'
```

### Validação esperada

- ambos os payloads devem retornar sucesso (`200`) após autenticação
- request sem `x-api-key` deve retornar `401`
- request com chave inválida deve retornar `401`
- registros devem persistir com `version` preenchido e `timestamp` definido


## Etapa 8 — Diff pronto (antes de aplicar)

Arquivo de patch incremental (sem quebrar endpoint existente):

- `tools/painelaremoto/patches/painel_heartbeat_incremental.patch`

Aplicação manual no repo do painel:

```bash
cd /opt/apps/eco-remote/panel
git checkout -b feat/heartbeat-contract-compat
git apply /opt/apps/eco-remote/rustdesk/tools/painelaremoto/patches/painel_heartbeat_incremental.patch
```

Validar e ajustar nomes de funções/modelos conforme o código atual do painel, mantendo a mesma rota `/api/heartbeat`.

## Etapa 9 — Testes mínimos (sem deploy)

Executar no repo do painel após integração:

```bash
python -m unittest -q tests/test_heartbeat_contract.py
```

Critérios de aceite:

1. payload novo com `version` + `timestamp` aceito
2. payload legado com `client_version` aceito
3. sem `x-api-key` retorna `401`
4. com `x-api-key` inválida retorna `401`
