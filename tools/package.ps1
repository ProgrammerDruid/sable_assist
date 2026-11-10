# Build a standalone Sable folder (and zip) in dist\.
#   .\tools\package.ps1                 -> dist\Sable\ and dist\Sable-<version>.zip
#   .\tools\package.ps1 -Version 0.2.0
# Needs the Godot 4.7.2 Windows export templates installed
# (%APPDATA%\Godot\export_templates\4.7.2.stable\). Godot comes from -Godot,
# else GODOT in the environment or .env (the _console.exe next to it is
# preferred so export errors show up here).
# Your .env and persona\USER.md are never packaged; setup.ps1 creates .env.
param(
    [string]$Version = "0.1.0",
    [string]$Godot = ""
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "load_env.ps1")
if (-not $Godot) { $Godot = Get-SableEnv "GODOT" }
if (-not $Godot) { $Godot = (Get-Command godot -ErrorAction SilentlyContinue).Source }
if (-not $Godot -or -not (Test-Path $Godot)) { throw "Godot 4.7.2 not found. Set GODOT in .env or pass -Godot." }
$console = $Godot -replace '(?<!_console)\.exe$', '_console.exe'
if (Test-Path $console) { $Godot = $console }
$dist = Join-Path $repo "dist"
$out = Join-Path $dist "Sable"

Write-Host "== Cleaning $out"
# A running packaged Sable locks Sable.exe; stop it and wait for it to exit.
Get-Process Sable -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$out*" } | ForEach-Object {
    Stop-Process -Id $_.Id -Force
    $_.WaitForExit(5000) | Out-Null
}
# Its helper scripts (idle watcher, taskbar helper) run from the folder too.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$out*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500
# Clear the contents, not the folder: the TTS server Sable started may still
# have it as its working directory, which locks the directory itself.
New-Item -ItemType Directory -Force $out | Out-Null
# Keep a local dist\Sable\.env (your own install) across rebuilds; it is put
# back only after zipping, so it never ships.
$keptEnv = $null
if (Test-Path (Join-Path $out ".env")) { $keptEnv = [IO.File]::ReadAllBytes((Join-Path $out ".env")) }
Get-ChildItem $out -Force | Remove-Item -Recurse -Force

Write-Host "== Exporting Sable.exe (Godot release template, pck embedded)"
& $Godot --headless --path (Join-Path $repo "godot") --export-release "Windows Desktop" (Join-Path $out "Sable.exe") 2>&1 |
    Where-Object { $_ -match "ERROR|error:" } | ForEach-Object { Write-Host $_ -ForegroundColor Red }
if (-not (Test-Path (Join-Path $out "Sable.exe"))) { throw "Export failed: no Sable.exe" }

Write-Host "== Copying support files (same layout as the repo)"
$files = @(
    "setup.ps1", ".env.example", "LICENSE.md",
    "persona\SOUL.md", "persona\USER.example.md",
    "tools\load_env.ps1",
    "brain\pet_rules.md", "brain\chat_rules.md", "brain\diary_rules.md", "brain\sable_take.mjs",
    "claude-hooks\pet-hook.mjs", "claude-hooks\install.mjs",
    "claude-skills\sable\SKILL.md",
    "tts\serve.ps1", "tts\design_voice.py", "tts\VOICE_RUNBOOK.md",
    "tools\hide_from_taskbar.ps1", "tools\idle_watch.ps1"
)
foreach ($f in $files) {
    $dst = Join-Path $out $f
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    Copy-Item (Join-Path $repo $f) $dst
}
# Custom voice and art are user data: copied if present, never required.
$voice = Join-Path $repo "tts\voices\sable.safetensors"
if (Test-Path $voice) { New-Item -ItemType Directory -Force (Join-Path $out "tts\voices") | Out-Null; Copy-Item $voice (Join-Path $out "tts\voices\") }
New-Item -ItemType Directory -Force (Join-Path $out "art\sable") | Out-Null
Set-Content (Join-Path $out "art\sable\PUT_ART_HERE.txt") "Drop pose PNGs here (idle.png, joy.png, sleep.png, ...). They override the drawn cat. See DESIGN.md section 5."
Copy-Item (Join-Path $repo "tools\dist_README.md") (Join-Path $out "README.md")

Write-Host "== Zipping"
$zip = Join-Path $dist "Sable-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $out -DestinationPath $zip
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
if ($keptEnv) { [IO.File]::WriteAllBytes((Join-Path $out ".env"), $keptEnv); Write-Host "Restored your local dist .env (not in the zip)" }
Write-Host "Done: $out  and  $zip ($mb MB)" -ForegroundColor Green
