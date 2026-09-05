# Transpose — Plano de Implementação

Ferramenta CLI para "re-versionar" pacotes de transporte do One Identity Manager
(change labels / transportes exportados pelo Database Transporter), permitindo
importar um transporte exportado numa versão do OIM (ex.: 9.2) em uma base de
versão diferente (9.3, 10.0).

## 1. O que a análise do transporte real revelou

Analisado: um transporte real exportado de uma base 9.2
(`Transport_MSSQL_<servidor>_<base>_<timestamp>.zip`).

Estrutura interna:

```
Transport.xml                          ← manifesto (1.3 KB)
ShellTransport/
  EntraID LastLogon.xml                ← sync project serializado (ObjectContainer)
  SAP IAS Connector.xml
```

A versão aparece em **três lugares**, e é isso que quebra o rezip manual:

1. **`Transport.xml`** → `<Parameter Name="Version">9.2</Parameter>` no `<Header>`,
   e `<Modules>` com versões de módulo completas (`CCC 9.2.2.636`, `DPR 9.2.2.635`,
   `QBM 9.2.2.636`).
2. **Comentário do ZIP** (campo comment do End of Central Directory) — o
   DBTransporter grava ali uma cópia de todos os parâmetros do header
   (`Version=9.2`, `DBName=...`, etc.) **mais uma linha `Signature=5D64D753`**.
3. Os XMLs internos do ShellTransport **não** contêm hash nem versão de produto
   (apenas versões de registro `Version="2"` dos DbObjects — irrelevantes).

### A origem do erro de "SHA diferente"

- Ferramentas comuns (7-Zip, Explorer, `Compress-Archive`) **descartam o
  comentário do zip** ao recompactar → o importador não acha os metadados ou
  acusa pacote inválido/adulterado.
- Mesmo preservando o comentário, alterar `Version=` invalida a `Signature`.
- A `Signature` tem 8 dígitos hex (32 bits, cara de CRC). Testei CRC32 (zlib),
  CRC32 sem xor final, CRC32C, Adler32, MD5/SHA1 truncados, sobre: Transport.xml,
  comentário (com/sem linha Signature, UTF-8/UTF-16, CRLF/LF), central directory,
  bytes locais do zip, CRCs das entradas concatenados, valores dos parâmetros
  concatenados. **Nenhum bateu** → é um checksum proprietário da One Identity
  (implementado em `VI.Base.dll` / `VI.Transport.dll`).

## 2. Estratégia

### Fase 0 — Descobrir o algoritmo da Signature (bloqueador, ~meio dia)

No diretório de instalação do OIM (workstation com Designer/DBTransporter):

- Abrir com ILSpy/dnSpy: `VI.Base.dll`, `VI.Transport.dll`, `VI.DB.dll`,
  `DBTransporterCMD.exe`. Buscar por `"Signature"`, escrita/leitura do zip
  comment, e a mensagem de erro exata que o importador exibe.
- É análise do software licenciado do próprio cliente para interoperabilidade —
  sem redistribuição de código.

Dois desfechos possíveis:

- **(a) Algoritmo simples** (CRC custom, hash caseiro) → reimplementar na
  ferramenta. Portável, sem dependências.
