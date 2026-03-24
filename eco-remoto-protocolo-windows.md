# Eco-Remote no Windows: Botao Conectar nao abre com app aberto

Este documento explica o problema e o procedimento de correcao para o botao **Conectar** quando o Eco-Remote ja esta aberto no Windows.

## Sintomas
- No painel, ao clicar em **Conectar**, nao abre a conexao.
- No console do navegador aparece `Launched external handler for 'eco-remote://<id>'`.
- Se fechar o Eco-Remote e os servicos, o botao passa a funcionar.

## Causa
O processo do Eco-Remote aberto interceptava a chamada do protocolo e encerrava a nova instancia antes de processar o comando.  
Com isso, o link `eco-remote://<id>` era disparado, mas a conexao nao iniciava.

## Correcao definitiva (codigo)
Foram aplicadas duas mudancas principais no RustDesk (Eco-Remote):
- Permitir nova instancia quando o Windows chamar o protocolo (`eco-remote://...`).
- Permitir nova instancia quando a chamada vier como `--connect` (via launcher do protocolo).

Arquivos alterados:
- `rustdesk/flutter/windows/runner/main.cpp`
- `rustdesk/src/core_main.rs`
- `rustdesk/src/platform/windows.rs`


## Como aplicar na sua maquina
1. Atualizar o codigo:
```
cd D:\Projetos Delphi\Rustdesk\rustdesk
git pull
```

2. Rebuild e gerar instalador:
```
.\tools\eco_compile_windows.ps1 -FlutterSdkPath "D:\flutter" -InstallCodegen -CreateExeInstaller
```

3. Instalar o Eco-Remote gerado.

4. Testar com o app aberto:
- Abrir o Eco-Remote.
- No painel, clicar em **Conectar** para um cliente.


## Verificacao rapida
Para confirmar que o protocolo esta registrado corretamente no Windows:
```
reg query "HKCR\eco-remote\shell\open\command" /ve
```
O resultado esperado:
```
(padrão)    REG_SZ    "C:\Program Files\RustDesk\eco-remoto.exe" "%1"
```


## Se voltar a falhar
- Garanta que o build instalado veio do codigo atualizado.
- Repita os passos de `git pull` + rebuild + reinstalacao.
- Teste novamente com o Eco-Remote aberto e fechado.
