# ===================================================
#  Modpack Update Generator v3.0
#  Hybrid: local .jar (GitHub) + remote links (CurseForge/Modrinth)
# ===================================================
param(
    [string]$VersionBump = "patch"  # major | minor | patch
)

$ErrorActionPreference = "Stop"
$ScriptDir    = $PSScriptRoot
$ModsDir      = Join-Path $ScriptDir "files\mods"
$ManifestPath = Join-Path $ScriptDir "modpack.json"
$Changelog    = Join-Path $ScriptDir "changelog.json"
$SourcesFile  = Join-Path $ScriptDir "mod_sources.json"

# ============================================
# Helper Functions
# ============================================

function Get-PrefixFromFileName {
    param([string]$FileName)
    $name = [System.IO.Path]::GetFileName($FileName)
    if ($name -match '^([0-9a-fA-F]{8})_') {
        return $matches[1].ToLower()
    }
    return $null
}

function Get-OriginalName {
    param([string]$FileName)
    $name = [System.IO.Path]::GetFileName($FileName)
    if ($name -match '^[0-9a-fA-F]{8}_(.+)$') {
        return $matches[1]
    }
    return $name
}

function Get-JarModId {
    param([string]$JarPath)
    # Try to extract modId from jar metadata (neoforge.mods.toml / mods.toml / fabric.mod.json)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
        $modId = $null

        foreach ($entryName in @("META-INF/neoforge.mods.toml", "META-INF/mods.toml", "fabric.mod.json")) {
            $entry = $zip.GetEntry($entryName)
            if ($entry) {
                $stream = $entry.Open()
                $reader = New-Object System.IO.StreamReader($stream)
                $content = $reader.ReadToEnd()
                $reader.Dispose(); $stream.Dispose()

                if ($entryName -eq "fabric.mod.json") {
                    $json = $content | ConvertFrom-Json
                    $modId = $json.id
                } else {
                    if ($content -match 'modId\s*=\s*"([^"]+)"') {
                        $modId = $matches[1]
                    }
                }
                break
            }
        }
        $zip.Dispose()
        if ($modId) { return $modId.ToLower() }
    } catch {
        # Fall through to filename-based extraction
    }
    return $null
}

function Get-ModId {
    param([string]$FileName, [string]$JarPath)
    # Priority: jar metadata > filename heuristics
    if ($JarPath -and (Test-Path -LiteralPath $JarPath)) {
        $jarModId = Get-JarModId -JarPath $JarPath
        if ($jarModId) { return $jarModId }
    }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $name = $name -replace '^[0-9a-fA-F]{8}_', ''
    $name = $name -replace '^\[.*?\]\s*', ''
    $name = $name -replace '-(mc)?\d+\.\d+.*$', ''
    $name = $name -replace '\s*\(\d+\)\s*$', ''
    return $name.Trim().ToLower()
}

function Get-Prefix {
    param([string]$ModId)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ModId))
    $hex = [BitConverter]::ToString($hash) -replace '-',''
    return $hex.Substring(0, 8).ToLower()
}

function Bump-Version {
    param([string]$Version, [string]$Bump)
    $parts = $Version -split '\.'
    if ($parts.Count -lt 3) { $parts = @("1", "0", "0") }
    [int]$major = $parts[0]
    [int]$minor = $parts[1]
    [int]$patch = $parts[2]
    switch ($Bump) {
        "major" { $major++; $minor = 0; $patch = 0 }
        "minor" { $minor++; $patch = 0 }
        "patch" { $patch++ }
        default { $patch++ }
    }
    return "$major.$minor.$patch"
}

# ============================================
# 0. Read external source mappings (mod_sources.json)
# ============================================
$remoteSources = @{}   # prefix -> source info
$sourceStats = @{ curseforge = 0; modrinth = 0; github = 0 }