- **(b) Complexo/ofuscado** → a ferramenta (em C#) carrega o próprio DLL da
  instalação via reflection e chama o método original para recalcular. Robusto
  e imune a mudanças entre versões (usa sempre o DLL da versão alvo).

Verificar também, antes de investir: se a validação da Signature é *fatal* ou
apenas warning, e se o `DBTransporterCMD` tem flag que relaxa o check de
versão/assinatura (economizaria a fase inteira).

### Fase 1 — MVP CLI (C# / .NET 8, exe single-file)

C# porque: (1) permite o plano B da reflection sobre os DLLs VI.*; (2) mundo
OIM é Windows/.NET; (3) exe único sem runtime pra distribuir a colegas.

Comandos:

```
transpose inspect  <transporte.zip>
    → mostra versão, módulos, parâmetros do header, Signature, e valida
      consistência (Transport.xml × comentário do zip)

transpose retarget <transporte.zip> --to 9.3 [--out <saida.zip>] [--module-versions 9.3.0.xxx]
    → 1. edita Version no Transport.xml (in-place na entrada do zip)
      2. reescreve o comentário do zip com o Version novo
      3. recalcula e grava a Signature
      4. preserva timestamps, ordem e compressão das entradas
      5. NUNCA sobrescreve o original (gera *_retarget_9.3.zip por padrão)
```

Critério de aceite do MVP: um `retarget` sem mudança de versão (9.2 → 9.2) gera
zip que o Designer/DBTransporter importa sem nenhum erro; depois, 9.2 → 9.3
importa numa base QAS 9.3.

### Fase 2 — Robustez

- `--module-versions`: reescrever as versões em `<Modules>` (o importador pode
  comparar com os módulos da base alvo; se necessário, opção de ler as versões
  direto da base alvo via connection string).
- Suporte a **XML avulso** (change label exportado como XML puro) — mapear onde
  a versão aparece nesse formato (ficou para depois, conforme combinado).
- `--dry-run` (mostra o diff sem gravar), modo batch (pasta inteira), log.
- Testes automatizados de round-trip byte a byte.

### Fase 3 — "Algo bonitinho" (depois)

O core vira uma lib; em cima dela, TUI (Spectre.Console) ou mini web UI com
drag-and-drop do zip. Decidir quando o CLI estiver provado em campo.

## 3. Riscos e avisos (importante para uso em cliente)

- Trocar a versão **engana o check, não converte o conteúdo**: colunas/
  propriedades que mudaram entre 9.2 → 9.3 → 10.0 continuam com o schema velho
  no XML. Para sync projects (DPR) costuma funcionar porque o shell é
  recriado/patcheado no alvo, mas o import pode gerar warnings ou skips — a
  ferramenta deve imprimir um aviso padrão.
- Sempre validar primeiro em QAS, com transporte pequeno.
- Guardar o zip original intacto (a ferramenta já força isso).

## 4. Status (2026-09-05)

- **Fase 0 CONCLUÍDA**: algoritmo extraído do IL de `VI.Transport.Base.dll`
  (`Transport::CreateFileCRC`): `Signature = 0xDEADBEEF XOR CRC32(cada entrada
  do zip)`, formatada em hex maiúsculo sem padding. Comentário gerado por
  `_SetFileComments` (título + `Nome=Valor` CRLF + `Signature=` sem newline
  final); validado por `LoadFileCRC` no import.
- **Fase 1 MVP ENTREGUE**: `transpose.ps1` (PowerShell 7) com `inspect` e `retarget`.
  Testado no transporte real 9.2: assinatura calculada bate com a original e o
  retarget 9.2→9.3 regenera XML + comentário + assinatura consistentes.
- **Fase 2 (módulos + dry-run) ENTREGUE**: regras de validação do import
  extraídas do IL de `VI.Transport.Wizards.PageFileLoad::VerifyTransportImport`:
  - CRC divergente → apenas warning Sim/Não (e é **logado no journal** com
    usuário/máquina — fica rastro auditável).
  - `GetVersionDiff`: Major.Minor do header `Version` ≠ `EditionVersion` da
    base → **erro fatal** (existe um bypass interno `TransportVariables.Force`).
  - Módulo do transporte ausente na base → erro fatal.
  - Versão de módulo: compara **só Major.Minor** com o módulo da base alvo,
    **pulando o CCC** → mismatch é erro fatal.
  Por isso o `retarget` agora reescreve também o Major.Minor de `<Modules>`
  (default), aceita `-ModuleVersions "DPR=9.3.0.12,..."` para versões exatas,
  `-KeepModuleVersions` para não mexer, e `-DryRun` para pré-visualizar.
- **Compatibilidade PS 5.1**: `transpose.ps1` agora roda no Windows PowerShell 5.1
  nativo (CRCs lidos direto do central directory do zip; arquivo salvo com BOM
  UTF-8; sem sufixos numéricos do PS7). Testado nas duas versões com
  assinaturas idênticas. `README.md` criado para distribuição a colegas.
- **Port C# ENTREGUE**: `src/` (net8.0) → `dist/transpose.exe` autocontido win-x64
  (~64 MB, sem dependência de .NET na máquina destino). Mesma CLI com flags
  `--to/--out/--module-versions/--keep-module-versions/--dry-run`. Paridade
  validada contra o transpose.ps1 (assinaturas idênticas no mesmo input).
- Pendente: teste de import real numa base QAS 9.3 (validação de campo);
  XML avulso (change label puro).

## 5. Próximo passo imediato

Testar o import de um zip re-versionado (`transpose.ps1 retarget ... -To 9.3`) numa
base QAS da versão alvo, observando o comportamento do Database Transporter /
Designer. Se aprovado, seguir para a Fase 2 (module versions, XML avulso,
dry-run/batch).
