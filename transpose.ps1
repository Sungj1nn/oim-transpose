<#
.SYNOPSIS
  Transpose — re-versiona transportes do One Identity Manager.

.DESCRIPTION
  Permite importar um transporte exportado numa versao do OIM (ex.: 9.2) em uma
  base de versao diferente (ex.: 9.3), reescrevendo:
    1. <Parameter Name="Version"> no Transport.xml dentro do zip
    2. a linha Version= no comentario EOCD do zip
    3. a Signature do comentario (0xDEADBEEF XOR CRC32 de cada entrada do zip,
       formatada em hex maiusculo sem padding — algoritmo do VI.Transport.Base:
       Transport::CreateFileCRC / _SetFileComments / LoadFileCRC)

.EXAMPLE
  pwsh -File transpose.ps1 inspect  .\Transport_....zip
  pwsh -File transpose.ps1 retarget .\Transport_....zip -To 9.3
  pwsh -File transpose.ps1 retarget .\Transport_....zip -To 10.0 -Out .\saida.zip
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('inspect', 'retarget')][string]$Command,
    [Parameter(Mandatory, Position = 1)][string]$Path,
    [string]$To,
    [string]$Out,
    # versoes exatas por modulo, ex.: -ModuleVersions "DPR=9.3.0.12,QBM=9.3.0.15"
    # (sem isso, o retarget troca so o Major.Minor de cada modulo pelo de -To)
    [string]$ModuleVersions,
    # nao mexer nas versoes de <Modules> (o import compara Major.Minor dos
    # modulos nao-CCC com a base alvo e bloqueia se divergirem)
    [switch]$KeepModuleVersions,
    # mostra o que mudaria sem gravar nada
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# ---------- helpers de baixo nivel (EOCD / comentario do zip) ----------

function Find-Eocd([byte[]]$bytes) {
    # End of Central Directory: assinatura PK\x05\x06, procurada de tras pra frente
    $min = [Math]::Max(0, $bytes.Length - 65558)
    for ($i = $bytes.Length - 22; $i -ge $min; $i--) {
        if ($bytes[$i] -eq 0x50 -and $bytes[$i + 1] -eq 0x4B -and $bytes[$i + 2] -eq 0x05 -and $bytes[$i + 3] -eq 0x06) {
            return $i
        }
    }
    throw "EOCD nao encontrado — o arquivo nao parece ser um zip valido: $Path"
}

function Get-ZipComment([string]$zipPath) {
    $bytes = [IO.File]::ReadAllBytes($zipPath)
    $eocd = Find-Eocd $bytes
    $len = [BitConverter]::ToUInt16($bytes, $eocd + 20)
    if ($len -eq 0) { return '' }
    return [Text.Encoding]::UTF8.GetString($bytes, $eocd + 22, $len)
}

function Set-ZipComment([string]$zipPath, [string]$comment) {
    $bytes = [IO.File]::ReadAllBytes($zipPath)
    $eocd = Find-Eocd $bytes
    $commentBytes = [Text.Encoding]::UTF8.GetBytes($comment)
    if ($commentBytes.Length -gt 65535) { throw "Comentario excede 65535 bytes" }
    $fs = [IO.File]::Open($zipPath, 'Open', 'ReadWrite')
    try {
        $fs.SetLength($eocd + 22)                 # descarta comentario antigo
        $fs.Position = $eocd + 20
        $fs.Write([BitConverter]::GetBytes([uint16]$commentBytes.Length), 0, 2)
        $fs.Position = $eocd + 22
        $fs.Write($commentBytes, 0, $commentBytes.Length)
    } finally { $fs.Dispose() }
}

# ---------- assinatura (algoritmo do VI.Transport.Base) ----------

function Get-ZipEntryInfo([string]$zipPath) {
    # le CRC32/tamanhos direto do central directory — funciona tambem no
    # Windows PowerShell 5.1, onde ZipArchiveEntry nao expoe Crc32
    $bytes = [IO.File]::ReadAllBytes($zipPath)
    $eocd = Find-Eocd $bytes
    $count = [BitConverter]::ToUInt16($bytes, $eocd + 10)
    $pos = [BitConverter]::ToUInt32($bytes, $eocd + 16)
    $entries = @()
    for ($n = 0; $n -lt $count; $n++) {
        if (-not ($bytes[$pos] -eq 0x50 -and $bytes[$pos+1] -eq 0x4B -and $bytes[$pos+2] -eq 0x01 -and $bytes[$pos+3] -eq 0x02)) {
            throw "Central directory corrompido em $zipPath (offset $pos)"
        }
        $nameLen = [BitConverter]::ToUInt16($bytes, $pos + 28)
        $extraLen = [BitConverter]::ToUInt16($bytes, $pos + 30)
        $cmtLen = [BitConverter]::ToUInt16($bytes, $pos + 32)
        $entries += [pscustomobject]@{
            Name = [Text.Encoding]::UTF8.GetString($bytes, $pos + 46, $nameLen)
            Crc = [long][BitConverter]::ToUInt32($bytes, $pos + 16)
            Size = [BitConverter]::ToUInt32($bytes, $pos + 24)
        }
        $pos += 46 + $nameLen + $extraLen + $cmtLen
    }
    return $entries
}

