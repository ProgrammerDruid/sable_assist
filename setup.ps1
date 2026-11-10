# One-time setup for Sable. Works from the dev repo and from a packaged
# dist folder (same layout). Safe to re-run; re-run it after moving the folder.
#
#   .\setup.ps1                 everything: customize (.env), TTS venv, Claude hook, Claude skill
#   .\setup.ps1 -Customize      just re-ask the customization questions (name, server, voice, ...)
#   .\setup.ps1 -Autostart      also start Sable with Windows (packaged build only)
#   .\setup.ps1 -SkipTts        skip the Pocket TTS install (Sable stays silent)
#   .\setup.ps1 -Defaults       don't ask anything; use .env / .env.example values as they are
#   .\setup.ps1 -Uninstall      remove the hook, skill and autostart entry
#
# Requirements: Node.js (Claude hook + vibe check), uv (TTS), and a llama.cpp
# server somewhere on your network. Everything stays local.
param(
    [switch]$Customize,
    [switch]$Autostart,
    [switch]$SkipTts,
    [switch]$Defaults,
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$home_ = $root -replace '\\', '/'
$skillDir = Join-Path $env:USERPROFILE ".claude\skills\sable"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$exe = Join-Path $root "Sable.exe"
$envFile = Join-Path $root ".env"
$envExample = Join-Path $root ".env.example"

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# --- .env helpers ------------------------------------------------------------

function Read-EnvFile($path) {
    $map = [ordered]@{}
    if (Test-Path $path) {
        foreach ($line in Get-Content $path) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith("#") -or -not $t.Contains("=")) { continue }
            $i = $t.IndexOf("=")
            $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        }
    }
    return $map
}

# Rewrites the template (existing .env, else .env.example) with new values,
# keeping its comments. Keys missing from the template are appended.
function Write-EnvFile($values) {
    $template = if (Test-Path $envFile) { $envFile } else { $envExample }
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($line in Get-Content $template) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith("#") -and $t.Contains("=")) {
            $key = $t.Substring(0, $t.IndexOf("=")).Trim()
            if ($values.Contains($key)) { $out.Add("$key=$($values[$key])"); $seen[$key] = $true; continue }
        }
        $out.Add($line)
    }
    foreach ($key in $values.Keys) { if (-not $seen[$key]) { $out.Add("$key=$($values[$key])") } }
    [IO.File]::WriteAllLines($envFile, $out, (New-Object Text.UTF8Encoding($false)))
}

function Ask($prompt, $current) {
    if ($Defaults) { return $current }
    $answer = Read-Host "$prompt [$current]"
    if ($answer.Trim()) { return $answer.Trim() } else { return $current }
}

function Test-Llm($url) {
    try {
        $r = Invoke-WebRequest "$url/health" -TimeoutSec 4 -UseBasicParsing
        return $r.StatusCode -eq 200
    } catch { return $false }
}

# --- uninstall ---------------------------------------------------------------

if ($Uninstall) {
    Step "Removing Claude hook"
    if (Have node) { node (Join-Path $root "claude-hooks\install.mjs") --uninstall }
    Step "Removing Claude skill"
    if (Test-Path $skillDir) { Remove-Item -Recurse -Force $skillDir; Write-Host "removed $skillDir" }
    Step "Removing autostart"
    Remove-ItemProperty -Path $runKey -Name "Sable" -ErrorAction SilentlyContinue
    Write-Host "`nDone. .env, the TTS venv (tts\.venv) and settings (%APPDATA%\Godot\app_userdata\Sable Pet) were left in place."
    exit 0
}

# --- customize ---------------------------------------------------------------

$cfg = Read-EnvFile $envExample
foreach ($kv in (Read-EnvFile $envFile).GetEnumerator()) { $cfg[$kv.Key] = $kv.Value }
if (-not $cfg["SABLE_USER_NAME"]) { $cfg["SABLE_USER_NAME"] = (Get-Culture).TextInfo.ToTitleCase($env:USERNAME) }

