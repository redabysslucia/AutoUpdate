# ===================================================
#  Mod Source Finder v3.0
#  Jar metadata analysis + auto-match on Modrinth/CurseForge
#  Auto-fills mod_sources.json after successful match
# ===================================================
param(
    [string]$ModName,              # Search by keyword
    [string]$ModFile,              # Path to a specific .jar
    [string]$ScanDir,              # Scan directory
    [string]$GameVersion = "1.21.1",
    [string]$Loader = "neoforge",
    [switch]$NoAutoAdd,            # Disable auto-fill to mod_sources.json
    [switch]$ForceRecheck,         # Re-check already-mapped mods
    [string]$CurseForgeApiKey = "" # Optional CurseForge API key
)

$ErrorActionPreference = "Stop"
$ScriptDir    = $PSScriptRoot
$SourcesFile  = Join-Path $ScriptDir "mod_sources.json"
$ModsDir      = Join-Path $ScriptDir "files\mods"
$TempDir      = Join-Path ([System.IO.Path]::GetTempPath()) "AutoUpdate_Finder"
$Timeout      = 30
$UserAgent    = "AutoUpdate-ModFinder/3.0"

# Ensure temp dir exists
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

# ============================================
# JAR Metadata Reader
# ============================================
function Get-JarModInfo {
    param([string]$JarPath)

    $result = @{
        modId       = ""
        displayName = ""
        version     = ""
        displayURL  = ""
        loader      = "unknown"
        success     = $false
    }

    if (-not (Test-Path -LiteralPath $JarPath)) { return $result }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)

        $foundEntry = $null
        foreach ($entryName in @("META-INF/neoforge.mods.toml", "META-INF/mods.toml", "fabric.mod.json")) {
            $entry = $zip.GetEntry($entryName)
            if ($entry) {
                $foundEntry = $entry
                $result.loader = switch -Wildcard ($entryName) {
                    "*neoforge*" { "neoforge" }
                    "*mods.toml" { "forge" }
                    "fabric.mod.json" { "fabric" }
                    default { "legacy" }
                }
                break
            }
        }

        if (-not $foundEntry) { $zip.Dispose(); return $result }

        $stream = $foundEntry.Open()
        $reader = New-Object System.IO.StreamReader($stream)
        $content = $reader.ReadToEnd()
        $reader.Dispose(); $stream.Dispose(); $zip.Dispose()

        if ($foundEntry.Name -eq "fabric.mod.json") {
            try {
                $json = $content | ConvertFrom-Json
                $result.modId       = $json.id
                $result.displayName = if ($json.name) { $json.name } else { $json.id }
                $result.version     = if ($json.version) { $json.version } else { "" }
                $result.success     = $true
            } catch {}
        } else {
            # Extract from within [[mods]] section (avoid matching loaderVersion etc.)
            # Use regex with singleline to find [[mods]]...version
            if ($content -match 'modId\s*=\s*"([^"]+)"')             { $result.modId = $matches[1] }
            if ($content -match 'displayName\s*=\s*"([^"]+)"')       { $result.displayName = $matches[1] }
            elseif ($content -match "displayName\s*=\s*'([^']+)'")   { $result.displayName = $matches[1] }
            # version must be within [[mods]] block, not loaderVersion
            if ($content -match '(?s)\[\[mods\]\].*?version\s*=\s*"([^"]+)"') { $result.version = $matches[1] }
            if ($content -match 'displayURL\s*=\s*"([^"]+)"')        { $result.displayURL = $matches[1] }
            if ($result.modId) { $result.success = $true }
        }
    } catch {
        Write-Host "    [ERROR] Jar read failed: $_" -ForegroundColor Red
    }
    return $result
}

# ============================================
# Version fuzzy matching helpers
# ============================================
function Get-VersionCore {
    param([string]$VersionStr)
    # Extract the first X.Y.Z pattern, stripping loader/game prefixes/suffixes
    # "0.6.13+mc1.21.1" -> "0.6.13"
    # "mc1.21.1-0.6.13" -> "0.6.13"
    # "1.5.3-neoforge+mc1.21.1" -> "1.5.3"
    # "6.0.10" -> "6.0.10"
    # "19.27.0.340" -> "19.27.0.340"
    if ($VersionStr -match '(\d+\.\d+\.\d+(?:\.\d+)?)') {
        return $matches[1]
    }
    return $VersionStr
}

