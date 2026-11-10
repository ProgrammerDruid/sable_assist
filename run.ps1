# Launch Sable from the dev repo (the packaged build just runs Sable.exe).
#   .\run.ps1                 normal
#   .\run.ps1 -CycleMoods     preview every emotion and intensity level
# Godot comes from -Godot, else GODOT in the environment or .env, else godot on PATH.
# Sable starts the TTS server (tts\serve.ps1) herself when voice is on.
# Launching while she's already running just brings her back into view.
param(
    [switch]$CycleMoods,
    [string]$Godot = ""
)
. (Join-Path $PSScriptRoot "tools\load_env.ps1")
if (-not $Godot) { $Godot = Get-SableEnv "GODOT" }
if (-not $Godot) { $Godot = (Get-Command godot -ErrorAction SilentlyContinue).Source }
if (-not $Godot -or -not (Test-Path $Godot)) {
    throw "Godot 4.7.2 not found. Set GODOT in .env (path to the Godot exe) or pass -Godot."
}

$godotArgs = @('--path', (Join-Path $PSScriptRoot 'godot'))
if ($CycleMoods) { $godotArgs += @('--', '--cycle-moods') }
Start-Process -FilePath $Godot -ArgumentList $godotArgs