if ($Customize -or -not (Test-Path $envFile)) {
    Step "Customize Sable (press Enter to keep the value in brackets)"
    $cfg["SABLE_USER_NAME"] = Ask "What should Sable call you?" $cfg["SABLE_USER_NAME"]
    $cfg["SABLE_LLM_URL"] = (Ask "llama.cpp server URL" $cfg["SABLE_LLM_URL"]).TrimEnd("/")
    if (Test-Llm $cfg["SABLE_LLM_URL"]) {
        Write-Host "  reachable" -ForegroundColor Green
    } else {
        Write-Host "  not answering right now (fine; Sable naps until it's up)" -ForegroundColor Yellow
    }
    $cfg["SABLE_LLM_SLOT"] = Ask "Slot reserved for Sable (-1 = any; use 1 with llama-server -np 2)" $cfg["SABLE_LLM_SLOT"]
    $cfg["SABLE_BRAIN_NAME"] = Ask "What does Sable call the machine her brain runs on?" $cfg["SABLE_BRAIN_NAME"]
    if (-not $SkipTts) {
        Write-Host "  Voices: alba, anna, azelma, cosette, eponine, eve, fantine, jane, marius, mary, paul, vera, ... (see tts\VOICE_RUNBOOK.md)"
        $cfg["SABLE_TTS_VOICE"] = Ask "Voice" $cfg["SABLE_TTS_VOICE"]
    }
    $persona = if ($cfg["SABLE_PERSONA_DIR"]) { $cfg["SABLE_PERSONA_DIR"] } else { "(bundled persona folder)" }
    $persona = Ask "Persona folder with SOUL.md (or a pi-persona agent dir)" $persona
    $cfg["SABLE_PERSONA_DIR"] = if ($persona -eq "(bundled persona folder)") { "" } else { $persona -replace '\\', '/' }
    $search = if ($cfg["SABLE_SEARCH_URL"]) { $cfg["SABLE_SEARCH_URL"] } else { "none" }
    $search = Ask "SearXNG URL so she can search the web in chat (none = no web access)" $search
    $cfg["SABLE_SEARCH_URL"] = if ($search -eq "none") { "" } else { $search.TrimEnd("/") }
    if ($cfg["SABLE_SEARCH_URL"]) {
        try {
            $r = Invoke-RestMethod "$($cfg["SABLE_SEARCH_URL"])/search?q=test&format=json" -TimeoutSec 10
            Write-Host "  JSON API works ($(@($r.results).Count) results)" -ForegroundColor Green
            if (@($r.results).Count -eq 0) {
                Write-Host "  0 results: its default engines may be rate-limited; set SABLE_SEARCH_ENGINES in .env (e.g. bing)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  no JSON answer: enable it in SearXNG settings.yml (search.formats: [html, json])" -ForegroundColor Yellow
        }
    }
    Write-EnvFile $cfg
    Write-Host "Saved $envFile"

    $userMd = Join-Path $root "persona\USER.md"
    if (-not $Defaults -and -not $cfg["SABLE_PERSONA_DIR"] -and -not (Test-Path $userMd)) {
        $yn = Read-Host "Tell Sable a little about yourself? Creates persona\USER.md and opens it (y/N)"
        if ($yn -match '^[Yy]') {
            Copy-Item (Join-Path $root "persona\USER.example.md") $userMd
            Start-Process notepad $userMd
        }
    }
} else {
    Write-Host "`nUsing existing .env (re-run with -Customize to change it)."
}

if ($Customize -and -not ($Autostart)) {
    Write-Host "`nDone. Restart Sable to pick up the changes." -ForegroundColor Green
    exit 0
}

# --- prerequisites and installs ------------------------------------------------

Step "Checking prerequisites"
if (-not (Have node)) { throw "Node.js not found on PATH. Install it (https://nodejs.org) and re-run." }
Write-Host "node $(node --version)"
if (-not $SkipTts -and -not (Have uv)) { throw "uv not found on PATH (needed for TTS). Install uv, or re-run with -SkipTts." }

if (-not $SkipTts) {
    Step "Pocket TTS (CPU) in tts\.venv"
    $venv = Join-Path $root "tts\.venv"
    if (-not (Test-Path (Join-Path $venv "Scripts\pocket-tts.exe"))) {
        uv venv $venv --python 3.12
        $env:VIRTUAL_ENV = $venv
        uv pip install pocket-tts --index-strategy unsafe-best-match --extra-index-url https://download.pytorch.org/whl/cpu
        Remove-Item Env:VIRTUAL_ENV
    } else {
        Write-Host "already installed"
    }
    Write-Host "Warming up (downloads the model on first run)..."
    $voice = if ($cfg["SABLE_TTS_VOICE"]) { $cfg["SABLE_TTS_VOICE"] } else { "azelma" }
    & (Join-Path $venv "Scripts\pocket-tts.exe") generate --voice $voice --text "Hello, $($cfg["SABLE_USER_NAME"])." --output-path (Join-Path $env:TEMP "sable_tts_warmup.wav") | Out-Null
}

Step "Claude Code hook"
node (Join-Path $root "claude-hooks\install.mjs")

Step "Claude Code skill (/sable)"
New-Item -ItemType Directory -Force $skillDir | Out-Null
$skill = [IO.File]::ReadAllText((Join-Path $root "claude-skills\sable\SKILL.md")).Replace("{{SABLE_HOME}}", $home_)
# No BOM: a byte-order mark in front of the --- frontmatter breaks skill parsing.
[IO.File]::WriteAllText((Join-Path $skillDir "SKILL.md"), $skill, (New-Object Text.UTF8Encoding($false)))
Write-Host "installed $skillDir\SKILL.md"

if ($Autostart) {
    Step "Start with Windows"
    if (Test-Path $exe) {
        Set-ItemProperty -Path $runKey -Name "Sable" -Value "`"$exe`""
        Write-Host "Sable will start at login."
    } else {
        Write-Host "No Sable.exe here (dev repo?). Skipped; use run.ps1 in dev."
    }
}

Write-Host "`nAll set. Start Sable with $(if (Test-Path $exe) { 'Sable.exe' } else { '.\run.ps1' })." -ForegroundColor Green