function Test-VersionMatch {
    param([string]$JarVersion, [string]$PlatformVersion)
    # Exact match first
    if ($JarVersion -eq $PlatformVersion) { return $true }
    # Core version match
    $jarCore = Get-VersionCore -VersionStr $JarVersion
    $platCore = Get-VersionCore -VersionStr $PlatformVersion
    if ($jarCore -and $platCore -and $jarCore -eq $platCore) { return $true }
    # Partial match: one contains the other
    if ($JarVersion -match [regex]::Escape($PlatformVersion)) { return $true }
    if ($PlatformVersion -match [regex]::Escape($JarVersion)) { return $true }
    return $false
}

# ============================================
# Modrinth: find project by modId (slug) or search
# ============================================
function Find-ModrinthProject {
    param([string]$ModId, [string]$DisplayName)

    # Strategy 1: Direct slug lookup (convert underscores to hyphens)
    $slugVariants = @($ModId, ($ModId -replace '_', '-'), ($ModId -replace '-', '_'))
    foreach ($slug in $slugVariants | Select-Object -Unique) {
        try {
            $headers = @{ "User-Agent" = $UserAgent }
            $project = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$slug" -Headers $headers -TimeoutSec $Timeout
            if ($project -and $project.project_type -eq "mod") {
                return @{
                    platform  = "modrinth"
                    projectId = $project.id
                    name      = $project.title
                    slug      = $project.slug
                }
            }
        } catch {
            # 404 or other error, try next variant
        }
    }

    # Strategy 2: Search by displayName (more reliable)
    if ($DisplayName) {
        try {
            $headers = @{ "User-Agent" = $UserAgent }
            $url = "https://api.modrinth.com/v2/search?query=$([Uri]::EscapeDataString($DisplayName))&facets=$([Uri]::EscapeDataString('[["project_type:mod"]]'))&limit=5"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $Timeout
            foreach ($hit in $response.hits) {
                # Check if title or slug matches our modId (fuzzy)
                $hitSlug = $hit.slug -replace '-', '_'
                $ourModId = $ModId -replace '-', '_'
                if ($hit.title -eq $DisplayName -or $hitSlug -eq $ourModId) {
                    return @{
                        platform  = "modrinth"
                        projectId = $hit.project_id
                        name      = $hit.title
                        slug      = $hit.slug
                    }
                }
            }
            # Fallback: return first result if any
            if ($response.hits.Count -gt 0) {
                $best = $response.hits[0]
                return @{
                    platform  = "modrinth"
                    projectId = $best.project_id
                    name      = $best.title
                    slug      = $best.slug
                }
            }
        } catch {}
    }

    # Strategy 3: Search by modId
    try {
        $headers = @{ "User-Agent" = $UserAgent }
        $url = "https://api.modrinth.com/v2/search?query=$([Uri]::EscapeDataString($ModId))&facets=$([Uri]::EscapeDataString('[["project_type:mod"]]'))&limit=5"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $Timeout
        if ($response.hits.Count -gt 0) {
            $best = $response.hits[0]
            return @{
                platform  = "modrinth"
                projectId = $best.project_id
                name      = $best.title
                slug      = $best.slug
            }
        }
    } catch {}

    return $null
}

