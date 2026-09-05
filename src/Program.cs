// Change-Label Corretor (clc) — re-versiona transportes do One Identity Manager.
// Port C# do clc.ps1. Algoritmo da assinatura extraído de VI.Transport.Base.dll
// (Transport::CreateFileCRC / _SetFileComments / LoadFileCRC):
//   Signature = 0xDEADBEEF XOR CRC32(cada entrada do zip), hex maiúsculo sem padding,
//   gravada como última linha do comentário EOCD do zip.

using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

return Cli.Run(args);

static class Cli
{
    public static int Run(string[] args)
    {
        try
        {
            if (args.Length < 2) return Usage();
            var command = args[0].ToLowerInvariant();
            var path = Path.GetFullPath(args[1]);
            if (!File.Exists(path)) throw new FileNotFoundException($"Arquivo nao encontrado: {path}");

            switch (command)
            {
                case "inspect":
                    Commands.Inspect(path);
                    return 0;
                case "retarget":
                    var opt = RetargetOptions.Parse(args.Skip(2).ToArray());
                    Commands.Retarget(path, opt);
                    return 0;
                default:
                    return Usage();
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"ERRO: {ex.Message}");
            return 1;
        }
    }

    static int Usage()
    {
        Console.WriteLine("""
            Change-Label Corretor (clc) — re-versiona transportes do One Identity Manager

            Uso:
              clc inspect  <transporte.zip>
              clc retarget <transporte.zip> --to <versao> [opcoes]

            Opcoes do retarget:
              --to <versao>              versao alvo (ex.: 9.3, 10.0)  [obrigatoria]
              --out <arquivo>            saida (default: *_retarget_<versao>.zip)
              --module-versions <lista>  versao exata por modulo, ex.: DPR=9.3.0.12,QBM=9.3.0.15
              --keep-module-versions     nao alterar as versoes de <Modules>
              --dry-run                  mostrar mudancas sem gravar
            """);
        return 2;
    }
}

sealed record RetargetOptions(string To, string? Out, string? ModuleVersions, bool KeepModuleVersions, bool DryRun)
{
    public static RetargetOptions Parse(string[] args)
    {
        string? to = null, @out = null, moduleVersions = null;
        bool keep = false, dryRun = false;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--to": to = Next(args, ref i); break;
                case "--out": @out = Next(args, ref i); break;
                case "--module-versions": moduleVersions = Next(args, ref i); break;
                case "--keep-module-versions": keep = true; break;
                case "--dry-run": dryRun = true; break;
                default: throw new ArgumentException($"Opcao desconhecida: {args[i]}");
            }
        }
        if (string.IsNullOrEmpty(to)) throw new ArgumentException("Informe a versao alvo com --to (ex.: --to 9.3)");
        if (!Regex.IsMatch(to, @"^\d+\.\d+")) throw new ArgumentException($"Versao alvo invalida: {to}");
        return new RetargetOptions(to, @out, moduleVersions, keep, dryRun);

        static string Next(string[] a, ref int i) =>
            ++i < a.Length ? a[i] : throw new ArgumentException($"Valor ausente para {a[i - 1]}");
    }
}

static class Commands
{
    public static void Inspect(string zipPath)
    {
        var xmlText = TransportZip.ReadTransportXml(zipPath);
        var header = TransportZip.ParseHeaderParameters(xmlText);
        var comment = TransportZip.GetComment(zipPath);
        var computed = TransportZip.FormatSignature(TransportZip.ComputeSignature(zipPath));

        Console.WriteLine($"\n=== {Path.GetFileName(zipPath)} ===\n");
        Console.WriteLine("[Header do Transport.xml]");
        foreach (var (name, value) in header) Console.WriteLine($"  {name + ":",-13}{value}");

        Console.WriteLine("\n[Modulos]");
        foreach (var m in TransportZip.ParseModules(xmlText))
            Console.WriteLine($"  {m.Id,-6}{m.Version,-13}{m.Name}");

        Console.WriteLine("\n[Assinatura]");
        Console.WriteLine($"  Calculada (0xDEADBEEF XOR CRC32s): {computed}");
        var match = Regex.Match(comment, "Signature=(?<ID>[0-9A-F]{1,16})");
        if (match.Success)
        {
            var stored = match.Groups["ID"].Value;
            Console.WriteLine($"  Gravada no comentario do zip:      {stored}  [{(stored == computed ? "OK" : "DIVERGENTE!")}]");
        }
        else
        {
            Console.WriteLine("  Comentario do zip sem Signature (import falharia)");
        }

        var commentVersion = Regex.Match(comment, @"(?m)^Version=(?<V>.+?)\r?$");
        var headerVersion = header.FirstOrDefault(p => p.Name == "Version").Value;
        if (commentVersion.Success && headerVersion is not null && commentVersion.Groups["V"].Value != headerVersion)
            Console.WriteLine($"\n  AVISO: Version difere entre Transport.xml ({headerVersion}) e comentario ({commentVersion.Groups["V"].Value})");
        Console.WriteLine();
    }

