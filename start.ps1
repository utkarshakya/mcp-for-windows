param()

$envFile = 'config.env'
$proxyPort = 8080
$proxyBin = '.\mcp-auth-proxy.exe'

$g = "$([char]0x1b)[32m"; $r = "$([char]0x1b)[31m"; $x = "$([char]0x1b)[0m"

function bail($msg) { Write-Host "`n${r}ERROR${x}: $msg"; exit 1 }

if (-not (Get-Command ngrok -ErrorAction SilentlyContinue)) { bail 'ngrok not found. Install from https://ngrok.com/download' }

if (-not (Test-Path $proxyBin)) {
    Write-Host "`n${r}ERROR${x}: $proxyBin not found."
    Write-Host '  Download: https://github.com/sigbit/mcp-auth-proxy/releases/latest'
    Write-Host '  File: mcp-auth-proxy-windows-amd64.exe'
    Write-Host '  Rename to: mcp-auth-proxy.exe and place in project root.'
    exit 1
}

if (-not (Test-Path $envFile)) { bail "$envFile not found" }

$envVars = @{}
try {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)') { $envVars[$matches[1].Trim()] = $matches[2].Trim() }
    }
} catch { bail "Failed to read $envFile`: $($_.Exception.Message)" }

$required = @('NGROK_URL', 'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'ALLOWED_EMAIL', 'FILESYSTEM_PATH')
foreach ($k in $required) {
    if ([string]::IsNullOrWhiteSpace($envVars[$k])) { bail "Missing or empty $k in $envFile" }
}

$fsPath = $envVars['FILESYSTEM_PATH']
if (-not (Test-Path $fsPath)) { bail "FILESYSTEM_PATH does not exist: $fsPath" }

try { $ngrokDomain = ([System.Uri]$envVars['NGROK_URL']).Host }
catch { bail "NGROK_URL is not a valid URL: $($envVars['NGROK_URL'])" }

Write-Host 'Starting mcp-auth-proxy...'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $PWD.ProviderPath $proxyBin
$psi.WorkingDirectory = $PWD.ProviderPath
$psi.Arguments = @(
    '--external-url', $envVars['NGROK_URL'],
    '--no-auto-tls',
    '--listen', ":$proxyPort",
    '--google-client-id', $envVars['GOOGLE_CLIENT_ID'],
    '--google-client-secret', $envVars['GOOGLE_CLIENT_SECRET'],
    '--google-allowed-users', $envVars['ALLOWED_EMAIL'],
    '--', 'npx', '-y', '@modelcontextprotocol/server-filesystem', $fsPath
) -join ' '
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
Get-ChildItem Env: | ForEach-Object { $psi.EnvironmentVariables[$_.Name] = $_.Value }
foreach ($kv in $envVars.GetEnumerator()) { $psi.EnvironmentVariables[$kv.Key] = $kv.Value }

try {
    $proxy = [System.Diagnostics.Process]::Start($psi)
    $stderrTask = $proxy.StandardError.ReadToEndAsync()
} catch { bail "Failed to start proxy: $($_.Exception.Message)" }

$ready = $false
for ($i = 0; $i -lt 15; $i++) {
    if ($proxy.HasExited) { bail "Proxy stopped early (exit: $($proxy.ExitCode)): $($stderrTask.Result.Trim())" }
    try {
        $null = curl.exe -s -o NUL -w '' "http://127.0.0.1:$proxyPort/" 2>$null
        $ready = $true; break
    } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) {
    $err = if ($proxy.HasExited) { "`nStderr: $($stderrTask.Result.Trim())" } else { '' }
    bail "Proxy did not start in time$err"
}

Write-Host "${g}Proxy ready${x} on port $proxyPort"
Write-Host 'Opening ngrok in a new window...'

try { Start-Process ngrok -ArgumentList "http --url=$ngrokDomain $proxyPort" }
catch { bail "Failed to start ngrok: $($_.Exception.Message)" }

Write-Host "`n${g}Proxy:       http://127.0.0.1:$proxyPort${x}"
Write-Host "${g}Ngrok URL:   $($envVars['NGROK_URL'])${x}"
Write-Host "${g}Exposed dir: $fsPath${x}"
Write-Host "Close ngrok window or press Ctrl+C here to stop.`n"

try { Wait-Process -Id $proxy.Id -ErrorAction Stop }
catch {
    Write-Host "`nShutting down..."
    if (-not $proxy.HasExited) { $proxy.Kill() }
    Write-Host 'Done.'
    exit 0
}

Write-Host 'Proxy exited.'