# ============================================
# Modrinth: find matching version
# ============================================
function Find-ModrinthVersion {
    param([string]$ProjectId, [string]$JarVersion, [string]$GameVersion, [string]$Loader)

    try {
        $loaders = '["' + $Loader + '"]'
        $versions = '["' + $GameVersion + '"]'
        $headers = @{ "User-Agent" = $UserAgent }
        $url = "https://api.modrinth.com/v2/project/$ProjectId/version?loaders=$([Uri]::EscapeDataString($loaders))&game_versions=$([Uri]::EscapeDataString($versions))"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $Timeout

        # Try exact version match first, then fuzzy
        foreach ($ver in $response) {
            if (Test-VersionMatch -JarVersion $JarVersion -PlatformVersion $ver.version_number) {
                $primaryFile = $ver.files | Where-Object { $_.primary } | Select-Object -First 1
                if (-not $primaryFile) { $primaryFile = $ver.files[0] }
                if ($primaryFile) {
                    return @{
                        versionId    = $ver.id
                        versionNum   = $ver.version_number
                        fileName     = $primaryFile.filename
                        downloadUrl  = $primaryFile.url
                        sha1         = $primaryFile.hashes.sha1
                        sha512       = $primaryFile.hashes.sha512
                    }
                }
            }
        }
    } catch {}
    return $null
}

# ============================================
# CurseForge: find project and version (requires API key)
# ============================================
function Find-CurseForgeMatch {
    param([string]$ModId, [string]$DisplayName, [string]$JarVersion, [string]$ApiKey)

    if (-not $ApiKey) { return $null }

    try {
        $headers = @{ "x-api-key" = $ApiKey; "Accept" = "application/json" }
        $url = "https://api.curseforge.com/v1/mods/search?gameId=432&classId=6&searchFilter=$([Uri]::EscapeDataString($ModId))&pageSize=5"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $Timeout

        foreach ($mod in $response.data) {
            if ($mod.slug -eq $ModId -or $mod.name -eq $DisplayName -or $mod.slug -eq ($ModId -replace '_','-')) {
                # Get files for this mod
                $loaderType = if ($Loader -eq 'neoforge') { 6 } else { 1 }
                $filesUrl = "https://api.curseforge.com/v1/mods/$($mod.id)/files?gameVersion=$GameVersion&modLoaderType=$loaderType&pageSize=20"
                $filesResponse = Invoke-RestMethod -Uri $filesUrl -Headers $headers -TimeoutSec $Timeout

                foreach ($file in $filesResponse.data) {
                    $cfVersion = $file.displayName
                    if (Test-VersionMatch -JarVersion $JarVersion -PlatformVersion $cfVersion) {
                        return @{
                            platform    = "curseforge"
                            projectId   = $mod.id.ToString()
                            projectName = $mod.name
                            fileId      = $file.id.ToString()
                            fileName    = $file.fileName
                            downloadUrl = $file.downloadUrl
                            versionNum  = $file.displayName
                        }
                    }
                }
            }
        }
    } catch {}
    return $null
}

# ============================================
# Read / Write mod_sources.json
# ============================================
function Read-SourceMapping {
    $mapping = @{}
    if (Test-Path -LiteralPath $SourcesFile) {
        try {
            $raw = Get-Content -LiteralPath $SourcesFile -Raw
            if ($raw.Trim()) {
                $data = $raw -replace '^\ufeff', '' | ConvertFrom-Json
                if ($data.mappings) {
                    foreach ($key in $data.mappings.PSObject.Properties.Name) {
                        $mapping[$key] = @{}
                        $props = $data.mappings.$key
                        foreach ($p in $props.PSObject.Properties) {
                            $mapping[$key][$p.Name] = $p.Value
                        }
                    }
                }
            }
        } catch {}
    }
    return $mapping
}

function Write-SourceMapping {
    param([hashtable]$Mapping)

    # Read existing file structure (to preserve comments and formatting)
    $ordered = [ordered]@{}
    if (Test-Path -LiteralPath $SourcesFile) {
        try {
            $raw = Get-Content -LiteralPath $SourcesFile -Raw
            if ($raw.Trim()) {
                $data = $raw -replace '^\ufeff', '' | ConvertFrom-Json
                # Preserve top-level keys
                foreach ($prop in $data.PSObject.Properties) {
                    if ($prop.Name -eq "mappings") { continue }
                    $ordered[$prop.Name] = $prop.Value
                }
            }
        } catch {}
    }

    # Update mappings
    $ordered["mappings"] = $Mapping

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $json = $ordered | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($SourcesFile, $json, $utf8NoBom)
}