function Get-TransportSignature([string]$zipPath) {
    # 3735928559 = 0xDEADBEEF sem sinal (o IL original usa conv.u8 = zero-extend;
    # literal hex viraria Int32 negativo, e o sufixo L so existe no PS 7)
    [long]$crc = 3735928559
    foreach ($e in Get-ZipEntryInfo $zipPath) { $crc = $crc -bxor $e.Crc }
    return $crc
}

function Format-Signature([long]$crc) { return $crc.ToString('X') }

# ---------- Transport.xml ----------

function Get-TransportXml([string]$zipPath) {
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'Transport.xml' }
        if (-not $entry) { throw "Transport.xml nao encontrado no zip" }
        $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-HeaderParameters([xml]$doc) {
    # preserva a ordem do XML — o comentario e gerado na mesma ordem (_SetFileComments)
    $params = [ordered]@{}
    foreach ($p in $doc.DBTransporter.Header.Parameter) { $params[$p.Name] = $p.'#text' }
    return $params
}

function New-TransportComment($headerParams, [string]$signatureHex) {
    # replica VI.Transport.Transport::_SetFileComments: titulo, Nome=Valor por
    # parametro (AppendLine = CRLF), e "Signature=..." SEM newline final
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("One Identity Manager Transport File`r`n")
    foreach ($kv in $headerParams.GetEnumerator()) {
        [void]$sb.Append("$($kv.Key)=$($kv.Value)`r`n")
    }
    [void]$sb.Append("Signature=$signatureHex")
    return $sb.ToString()
}

# ---------- comandos ----------

