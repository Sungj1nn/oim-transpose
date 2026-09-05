# Transpose

*A mesma carga, em outra tonalidade.*

Re-versiona transportes / change labels do One Identity Manager para permitir
importar um export de uma versão (ex.: 9.2) em uma base de versão diferente
(ex.: 9.3, 10.0), corrigindo a assinatura interna do pacote para o importador
aceitar sem erro de integridade.

Duas formas de usar, com comportamento idêntico:

- **`dist\transpose.exe`** — executável único autocontido (win-x64, ~64 MB, não
  precisa de .NET instalado). Recompilar: `dotnet publish -c Release -o dist`
  dentro de `src\`.
- **`transpose.ps1`** — script para **Windows PowerShell 5.1** (nativo do Windows) e
  **PowerShell 7**, nenhuma instalação necessária.

## Uso (exe)

```powershell
transpose inspect  .\Transport_....zip
transpose retarget .\Transport_....zip --to 9.3 [--out saida.zip] [--dry-run]
             [--module-versions "DPR=9.3.0.12,QBM=9.3.0.15"] [--keep-module-versions]
```

## Uso (script)

```powershell
# ver o que tem dentro (versao, modulos, assinatura):
powershell -File transpose.ps1 inspect .\Transport_MSSQL_SERVIDOR_BASE_20260824.zip

# simular sem gravar nada:
powershell -File transpose.ps1 retarget .\Transport_....zip -To 9.3 -DryRun

# gerar o zip re-versionado (o original nunca e alterado):
powershell -File transpose.ps1 retarget .\Transport_....zip -To 9.3
# -> gera Transport_..._retarget_9.3.zip
```

### Opções do retarget

| Opção | Efeito |
|---|---|
| `-To <versao>` | Versão alvo (obrigatória), ex.: `9.3`, `10.0` |
| `-Out <arquivo>` | Caminho de saída (default: `*_retarget_<versao>.zip` ao lado do original) |
| `-ModuleVersions "DPR=9.3.0.12,QBM=9.3.0.15"` | Versão exata por módulo (use se souber os builds da base alvo) |
| `-KeepModuleVersions` | Não altera as versões de `<Modules>` |
| `-DryRun` | Mostra o que mudaria sem gravar |

## O que ele altera

1. `<Parameter Name="Version">` no `Transport.xml` dentro do zip;
2. as versões dos módulos em `<Modules>` (só Major.Minor por padrão — é o que
   o importador compara; o módulo CCC é ignorado pela checagem, mas é ajustado
   por consistência);
3. o comentário EOCD do zip (metadados que o DBTransporter lê antes de abrir)
   com a nova versão e a **Signature recalculada** — o famoso erro de
   "hash/SHA diferente" vem daí: a assinatura é
   `0xDEADBEEF XOR CRC32(cada arquivo do zip)`, e qualquer recompactação manual
   a invalida (ou perde o comentário por completo).

Todo o resto é preservado byte a byte, e o zip original nunca é modificado.

## Avisos importantes

- A ferramenta engana a checagem de versão do importador — ela **não converte**
  o conteúdo para o schema da versão alvo. Mudanças de schema entre versões
  continuam lá. **Sempre valide primeiro em QAS com um transporte pequeno.**
- Import com assinatura divergente é registrado no journal da base (usuário e
  máquina). Com a assinatura corrigida pela ferramenta, esse registro não ocorre.
- A checagem do importador compara apenas Major.Minor (da versão do header e
  das versões de módulo) com a base alvo; módulo presente no transporte e
  ausente na base alvo bloqueia o import.