function Add-SourceMapping {
    param(
        [string]$Prefix,
        [string]$Source,       # "curseforge" or "modrinth"
        [string]$DownloadUrl,
        [string]$Sha256,
        [string]$FileName,
        [string]$ProjectName,
        [string]$ProjectId
    )

    $mapping = Read-SourceMapping

    $mapping[$Prefix] = @{
        source      = $Source
        downloadUrl = $DownloadUrl
        sha256      = $Sha256
        fileName    = $FileName
        projectName = $ProjectName
        projectId   = $ProjectId
    }

    Write-SourceMapping -Mapping $mapping

    Write-Host ""
    Write-Host "  [AUTO-ADDED] Prefix='$Prefix' -> $Source" -ForegroundColor Green
    Write-Host "    URL:  $DownloadUrl" -ForegroundColor Gray
    Write-Host "    File: $FileName" -ForegroundColor Gray
    Write-Host "    SHA256: $Sha256" -ForegroundColor Gray
}

# ============================================
# Download file to compute SHA256
# ============================================
function Get-Sha256FromUrl {
    param([string]$DownloadUrl, [string]$ExpectedFileName)

    $tempFile = Join-Path $TempDir $ExpectedFileName

    # Skip download if already cached
    if (Test-Path $tempFile) {
        try {
            $hash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLower()
            Write-Host "    (Using cached hash from: $tempFile)" -ForegroundColor DarkGray
            return $hash
        } catch {}
    }

    Write-Host "    Downloading to compute SHA256..." -ForegroundColor DarkYellow
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", $UserAgent)
        $webClient.DownloadFile($DownloadUrl, $tempFile)
        $webClient.Dispose()

        $hash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLower()
        Write-Host "    SHA256: $hash" -ForegroundColor DarkGray
        return $hash
    } catch {
        Write-Host "    Download failed: $_" -ForegroundColor Red
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return ""
    }
}

# ============================================
# Main auto-match engine
# ============================================
function AutoMatch-Mod {
    param(
        [string]$JarPath,
        [string]$Prefix,
        [string]$GameVersion,
        [string]$Loader
    )

    $info = Get-JarModInfo -JarPath $JarPath
    if (-not $info.success) {
        Write-Host "  [SKIP] No metadata found in jar" -ForegroundColor DarkYellow
        return $false
    }

    Write-Host "  modId: $($info.modId) | v$($info.version) | $($info.displayName)" -ForegroundColor Gray

    # --- Try Modrinth first (free, fast) ---
    Write-Host "  Searching Modrinth..." -ForegroundColor DarkCyan
    $mrProject = Find-ModrinthProject -ModId $info.modId -DisplayName $info.displayName

    if ($mrProject) {
        Write-Host "    Found: $($mrProject.name) (slug=$($mrProject.slug))" -ForegroundColor Cyan
        $mrVersion = Find-ModrinthVersion -ProjectId $mrProject.projectId -JarVersion $info.version -GameVersion $GameVersion -Loader $Loader

        if ($mrVersion) {
            Write-Host "    Matched: v$($mrVersion.versionNum) | $($mrVersion.fileName)" -ForegroundColor Green

            # Compute SHA256 by downloading
            $sha256 = Get-Sha256FromUrl -DownloadUrl $mrVersion.downloadUrl -ExpectedFileName $mrVersion.fileName

            if ($sha256) {
                Add-SourceMapping -Prefix $Prefix -Source "modrinth" `
                    -DownloadUrl $mrVersion.downloadUrl -Sha256 $sha256 `
                    -FileName $mrVersion.fileName `
                    -ProjectName $mrProject.name -ProjectId $mrProject.projectId
                return $true
            }
        } else {
            Write-Host "    No matching version for $GameVersion/$Loader" -ForegroundColor DarkYellow
        }
    }

    # --- Try CurseForge (if API key provided) ---
    if ($CurseForgeApiKey) {
        Write-Host "  Searching CurseForge..." -ForegroundColor DarkCyan
        $cfMatch = Find-CurseForgeMatch -ModId $info.modId -DisplayName $info.displayName -JarVersion $info.version -ApiKey $CurseForgeApiKey

        if ($cfMatch) {
            Write-Host "    Found: $($cfMatch.projectName) | $($cfMatch.fileName)" -ForegroundColor Green

            $sha256 = Get-Sha256FromUrl -DownloadUrl $cfMatch.downloadUrl -ExpectedFileName $cfMatch.fileName

            if ($sha256) {
                Add-SourceMapping -Prefix $Prefix -Source "curseforge" `
                    -DownloadUrl $cfMatch.downloadUrl -Sha256 $sha256 `
                    -FileName $cfMatch.fileName `
                    -ProjectName $cfMatch.projectName -ProjectId $cfMatch.projectId
                return $true
            }
        }
    }

    # --- Try CurseForge without API key (public website fallback) ---
    Write-Host "  [INFO] Modrinth: no match. Provide -CurseForgeApiKey to also search CurseForge." -ForegroundColor DarkGray
    return $false
}

