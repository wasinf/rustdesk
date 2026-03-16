# ECO REMOTO - Build Windows (processo oficial)

## Pre-requisitos
1. Git instalado
2. Rust (rustup) instalado
3. Flutter instalado (recomendado 3.24.5)
4. Visual Studio Build Tools (C++ Desktop)
5. Python 3 instalado (para o build.py)
6. LLVM/Clang 18.x instalado (ou LLVM do Visual Studio)
7. (Opcional) Inno Setup 6 para gerar instalador `.exe`

## Passos
1. Abra PowerShell na pasta do repo `rustdesk`
   Exemplo com espaco no caminho:

```powershell
Set-Location "D:\Projetos Delphi\Rustdesk\rustdesk"
```

2. Rode o pipeline completo:

```powershell
.\tools\eco_compile_windows.ps1 -FlutterSdkPath "D:\flutter" -InstallCodegen
```

Ou use o atalho de 1 comando/1 arquivo:

```powershell
.\build-eco.cmd
```

## Fluxos recomendados

### A) Build interno (time tecnico)
```powershell
.\rebuild-deploy-ecoremoto-admin.cmd "D:\flutter"
```
Esse fluxo:
1. Compila
2. Faz deploy local
3. Remove servicos legados
4. Cria/inicia `EcoRemoto`
5. Abre tray + UI

### B) Pacote para cliente (sem Inno Setup)
```powershell
.\build-eco-installer-admin.cmd "D:\flutter"
```
Entrega para cliente:
1. `dist\eco-remote-installer-win64-<data>\Install_ECO_Remoto.cmd`
2. ou o `.zip` desse instalador

### C) Instalador `.exe` para cliente (Inno Setup)
```powershell
.\build-eco-exe-installer-admin.cmd "D:\flutter"
```
Ou direto:
```powershell
.\tools\eco_compile_windows.ps1 -FlutterSdkPath "D:\flutter" -InstallCodegen -CreateExeInstaller
```
Saida:
1. `dist\eco-remote-setup-win64-<data>.exe`

## Saida
- Executavel:
  `flutter\build\windows\x64\runner\Release\eco-remoto.exe`
- Pacote ZIP pronto para distribuir (com DLLs):
  `dist\eco-remote-win64-YYYYMMDD-HHMMSS.zip`
- Instalador ZIP:
  `dist\eco-remote-installer-win64-YYYYMMDD-HHMMSS.zip`
- Instalador EXE (se `-CreateExeInstaller`):
  `dist\eco-remote-setup-win64-YYYYMMDD-HHMMSS.exe`

## Observacoes
1. Este build ja inclui:
   - Servidor fixo `remoto.portalecomdo.com.br`
   - Heartbeat para `https://painelaremoto.portalecomdo.com.br/api/heartbeat`
   - Nome de servico Windows: `EcoRemoto`
2. O compilador gera automaticamente os arquivos FRB:
   - `src\bridge_generated.rs`
   - `flutter\lib\generated_bridge.dart`
   - `flutter\windows\runner\bridge_generated.h`
3. Se o Flutter nao estiver na versao esperada, ajuste antes do build.
4. Se aparecer erro do Visual Studio Build Tools, instale o componente de C++ Desktop.
5. Se aparecer erro de structs opacas (`_address`) em `vpx_codec_enc_cfg`/`aom_codec_enc_cfg`:
   - Seu `libclang` provavelmente esta novo demais para o bindgen usado no projeto.
   - Use LLVM 16-18 (ou LLVM do Visual Studio Build Tools).
   - O script de build interrompe com mensagem explicita.

## Opcoes uteis do compilador

```powershell
# Definir SDK Flutter explicitamente
.\tools\eco_compile_windows.ps1 -FlutterSdkPath "D:\Projetos Delphi\Rustdesk\flutter"

# Forcar um icone especifico para EXE/tray/flutter antes do build
.\tools\eco_compile_windows.ps1 -BrandIconPath "D:\Projetos Delphi\Rustdesk\rustdesk\branding\icon.ico"

# Reinstalar codegen FRB
.\tools\eco_compile_windows.ps1 -InstallCodegen

# Pular empacotamento ZIP
.\tools\eco_compile_windows.ps1 -SkipPackage

# Gerar instalador .exe (Inno Setup)
.\tools\eco_compile_windows.ps1 -FlutterSdkPath "D:\flutter" -CreateExeInstaller
```
