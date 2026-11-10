# Start the Pocket TTS server for Sable (CPU only, localhost).
#   .\serve.ps1                  voices\sable.safetensors if it exists, else SABLE_TTS_VOICE (.env), else azelma
#   .\serve.ps1 -Voice alba      a preset name
#   .\serve.ps1 -Voice C:\path\to\voice.safetensors   (or a .wav clip)
# The port comes from SABLE_TTS_URL (default 8890).
param(
    [string]$Voice = "",
    [int]$Port = 0
)
. (Join-Path $PSScriptRoot "..\tools\load_env.ps1")

if (-not $Voice) {
    $custom = Join-Path $PSScriptRoot "voices\sable.safetensors"
    $Voice = if (Test-Path $custom) { $custom } else { Get-SableEnv "SABLE_TTS_VOICE" "azelma" }
}
if (-not $Port) {
    $url = Get-SableEnv "SABLE_TTS_URL" "http://127.0.0.1:8890"
    $Port = if ($url -match ':(\d+)/?$') { [int]$Matches[1] } else { 8890 }
}
Write-Host "Pocket TTS on http://127.0.0.1:$Port  voice: $Voice"
& (Join-Path $PSScriptRoot ".venv\Scripts\pocket-tts.exe") serve --host 127.0.0.1 --port $Port --default-voice $Voice