# ============================================
# Helper: filename prefix extraction
# ============================================
function Get-PrefixFromFileName {
    param([string]$FileName)
    $name = [System.IO.Path]::GetFileName($FileName)
    if ($name -match '^([0-9a-fA-F]{8})_') { return $matches[1].ToLower() }
    return $null
}

function Get-FileSha256 {
    param([string]$FilePath)
    if (Test-Path -LiteralPath $FilePath) {
        return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLower()
    }
    return ""
}

# ============================================
# Manual search mode (no auto-fill)
# ============================================
function Find-ModSource {
    param([string]$ModName, [string]$ModFile)

    $info = $null
    $prefix = ""
    $localSha256 = ""

    if ($ModFile -and (Test-Path -LiteralPath $ModFile)) {
        $info = Get-JarModInfo -JarPath $ModFile
        $prefix = Get-PrefixFromFileName -FileName (Split-Path $ModFile -Leaf)
        $localSha256 = Get-FileSha256 -FilePath $ModFile
    }

    # Display jar metadata
    if ($info -and $info.success) {
        Write-Host ""
        Write-Host "=== Jar Metadata ===" -ForegroundColor Cyan
        Write-Host "  modId:       $($info.modId)"
        Write-Host "  displayName: $($info.displayName)"
        Write-Host "  version:     $($info.version)"
        Write-Host "  loader:      $($info.loader)"
        if ($info.displayURL) { Write-Host "  homepage:    $($info.displayURL)" }
        if ($localSha256)   { Write-Host "  SHA256:      $localSha256" }
        if ($prefix)        { Write-Host "  Prefix:      $prefix" }
    }

    # Search APIs
    $query = if ($ModName) { $ModName } elseif ($info.success) { $info.modId } else { "" }
    if (-not $query) { Write-Host "No search query."; return }

    Write-Host ""
    Write-Host "=== Searching: '$query' ===" -ForegroundColor Magenta

    # Modrinth search
    Write-Host "--- Modrinth ---" -ForegroundColor Green
    try {
        $headers = @{ "User-Agent" = $UserAgent }
        $url = "https://api.modrinth.com/v2/search?query=$([Uri]::EscapeDataString($query))&facets=$([Uri]::EscapeDataString('[["project_type:mod"]]'))&limit=5"
        $mrResults = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $Timeout
        if ($mrResults.hits.Count -eq 0) {
            Write-Host "  No results." -ForegroundColor DarkGray
        } else {
            for ($i = 0; $i -lt $mrResults.hits.Count; $i++) {
                $r = $mrResults.hits[$i]
                Write-Host "  [$($i+1)] $($r.title) | slug=$($r.slug)" -ForegroundColor White
                $desc = if ($r.description.Length -gt 80) { $r.description.Substring(0, 80) + "..." } else { $r.description }
                Write-Host "       $desc" -ForegroundColor Gray

                # Fetch versions
                try {
                    $vUrl = "https://api.modrinth.com/v2/project/$($r.project_id)/version?loaders=$([Uri]::EscapeDataString('["' + $Loader + '"]'))&game_versions=$([Uri]::EscapeDataString('["' + $GameVersion + '"]'))"
                    $versions = Invoke-RestMethod -Uri $vUrl -Headers $headers -TimeoutSec 15
                    if ($versions.Count -gt 0) {
                        Write-Host "       Versions ($($versions.Count)):" -ForegroundColor Magenta
                        foreach ($v in $versions) {
                            $marker = if ($v.files[0].primary) { " [PRIMARY]" } else { "" }
                            Write-Host "         v$($v.version_number) | $($v.files[0].filename)$marker" -ForegroundColor DarkCyan
                            Write-Host "           DL: $($v.files[0].url)" -ForegroundColor DarkGray
                            if ($v.files.Count -gt 1) { break } # Only show one file per version
                        }
                    }
                } catch {}
            }
        }
    } catch {
        Write-Host "  API error: $_" -ForegroundColor DarkRed
    }

    # CurseForge if key provided
    if ($CurseForgeApiKey) {
        Write-Host "--- CurseForge ---" -ForegroundColor Yellow
        try {
            $cfHeaders = @{ "x-api-key" = $CurseForgeApiKey; "Accept" = "application/json" }
            $cfUrl = "https://api.curseforge.com/v1/mods/search?gameId=432&classId=6&searchFilter=$([Uri]::EscapeDataString($query))&pageSize=5"
            $cfResults = Invoke-RestMethod -Uri $cfUrl -Headers $cfHeaders -TimeoutSec $Timeout
            if ($cfResults.data.Count -eq 0) {
                Write-Host "  No results." -ForegroundColor DarkGray
            } else {
                foreach ($mod in $cfResults.data) {
                    Write-Host "  $($mod.name) (slug=$($mod.slug), id=$($mod.id))" -ForegroundColor White
                }
            }
        } catch {
            Write-Host "  API error: $_" -ForegroundColor DarkRed
        }
    }
}