if (Test-Path -LiteralPath $SourcesFile) {
    try {
        $raw = Get-Content -LiteralPath $SourcesFile -Raw
        if ($raw.Trim()) {
            $srcData = $raw -replace '^\ufeff', '' | ConvertFrom-Json
            if ($srcData.mappings) {
                foreach ($prop in $srcData.mappings.PSObject.Properties) {
                    $pfx = $prop.Name
                    $info = $prop.Value
                    # Validate required fields
                    if ($info.source -and $info.downloadUrl -and $info.sha256) {
                        $remoteSources[$pfx] = @{
                            source      = $info.source
                            downloadUrl = $info.downloadUrl
                            sha256      = $info.sha256.ToLower()
                            fileName    = if ($info.fileName) { $info.fileName } else { "" }
                            projectName = if ($info.projectName) { $info.projectName } else { "" }
                        }
                        $sourceStats[$info.source]++
                    } else {
                        Write-Host "  [WARN] Incomplete mapping for prefix '$pfx', skipping" -ForegroundColor Yellow
                    }
                }
            }
        }
    } catch {
        Write-Host "[WARN] mod_sources.json parse failed: $_" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=== Remote Sources ===" -ForegroundColor Cyan
Write-Host "  CurseForge: $($sourceStats.curseforge) | Modrinth: $($sourceStats.modrinth) | GitHub: $($sourceStats.github)" -ForegroundColor Gray
Write-Host "  Total remote: $($remoteSources.Count)" -ForegroundColor Gray

# ============================================
# 1. Read existing manifest
# ============================================
$oldManifest = $null
$oldPrefixMap = @{}
$oldVersion = "0.0.0"

if (Test-Path -LiteralPath $ManifestPath) {
    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw
        if ($raw.Trim()) {
            $oldManifest = $raw -replace '^\ufeff', '' | ConvertFrom-Json
            $oldVersion = $oldManifest.version
            foreach ($f in $oldManifest.files) {
                if ($f.prefix) {
                    $oldPrefixMap[$f.prefix] = @{
                        path   = $f.path
                        sha256 = $f.sha256
                    }
                }
            }
        }
    } catch {
        Write-Host "[WARN] Existing modpack.json parse failed, treating as new." -ForegroundColor Yellow
    }
}

# ============================================
# 2. Collect remote-sourced mods first
# ============================================
$remoteMods = @()
$remotePrefixes = @{}   # for dedup detection

foreach ($pfx in $remoteSources.Keys) {
    $src = $remoteSources[$pfx]
    $fileName = if ($src.fileName) { $src.fileName } else { ($src.downloadUrl -split '/')[-1] }
    # URL-decode the filename
    $fileName = [System.Uri]::UnescapeDataString($fileName)
    $path = "mods/${pfx}_${fileName}"
    
    $remoteMods += @{
        prefix      = $pfx
        name        = $fileName
        path        = $path
        sha256      = $src.sha256
        source      = $src.source
        downloadUrl = $src.downloadUrl
        isRemote    = $true
    }
    $remotePrefixes[$pfx] = $true
    
    Write-Host "  [REMOTE] [$src.source] $pfx -> $fileName" -ForegroundColor Magenta
}

# ============================================
# 3. Scan local mods directory (only those NOT in remoteSources)
# ============================================
$localMods = @()
Write-Host ""
Write-Host "=== Scanning local mods (GitHub fallback) ===" -ForegroundColor Cyan

if (Test-Path -LiteralPath $ModsDir) {
    Get-ChildItem -LiteralPath $ModsDir -File -Filter "*.jar" | Sort-Object Name | ForEach-Object {
        $existingPrefix = Get-PrefixFromFileName -FileName $_.Name
        $originalName   = if ($existingPrefix) { Get-OriginalName -FileName $_.Name } else { $_.Name }
        # Use jar metadata for new files, filename fallback for already-prefixed files
        $modId          = if ($existingPrefix) { Get-ModId -FileName $originalName } else { Get-ModId -FileName $originalName -JarPath $_.FullName }
        $prefix         = if ($existingPrefix) { $existingPrefix } else { Get-Prefix -ModId $modId }
        
        # Skip if this prefix is already covered by a remote source
        if ($remotePrefixes.ContainsKey($prefix)) {
            Write-Host "  [SKIP] $($_.Name) -> remote source takes priority" -ForegroundColor DarkGray
            return
        }
        
        $newFileName    = "${prefix}_${originalName}"
        $hash           = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
        
        # Rename if needed
        if ($_.Name -ne $newFileName) {
            $newPath = Join-Path $ModsDir $newFileName
            if (Test-Path -LiteralPath $newPath) {
                Write-Host "  [SKIP] $($_.Name) -> target exists" -ForegroundColor Yellow
            } else {
                Rename-Item -LiteralPath $_.FullName -NewName $newFileName -Force
                Write-Host "  [RENAME] $($_.Name) -> $newFileName" -ForegroundColor DarkCyan
            }
        }
        
        $localMods += @{
            prefix      = $prefix
            modId       = $modId
            name        = $newFileName
            path        = "mods/$newFileName"
            sha256      = $hash
            file        = (Join-Path $ModsDir $newFileName)
            source      = "github"
            downloadUrl = $null
            isRemote    = $false
        }
        Write-Host "  [LOCAL]  [$prefix] $newFileName" -ForegroundColor Gray
    }
}

# ============================================
# 4. Merge: remote mods + local mods
# ============================================
$currentMods = @($remoteMods) + @($localMods)
Write-Host ""
Write-Host "  Total: $($currentMods.Count) mods (Remote: $($remoteMods.Count), Local: $($localMods.Count))" -ForegroundColor Green

# ============================================
# 5. Build prefix maps and detect changes
# ============================================
$currentPrefixMap = @{}
foreach ($m in $currentMods) { $currentPrefixMap[$m.prefix] = $m }

$allPrefixes = @($oldPrefixMap.Keys) + @($currentPrefixMap.Keys) | Select-Object -Unique

$added      = @()
$updated    = @()
$removed    = @()
$unchanged  = 0

foreach ($pfx in $allPrefixes) {
    $inOld = $oldPrefixMap.ContainsKey($pfx)
    $inNew = $currentPrefixMap.ContainsKey($pfx)
    if ($inNew -and -not $inOld) {
        $added += $currentPrefixMap[$pfx]
    } elseif ($inOld -and -not $inNew) {
        $removed += $oldPrefixMap[$pfx]
    } elseif ($inNew -and $inOld) {
        $newHash = $currentPrefixMap[$pfx].sha256
        $oldHash = $oldPrefixMap[$pfx].sha256
        if ($newHash -ne $oldHash) {
            $updated += $currentPrefixMap[$pfx]
        } else {
            $unchanged++
        }
    }
}

# ============================================
# 6. Generate changelog text
# ============================================
$newVersion = Bump-Version -Version $oldVersion -Bump $VersionBump
$date = Get-Date -Format "yyyy-MM-dd HH:mm"

$cl = New-Object System.Text.StringBuilder
[void]$cl.AppendLine("v$newVersion ($date)")
[void]$cl.AppendLine("")

if ($added.Count -gt 0) {
    [void]$cl.AppendLine("Added ($($added.Count)):")
    foreach ($m in $added) { 
        $srcTag = if ($m.isRemote) { "[$($m.source)]" } else { "[github]" }
        [void]$cl.AppendLine("  + $srcTag $($m.name)") 
    }
    [void]$cl.AppendLine("")
}
if ($updated.Count -gt 0) {
    [void]$cl.AppendLine("Updated ($($updated.Count)):")
    foreach ($m in $updated) { 
        $srcTag = if ($m.isRemote) { "[$($m.source)]" } else { "[github]" }
        [void]$cl.AppendLine("  ^ $srcTag $($m.name)") 
    }
    [void]$cl.AppendLine("")
}
if ($removed.Count -gt 0) {
    [void]$cl.AppendLine("Removed ($($removed.Count)):")
    foreach ($m in $removed) { [void]$cl.AppendLine("  - $($m.name)") }
    [void]$cl.AppendLine("")
}
if ($added.Count -eq 0 -and $updated.Count -eq 0 -and $removed.Count -eq 0) {
    [void]$cl.AppendLine("No changes.")
}

$changelogText = $cl.ToString().TrimEnd()

# ============================================
# 7. Write modpack.json
# ============================================
$files = @()
foreach ($m in $currentMods) {
    $entry = @{
        prefix = $m.prefix
        path   = $m.path
        sha256 = $m.sha256
    }
    # Add source info for remote mods
    if ($m.isRemote) {
        $entry.source      = $m.source
        $entry.downloadUrl = $m.downloadUrl
    }
    $files += $entry
}

$removePrefixes = @()
foreach ($r in $removed) { $removePrefixes += $r.prefix }

$manifest = @{
    version        = $newVersion
    changelog      = $changelogText
    files          = $files
    remove         = $removePrefixes
    sourceStats    = @{
        curseforge = $sourceStats.curseforge
        modrinth   = $sourceStats.modrinth
        github     = $localMods.Count
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($ManifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)

# ============================================
# 8. Append changelog.json
# ============================================
$history = @()
if (Test-Path -LiteralPath $Changelog) {
    try {
        $raw = Get-Content -LiteralPath $Changelog -Raw
        if ($raw.Trim()) {
            $history = @($raw -replace '^\ufeff', '' | ConvertFrom-Json)
        }
    } catch {}
}

$entry = @{
    version   = $newVersion
    date      = $date
    added     = @($added | ForEach-Object { $_.name })
    updated   = @($updated | ForEach-Object { $_.name })
    removed   = @($removed | ForEach-Object { $_.name })
    changelog = $changelogText
}

$history = @($entry) + $history
[System.IO.File]::WriteAllText($Changelog, ($history | ConvertTo-Json -Depth 4), $utf8NoBom)

# ============================================
# 9. Output summary
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Update: v$oldVersion -> v$newVersion" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sources:" -ForegroundColor Green
Write-Host "    CurseForge: $($sourceStats.curseforge)"
Write-Host "    Modrinth:   $($sourceStats.modrinth)"
Write-Host "    GitHub:     $($localMods.Count)"
Write-Host "  ---"
Write-Host "  Added:   $($added.Count)"
Write-Host "  Updated: $($updated.Count)"
Write-Host "  Removed: $($removed.Count)"
Write-Host "  Unchanged: $unchanged"
Write-Host ""
Write-Host $changelogText
Write-Host ""
Write-Host "Files written:" -ForegroundColor Green
Write-Host "  $ManifestPath"
Write-Host "  $Changelog"
Write-Host ""
Write-Host "Next: git add . ; git commit -m 'v$newVersion' ; git push" -ForegroundColor Yellow
Write-Host ""
Write-Host "TIP: Use find_mod_source.ps1 to migrate local mods to remote sources." -ForegroundColor Green