    public static void Retarget(string zipPath, RetargetOptions opt)
    {
        var outPath = opt.Out is not null
            ? Path.GetFullPath(opt.Out)
            : Path.Combine(Path.GetDirectoryName(zipPath)!,
                $"{Path.GetFileNameWithoutExtension(zipPath)}_retarget_{opt.To}.zip");
        if (string.Equals(outPath, zipPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Saida nao pode sobrescrever o original");

        var originalXml = TransportZip.ReadTransportXml(zipPath);
        var (newXml, oldVersion, moduleChanges) = TransportZip.RewriteVersions(
            originalXml, opt.To, opt.ModuleVersions, opt.KeepModuleVersions);

        if (opt.DryRun)
        {
            Console.WriteLine($"\n[DRY-RUN] Version: {oldVersion} -> {opt.To}");
            if (moduleChanges.Count > 0)
            {
                Console.WriteLine("[DRY-RUN] Modulos:");
                foreach (var c in moduleChanges) Console.WriteLine($"  {c}");
            }
            Console.WriteLine("[DRY-RUN] Nada gravado.\n");
            return;
        }

        File.Copy(zipPath, outPath, overwrite: true);
        TransportZip.WriteTransportXml(outPath, newXml);

        // recalcula a assinatura sobre o zip final e regenera o comentario
        // completo a partir do header ja modificado (logica do _SetFileComments)
        var header = TransportZip.ParseHeaderParameters(newXml);
        var sig = TransportZip.FormatSignature(TransportZip.ComputeSignature(outPath));
        TransportZip.SetComment(outPath, TransportZip.BuildComment(header, sig));

        Console.WriteLine($"\nOK: {oldVersion} -> {opt.To}");
        if (moduleChanges.Count > 0)
        {
            Console.WriteLine("Modulos:");
            foreach (var c in moduleChanges) Console.WriteLine($"  {c}");
        }
        Console.WriteLine($"Gerado: {outPath}");
        Console.WriteLine($"Assinatura recalculada: {sig}");
        Console.WriteLine("\nAVISO: a troca de versao engana a checagem do importador, mas nao converte");
        Console.WriteLine("o conteudo para o schema da versao alvo. Valide primeiro em ambiente QAS.\n");
    }
}

static class TransportZip
{
    // ---------- assinatura ----------

    public static long ComputeSignature(string zipPath)
    {
        long crc = 0xDEADBEEF;                      // conv.u8 no IL original: zero-extend
        using var zip = ZipFile.OpenRead(zipPath);
        foreach (var entry in zip.Entries) crc ^= entry.Crc32;
        return crc;
    }

    public static string FormatSignature(long crc) => crc.ToString("X");

    // ---------- comentario EOCD ----------

    static int FindEocd(byte[] bytes)
    {
        int min = Math.Max(0, bytes.Length - 65558);
        for (int i = bytes.Length - 22; i >= min; i--)
            if (bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06)
                return i;
        throw new InvalidDataException("EOCD nao encontrado — o arquivo nao parece ser um zip valido");
    }

    public static string GetComment(string zipPath)
    {
        var bytes = File.ReadAllBytes(zipPath);
        int eocd = FindEocd(bytes);
        int len = BitConverter.ToUInt16(bytes, eocd + 20);
        return len == 0 ? "" : Encoding.UTF8.GetString(bytes, eocd + 22, len);
    }

    public static void SetComment(string zipPath, string comment)
    {
        var bytes = File.ReadAllBytes(zipPath);
        int eocd = FindEocd(bytes);
        var commentBytes = Encoding.UTF8.GetBytes(comment);
        if (commentBytes.Length > ushort.MaxValue) throw new InvalidDataException("Comentario excede 65535 bytes");
        using var fs = File.Open(zipPath, FileMode.Open, FileAccess.ReadWrite);
        fs.SetLength(eocd + 22);
        fs.Position = eocd + 20;
        fs.Write(BitConverter.GetBytes((ushort)commentBytes.Length));
        fs.Position = eocd + 22;
        fs.Write(commentBytes);
    }

    public static string BuildComment(IReadOnlyList<(string Name, string Value)> headerParams, string signatureHex)
    {
        // replica _SetFileComments: titulo + Nome=Valor (CRLF) + Signature= sem newline final
        var sb = new StringBuilder();
        sb.Append("One Identity Manager Transport File\r\n");
        foreach (var (name, value) in headerParams) sb.Append($"{name}={value}\r\n");
        sb.Append($"Signature={signatureHex}");
        return sb.ToString();
    }

    // ---------- Transport.xml ----------

    public static string ReadTransportXml(string zipPath)
    {
        using var zip = ZipFile.OpenRead(zipPath);
        var entry = zip.GetEntry("Transport.xml")
            ?? throw new InvalidDataException("Transport.xml nao encontrado no zip");
        using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
        return reader.ReadToEnd();
    }

    public static void WriteTransportXml(string zipPath, string xmlText)
    {
        using var zip = ZipFile.Open(zipPath, ZipArchiveMode.Update);
        var entry = zip.GetEntry("Transport.xml")
            ?? throw new InvalidDataException("Transport.xml nao encontrado no zip");
        var lastWrite = entry.LastWriteTime;
        using (var stream = entry.Open())
        {
            stream.SetLength(0);
            using var writer = new StreamWriter(stream, new UTF8Encoding(false));
            writer.Write(xmlText);
        }
        entry.LastWriteTime = lastWrite;
    }

    public static IReadOnlyList<(string Name, string Value)> ParseHeaderParameters(string xmlText)
    {
        // ordem preservada — o comentario e gerado na mesma ordem (_SetFileComments)
        var doc = new XmlDocument();
        doc.LoadXml(xmlText);
        var result = new List<(string, string)>();
        foreach (XmlElement p in doc.SelectNodes("/DBTransporter/Header/Parameter")!)
            result.Add((p.GetAttribute("Name"), p.InnerText));
        return result;
    }

    public static IReadOnlyList<(string Id, string Name, string Version)> ParseModules(string xmlText)
    {
        var doc = new XmlDocument();
        doc.LoadXml(xmlText);
        var result = new List<(string, string, string)>();
        foreach (XmlElement m in doc.SelectNodes("/DBTransporter/Modules/Module")!)
            result.Add((m.GetAttribute("Id"), m.GetAttribute("Name"), m.GetAttribute("Version")));
        return result;
    }

    public static (string NewXml, string OldVersion, List<string> ModuleChanges) RewriteVersions(
        string xmlText, string targetVersion, string? explicitModuleVersions, bool keepModuleVersions)
    {
        var versionPattern = new Regex("(<Parameter Name=\"Version\">)([^<]*)(</Parameter>)");
        var versionMatch = versionPattern.Match(xmlText);
        if (!versionMatch.Success) throw new InvalidDataException("Parametro Version nao encontrado no Transport.xml");
        var oldVersion = versionMatch.Groups[2].Value;
        var newXml = versionPattern.Replace(xmlText, $"${{1}}{targetVersion}${{3}}", 1);

        var moduleChanges = new List<string>();
        if (!keepModuleVersions)
        {
            // O import (PageFileLoad::VerifyTransportImport) compara Major.Minor de
            // cada modulo nao-CCC com o modulo da base alvo — mismatch bloqueia.
            var explicitMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!string.IsNullOrEmpty(explicitModuleVersions))
            {
                foreach (var pair in explicitModuleVersions.Split(','))
                {
                    var parts = pair.Trim().Split('=', 2);
                    if (parts.Length != 2)
                        throw new ArgumentException($"Formato invalido em --module-versions (use Id=Versao,...): {pair}");
                    explicitMap[parts[0].Trim()] = parts[1].Trim();
                }
            }
            var target = Version.Parse(targetVersion.Split('.').Length < 2 ? targetVersion + ".0" : targetVersion);

            newXml = Regex.Replace(newXml,
                "(?<pre><Module Id=\"(?<id>[^\"]+)\"[^>]*Version=\")(?<ver>[^\"]*)(?<q>\")",
                m =>
                {
                    var id = m.Groups["id"].Value;
                    var old = m.Groups["ver"].Value;
                    string @new;
                    if (explicitMap.TryGetValue(id, out var exact))
                    {
                        @new = exact;
                    }
                    else
                    {
                        var parts = old.Split('.');
                        var rest = parts.Length > 2 ? "." + string.Join('.', parts.Skip(2)) : "";
                        @new = $"{target.Major}.{target.Minor}{rest}";
                    }
                    if (@new != old) moduleChanges.Add($"{id} : {old} -> {@new}");
                    return m.Groups["pre"].Value + @new + m.Groups["q"].Value;
                });
        }
        return (newXml, oldVersion, moduleChanges);
    }
}