# ============================================
# Scan mode with auto-match
# ============================================
function Scan-AndAutoMatch {
    param([string]$ModsDir, [string]$GameVersion, [string]$Loader)

    $existingMapping = Read-SourceMapping

    if (-not (Test-Path -LiteralPath $ModsDir)) {
        Write-Host "[ERROR] Mods directory not found: $ModsDir" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Auto-Match Mode: Scan + Auto-Fill" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Game: $GameVersion | Loader: $Loader" -ForegroundColor Gray
    if ($NoAutoAdd) { Write-Host "  (Auto-fill DISABLED - dry run)" -ForegroundColor Yellow }
    Write-Host ""

    $unmapped = @()
    $alreadyMapped = 0
    $matched = 0
    $failed = 0

    # Collect unmapped mods
    Get-ChildItem -LiteralPath $ModsDir -File -Filter "*.jar" | Sort-Object Name | ForEach-Object {
        $pfx = Get-PrefixFromFileName -FileName $_.Name
        if (-not $pfx) { return }
        if ($existingMapping.ContainsKey($pfx) -and -not $ForceRecheck) {
            $alreadyMapped++
            return
        }
        $unmapped += @{ prefix = $pfx; fileName = $_.Name; fullPath = $_.FullName }
    }

    Write-Host "  Mapped: $alreadyMapped | Unmapped: $($unmapped.Count)" -ForegroundColor Gray
    if ($unmapped.Count -eq 0) {
        Write-Host "  All mods already mapped! Use -ForceRecheck to re-scan." -ForegroundColor Green
        return
    }
    Write-Host ""

    # Process each unmapped mod
    $idx = 0
    foreach ($m in $unmapped) {
        $idx++
        Write-Host "[$idx/$($unmapped.Count)] $($m.fileName)" -ForegroundColor Yellow

        if (-not $NoAutoAdd) {
            $result = AutoMatch-Mod -JarPath $m.fullPath -Prefix $m.prefix -GameVersion $GameVersion -Loader $Loader
            if ($result) { $matched++ } else { $failed++ }
        } else {
            # Dry run: just show metadata
            $info = Get-JarModInfo -JarPath $m.fullPath
            if ($info.success) {
                Write-Host "  modId: $($info.modId) | $($info.displayName) | v$($info.version)" -ForegroundColor Gray
            } else {
                Write-Host "  (no metadata)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }

    # Summary
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Scan Complete" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Matched + Auto-added: $matched" -ForegroundColor Green
    Write-Host "  Failed / No match:    $failed" -ForegroundColor Yellow
    Write-Host "  Already mapped:       $alreadyMapped" -ForegroundColor Gray
    Write-Host ""
    if (-not $NoAutoAdd -and $matched -gt 0) {
        Write-Host "  Next: run 'update' to regenerate modpack.json" -ForegroundColor Green
    }
    if ($failed -gt 0) {
        Write-Host "  Tip: Use 'find_mod <keyword>' to search manually for failed mods" -ForegroundColor Yellow
    }
}

# ============================================
# Single file auto-match
# ============================================
function AutoMatch-File {
    param([string]$ModFile, [string]$GameVersion, [string]$Loader)

    if (-not (Test-Path -LiteralPath $ModFile)) {
        Write-Host "[ERROR] File not found: $ModFile" -ForegroundColor Red
        return
    }

    $fileName = Split-Path $ModFile -Leaf
    $prefix = Get-PrefixFromFileName -FileName $fileName
    if (-not $prefix) {
        Write-Host "[ERROR] File has no prefix: $fileName" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "=== Auto-Match: $fileName ===" -ForegroundColor Cyan

    if (-not $NoAutoAdd) {
        $result = AutoMatch-Mod -JarPath $ModFile -Prefix $prefix -GameVersion $GameVersion -Loader $Loader
        if (-not $result) {
            Write-Host "  No match found. Try manual search:" -ForegroundColor Yellow
            Write-Host "    .\find_mod_source.ps1 -ModFile '$ModFile'" -ForegroundColor Gray
        }
    } else {
        $info = Get-JarModInfo -JarPath $ModFile
        if ($info.success) {
            Write-Host "  modId: $($info.modId) | $($info.displayName) | v$($info.version)" -ForegroundColor Green
        } else {
            Write-Host "  (no metadata found)" -ForegroundColor DarkYellow
        }
    }
}

# ============================================
# Entry Point
# ============================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Mod Source Finder v3.0 (Auto-Match)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($ScanDir) {
    Scan-AndAutoMatch -ModsDir $ScanDir -GameVersion $GameVersion -Loader $Loader
} elseif ($ModFile) {
    AutoMatch-File -ModFile $ModFile -GameVersion $GameVersion -Loader $Loader
} elseif ($ModName) {
    # Keyword-only search: manual mode, no auto-fill
    Find-ModSource -ModName $ModName
} elseif (Test-Path -LiteralPath $ModsDir) {
    # Default: scan and auto-match
    Scan-AndAutoMatch -ModsDir $ModsDir -GameVersion $GameVersion -Loader $Loader
} else {
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  Auto-match all unmapped mods:" -ForegroundColor Gray
    Write-Host "    find_sources.bat" -ForegroundColor White
    Write-Host ""
    Write-Host "  Auto-match a specific jar:" -ForegroundColor Gray
    Write-Host "    find_mod_source.ps1 -ModFile 'files\mods\76ea0beb_create.jar'" -ForegroundColor White
    Write-Host ""
    Write-Host "  Manual search by keyword (no auto-fill):" -ForegroundColor Gray
    Write-Host "    find_mod.bat create" -ForegroundColor White
    Write-Host ""
    Write-Host "  Dry run (no write):" -ForegroundColor Gray
    Write-Host "    find_mod_source.ps1 -NoAutoAdd" -ForegroundColor White
    Write-Host ""
    Write-Host "  With CurseForge:" -ForegroundColor Gray
    Write-Host "    find_mod_source.ps1 -CurseForgeApiKey 'YOUR_KEY'" -ForegroundColor White
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