function Invoke-Inspect([string]$zipPath) {
    $xmlText = Get-TransportXml $zipPath
    [xml]$doc = $xmlText
    $params = Get-HeaderParameters $doc
    $comment = Get-ZipComment $zipPath
    $computed = Format-Signature (Get-TransportSignature $zipPath)

    Write-Host "`n=== $([IO.Path]::GetFileName($zipPath)) ===" -ForegroundColor Cyan
    Write-Host "`n[Header do Transport.xml]"
    foreach ($kv in $params.GetEnumerator()) { Write-Host ("  {0,-12} {1}" -f ($kv.Key + ':'), $kv.Value) }
    Write-Host "`n[Modulos]"
    foreach ($m in $doc.DBTransporter.Modules.Module) { Write-Host ("  {0,-5} {1,-12} {2}" -f $m.Id, $m.Version, $m.Name) }

    Write-Host "`n[Assinatura]"
    Write-Host "  Calculada (0xDEADBEEF XOR CRC32s): $computed"
    if ($comment -match 'Signature=(?<ID>[0-9A-F]{1,16})') {
        $stored = $Matches['ID']
        $status = if ($stored -eq $computed) { 'OK' } else { 'DIVERGENTE!' }
        Write-Host "  Gravada no comentario do zip:      $stored  [$status]" -ForegroundColor $(if ($stored -eq $computed) { 'Green' } else { 'Red' })
    } else {
        Write-Host "  Comentario do zip sem Signature (import falharia)" -ForegroundColor Red
    }

    if ($comment -match '(?m)^Version=(?<V>.+?)\r?$') {
        $cv = $Matches['V']
        if ($cv -ne $params['Version']) {
            Write-Host "`n  AVISO: Version difere entre Transport.xml ($($params['Version'])) e comentario ($cv)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

function Update-ModuleVersions([string]$xmlText, [string]$targetVersion, [string]$explicitVersions) {
    # O import (PageFileLoad::VerifyTransportImport) compara Major.Minor de cada
    # modulo nao-CCC com a versao do modulo na base alvo — mismatch bloqueia.
    # Default: troca Major.Minor mantendo build/revision; -ModuleVersions permite
    # cravar a versao exata por modulo.
    $explicit = @{}
    if ($explicitVersions) {
        foreach ($pair in $explicitVersions -split ',') {
            $id, $ver = ($pair.Trim() -split '=', 2)
            if (-not $ver) { throw "Formato invalido em -ModuleVersions (use Id=Versao,...): $pair" }
            $explicit[$id.Trim()] = $ver.Trim()
        }
    }
    $target = $null
    if ($targetVersion -notmatch '^\d+\.\d+') { throw "Versao alvo invalida: $targetVersion" }
    $target = [Version]($targetVersion + $(if (($targetVersion -split '\.').Count -lt 2) { '.0' } else { '' }))

    $changes = @()
    $newText = [regex]::Replace($xmlText, '(?<pre><Module Id="(?<id>[^"]+)"[^>]*Version=")(?<ver>[^"]*)(?<q>")', {
        param($m)
        $id = $m.Groups['id'].Value
        $old = $m.Groups['ver'].Value
        if ($explicit.ContainsKey($id)) {
            $new = $explicit[$id]
        } else {
            $parts = $old -split '\.'
            $rest = if ($parts.Count -gt 2) { '.' + (($parts | Select-Object -Skip 2) -join '.') } else { '' }
            $new = "$($target.Major).$($target.Minor)$rest"
        }
        if ($new -ne $old) { $script:moduleChanges += "  $id : $old -> $new" }
        $m.Groups['pre'].Value + $new + $m.Groups['q'].Value
    })
    return $newText
}

function Invoke-Retarget([string]$zipPath, [string]$targetVersion, [string]$outPath) {
    if (-not $targetVersion) { throw "Informe a versao alvo com -To (ex.: -To 9.3)" }
    if (-not $outPath) {
        $dir = [IO.Path]::GetDirectoryName((Resolve-Path $zipPath))
        $name = [IO.Path]::GetFileNameWithoutExtension($zipPath)
        $outPath = Join-Path $dir "${name}_retarget_${targetVersion}.zip"
    }
    if ((Resolve-Path $zipPath).Path -eq $outPath) { throw "Saida nao pode sobrescrever o original" }

    if ($DryRun) {
        $xmlText = Get-TransportXml $zipPath
        $pattern = '(<Parameter Name="Version">)([^<]*)(</Parameter>)'
        if ($xmlText -notmatch $pattern) { throw 'Parametro Version nao encontrado no Transport.xml' }
        $oldVersion = [regex]::Match($xmlText, $pattern).Groups[2].Value
        $script:moduleChanges = @()
        if (-not $KeepModuleVersions) { [void](Update-ModuleVersions $xmlText $targetVersion $ModuleVersions) }
        Write-Host "`n[DRY-RUN] Version: $oldVersion -> $targetVersion" -ForegroundColor Cyan
        if ($script:moduleChanges) { Write-Host "[DRY-RUN] Modulos:"; $script:moduleChanges | Write-Host }
        Write-Host "[DRY-RUN] Nada gravado.`n"
        return
    }

    Copy-Item -LiteralPath $zipPath -Destination $outPath -Force

    # 1. reescreve Version no Transport.xml (edicao textual minima — preserva o
    #    restante do arquivo byte a byte, incluindo indentacao e encoding)
    $zip = [IO.Compression.ZipFile]::Open($outPath, 'Update')
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'Transport.xml' }
        if (-not $entry) { throw "Transport.xml nao encontrado no zip" }
        $lastWrite = $entry.LastWriteTime
        $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
        try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }

        $pattern = '(<Parameter Name="Version">)([^<]*)(</Parameter>)'
        if ($xmlText -notmatch $pattern) { throw 'Parametro Version nao encontrado no Transport.xml' }
        $oldVersion = [regex]::Match($xmlText, $pattern).Groups[2].Value
        $newXml = [regex]::Replace($xmlText, $pattern, ('${1}' + $targetVersion + '${3}'), 1)

        $script:moduleChanges = @()
        if (-not $KeepModuleVersions) {
            $newXml = Update-ModuleVersions $newXml $targetVersion $ModuleVersions
        }

        $stream = $entry.Open()
        try {
            $stream.SetLength(0)
            $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
            $writer.Write($newXml)
            $writer.Flush()
            $writer.Dispose()
        } finally { if ($stream.CanWrite) { $stream.Dispose() } }
        $entry.LastWriteTime = $lastWrite
    } finally { $zip.Dispose() }   # Dispose grava o zip (e pode descartar o comentario — regravado abaixo)

    # 2. recalcula assinatura sobre o zip final e regenera o comentario completo
    #    a partir do header ja modificado (mesma logica do _SetFileComments)
    [xml]$doc = Get-TransportXml $outPath
    $params = Get-HeaderParameters $doc
    $sig = Format-Signature (Get-TransportSignature $outPath)
    Set-ZipComment $outPath (New-TransportComment $params $sig)

    Write-Host "`nOK: $oldVersion -> $targetVersion" -ForegroundColor Green
    if ($script:moduleChanges) { Write-Host "Modulos:"; $script:moduleChanges | Write-Host }
    Write-Host "Gerado: $outPath"
    Write-Host "Assinatura recalculada: $sig"
    Write-Host "`nAVISO: a troca de versao engana a checagem do importador, mas nao converte"
    Write-Host "o conteudo para o schema da versao alvo. Valide primeiro em ambiente QAS." -ForegroundColor Yellow
    Write-Host ""
}

switch ($Command) {
    'inspect'  { Invoke-Inspect (Resolve-Path $Path).Path }
    'retarget' { Invoke-Retarget (Resolve-Path $Path).Path $To $Out }
}
