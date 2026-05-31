# 初始化：运行 generator 然后固定版本为 1.0.0
$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir "generate_update.ps1") -VersionBump "patch"

# 将版本固定为 1.0.0（初始版本）
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$manifest = Get-Content (Join-Path $ScriptDir "modpack.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest.version = "1.0.0"
$manifest.changelog = "Initial release - 147 mods for Minecraft 1.21.1 NeoForge"
[System.IO.File]::WriteAllText((Join-Path $ScriptDir "modpack.json"), ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)

# 清理 changelog.json 只保留初始条目
$changelog = @(@{
    version = "1.0.0"
    date = (Get-Date -Format "yyyy-MM-dd HH:mm")
    added = @("Initial release")
    updated = @()
    removed = @()
    changelog = "Initial release - 147 mods for Minecraft 1.21.1 NeoForge"
})
[System.IO.File]::WriteAllText((Join-Path $ScriptDir "changelog.json"), ($changelog | ConvertTo-Json -Depth 4), $utf8NoBom)

# 清理旧文件
Remove-Item (Join-Path $ScriptDir "modpack_old.json") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $ScriptDir "_init.ps1") -Force

# 输出结果
$m = Get-Content (Join-Path $ScriptDir "modpack.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ""
Write-Host "=== Generated modpack.json ===" -ForegroundColor Green
Write-Host "Version: $($m.version)"
Write-Host "Files: $($m.files.Count)"
Write-Host "Changelog: $($m.changelog)"
Write-Host "Sample prefixes:"
$m.files | Select-Object -First 5 | ForEach-Object { Write-Host "  [$($_.prefix)] $($_.path)" }
Write-Host ""
Write-Host "Initial setup complete!" -ForegroundColor Green
