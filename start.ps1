param()

$envFile = 'config.env'
$proxyPort = 8080
$proxyBin = '.\mcp-auth-proxy.exe'
$releaseUrl = 'https://github.com/sigbit/mcp-auth-proxy/releases/latest'

$g = "$([char]0x1b)[32m"
$r = "$([char]0x1b)[31m"
$x = "$([char]0x1b)[0m"

function bail($msg) {
    Write-Host "`n${r}ERROR${x}: $msg"
    exit 1
}

if ($null -eq (Get-Command ngrok -ErrorAction SilentlyContinue)) {
    bail 'ngrok not found. Install from https://ngrok.com/download'
}

if (-not (Test-Path $proxyBin)) {
    Write-Host @"
`n${r}ERROR${x}: $proxyBin not found.
  Download: $releaseUrl
  File: mcp-auth-proxy-windows-amd64.exe
  Rename to: mcp-auth-proxy.exe and place in project root.
"@
    exit 1
}

if (-not (Test-Path $envFile)) { bail "$envFile not found" }

$envVars = @{}
try {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line.Split('=', 2)
            if ($parts.Count -eq 2) {
                $envVars[$parts[0].Trim()] = $parts[1].Trim()
            } else { bail "Invalid line in $envFile (missing '='): $line" }
        }
    }
} catch { bail "Failed to read $envFile`: $($_.Exception.Message)" }

$required = @('NGROK_URL', 'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'ALLOWED_EMAIL', 'FILESYSTEM_PATH')
foreach ($k in $required) {
    if (-not $envVars.ContainsKey($k)) { bail "Missing $k in $envFile" }
    if ([string]::IsNullOrWhiteSpace($envVars[$k])) { bail "$k in $envFile is empty" }
}

$fsPath = $envVars['FILESYSTEM_PATH']
if (-not (Test-Path $fsPath)) { bail "FILESYSTEM_PATH does not exist: $fsPath" }

try { $ngrokDomain = (New-Object System.Uri $envVars['NGROK_URL']).Host }
catch { bail "NGROK_URL is not a valid URL: $($envVars['NGROK_URL'])" }

Write-Host 'Starting mcp-auth-proxy...'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $proxyBin
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
    $proxy = New-Object System.Diagnostics.Process
    $proxy.StartInfo = $psi
    $proxy.Start() | Out-Null
    $proxy.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null) | Out-Null
    $proxy.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null) | Out-Null
} catch { bail "Failed to start proxy: $($_.Exception.Message)" }

Start-Sleep -Seconds 1
$ready = $false
for ($i = 0; $i -lt 15; $i++) {
    if ($proxy.HasExited) { bail "proxy stopped early (exit code: $($proxy.ExitCode))" }
    try {
        $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$proxyPort/")
        $req.Timeout = 2000
        $req.GetResponse().Close()
        $ready = $true
        break
    } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) { bail 'proxy did not start in time' }

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
