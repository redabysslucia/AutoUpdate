# ===================================================
#  Modpack Update Generator v2.0
#  Scan mods/ directory, assign unique prefix, embed in filename
# ===================================================
param(
    [string]$VersionBump = "patch"  # major | minor | patch
)

$ErrorActionPreference = "Stop"
$ScriptDir   = $PSScriptRoot
$ModsDir     = Join-Path $ScriptDir "files\mods"
$ManifestPath = Join-Path $ScriptDir "modpack.json"
$Changelog   = Join-Path $ScriptDir "changelog.json"

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

function Get-ModId {
    param([string]$FileName)
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
# 2. Scan current mods directory and rename files
# ============================================
$currentMods = @()
Write-Host ""
Write-Host "=== Scanning mods ===" -ForegroundColor Cyan

Get-ChildItem -LiteralPath $ModsDir -File -Filter "*.jar" | Sort-Object Name | ForEach-Object {
    $existingPrefix = Get-PrefixFromFileName -FileName $_.Name
    $originalName   = if ($existingPrefix) { Get-OriginalName -FileName $_.Name } else { $_.Name }
    $modId          = Get-ModId -FileName $originalName
    $prefix         = if ($existingPrefix) { $existingPrefix } else { Get-Prefix -ModId $modId }
    $newFileName    = "${prefix}_${originalName}"
    $hash           = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()

    if ($_.Name -ne $newFileName) {
        $newPath = Join-Path $ModsDir $newFileName
        if (Test-Path -LiteralPath $newPath) {
            Write-Host "  [SKIP] $($_.Name) -> target exists" -ForegroundColor Yellow
        } else {
            Rename-Item -LiteralPath $_.FullName -NewName $newFileName -Force
            Write-Host "  [RENAME] $($_.Name) -> $newFileName" -ForegroundColor DarkCyan
        }
    }

    $currentMods += @{
        prefix = $prefix
        modId  = $modId
        name   = $newFileName
        path   = "mods/$newFileName"
        sha256 = $hash
        file   = (Join-Path $ModsDir $newFileName)
    }
    Write-Host "  [$prefix] $newFileName" -ForegroundColor Gray
}

Write-Host "  Total: $($currentMods.Count) mods" -ForegroundColor Green

# ============================================
# 3. Build prefix maps and detect changes
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
# 4. Generate changelog text
# ============================================
$newVersion = Bump-Version -Version $oldVersion -Bump $VersionBump
$date = Get-Date -Format "yyyy-MM-dd HH:mm"

$cl = New-Object System.Text.StringBuilder
[void]$cl.AppendLine("v$newVersion ($date)")
[void]$cl.AppendLine("")

if ($added.Count -gt 0) {
    [void]$cl.AppendLine("Added ($($added.Count)):")
    foreach ($m in $added) { [void]$cl.AppendLine("  + $($m.name)") }
    [void]$cl.AppendLine("")
}
if ($updated.Count -gt 0) {
    [void]$cl.AppendLine("Updated ($($updated.Count)):")
    foreach ($m in $updated) { [void]$cl.AppendLine("  ^ $($m.name)") }
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
# 5. Write modpack.json
# ============================================
$files = @()
foreach ($m in $currentMods) {
    $files += @{
        prefix = $m.prefix
        path   = $m.path
        sha256 = $m.sha256
    }
}

$removePrefixes = @()
foreach ($r in $removed) { $removePrefixes += $r.prefix }

$manifest = @{
    version   = $newVersion
    changelog = $changelogText
    files     = $files
    remove    = $removePrefixes
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($ManifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)

# ============================================
# 6. Append changelog.json
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
# 7. Output summary
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Update: v$oldVersion -> v$newVersion" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
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
