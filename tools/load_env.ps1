# Dot-source to read Sable's local config the same way the app does:
# a real environment variable wins, then .env next to the repo/dist root.
#   . (Join-Path $root "tools\load_env.ps1")
#   $url = Get-SableEnv "SABLE_LLM_URL" "http://127.0.0.1:8080"
$script:SableRoot = Split-Path $PSScriptRoot -Parent
$script:SableEnvFile = @{}
$envPath = Join-Path $script:SableRoot ".env"
if (Test-Path $envPath) {
    foreach ($line in Get-Content $envPath) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith("#") -or -not $t.Contains("=")) { continue }
        $i = $t.IndexOf("=")
        $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        $script:SableEnvFile[$t.Substring(0, $i).Trim()] = $v
    }
}

function Get-SableEnv([string]$Key, [string]$Default = "") {
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ($v) { return $v }
    if ($script:SableEnvFile[$Key]) { return $script:SableEnvFile[$Key] }
    return $Default
}
