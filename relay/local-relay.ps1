# SKYLINK Pay Relay — LOCAL TEST VERSION (same API as relay/worker.js)
# Usage:  powershell -ExecutionPolicy Bypass -File relay\local-relay.ps1
# Listens on http://localhost:8787  — press Ctrl+C to stop.
# Secrets are read from relay\secrets.local.json (never commit / upload this file).

param([int]$Port = 8787)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$secretsPath = Join-Path $PSScriptRoot "secrets.local.json"
if (-not (Test-Path $secretsPath)) { throw "Missing $secretsPath" }
$secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json
$ApiKey = $secrets.ABLINER_API_KEY
$Secret = $secrets.ABLINER_WEBHOOK_SECRET
$AblinerBase = "https://abliner.net/api/v1"

# Must match relay/worker.js and index.html
$Packages = @{ "2h" = 500; "5h" = 1000; "12h" = 1500; "1d" = 2000; "2d" = 3500; "3d" = 5000; "7d" = 10000; "30d" = 25000 }

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(30)

function Get-HmacHex([string]$key, [string]$msg) {
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = [Text.Encoding]::UTF8.GetBytes($key)
  return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($msg)))).Replace("-", "").ToLower()
}

function ConvertTo-TzPhone([string]$p) {
  $c = ($p -replace '[\s\-\+]', '')
  if ($c -match '^255[67]\d{8}$') { return $c }
  if ($c -match '^0([67]\d{8})$') { return "255" + $Matches[1] }
  if ($c -match '^([67]\d{8})$') { return "255" + $Matches[1] }
  return $null
}

function Add-Cors($resp) {
  $resp.AddHeader("Access-Control-Allow-Origin", "*")
  $resp.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  $resp.AddHeader("Access-Control-Allow-Headers", "Content-Type")
  $resp.AddHeader("Cache-Control", "no-store")
}

function Send-Json($ctx, [int]$status, $obj) {
  $resp = $ctx.Response
  Add-Cors $resp
  $resp.StatusCode = $status
  $resp.ContentType = "application/json; charset=utf-8"
  $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 5))
  $resp.OutputStream.Write($bytes, 0, $bytes.Length)
  $resp.Close()
}

function Invoke-Pay($ctx) {
  $reader = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
  try { $in = $reader.ReadToEnd() | ConvertFrom-Json } catch { return Send-Json $ctx 400 @{ ok = $false; code = "invalid_json"; message = "Ombi si sahihi." } }

  $pkg = [string]$in.package
  if (-not $Packages.ContainsKey($pkg)) { return Send-Json $ctx 422 @{ ok = $false; code = "invalid_package"; message = "Kifurushi hakijulikani." } }
  $amount = $Packages[$pkg]

  $phone = ConvertTo-TzPhone ([string]$in.phone)
  if (-not $phone) { return Send-Json $ctx 422 @{ ok = $false; code = "invalid_phone"; message = "Namba ya simu si sahihi." } }

  $shortPhone = if ($phone.StartsWith("255")) { $phone.Substring(3) } else { $phone }
  $suffix = (-join ((65..90) + (48..57) | Get-Random -Count 4 | ForEach-Object {[char]$_}))
  $reference = "S" + $shortPhone + "_" + $suffix
  # Build the JSON string by hand so the signed string == the sent string.
  $body = '{"amount":' + $amount + ',"method":"mobile","currency":"TZS","phone":"' + $phone + '","reference":"' + $reference + '"}'
  $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
  $sig = Get-HmacHex $Secret "$ts.$body"

  $msg = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$AblinerBase/deposits")
  $msg.Headers.TryAddWithoutValidation("Authorization", "Bearer $ApiKey") | Out-Null
  $msg.Headers.TryAddWithoutValidation("Accept", "application/json") | Out-Null
  $msg.Headers.TryAddWithoutValidation("Idempotency-Key", $reference) | Out-Null
  $msg.Headers.TryAddWithoutValidation("x-abliner-timestamp", $ts) | Out-Null
  $msg.Headers.TryAddWithoutValidation("x-abliner-signature", $sig) | Out-Null
  $msg.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, "application/json")

  $res = $client.SendAsync($msg).GetAwaiter().GetResult()
  $raw = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  $data = $null; try { $data = $raw | ConvertFrom-Json } catch {}
  $code = [int]$res.StatusCode

  Write-Host ("[{0}] PAY {1} TZS {2} -> {3} {4}" -f (Get-Date -Format HH:mm:ss), $phone, $amount, $code, $reference)

  if (-not $res.IsSuccessStatusCode) {
    return Send-Json $ctx $code @{
      ok = $false
      code = $(if ($data.code) { $data.code } else { "abliner_error" })
      message = $(if ($data.message) { $data.message } else { "Abliner error ($code)" })
      retryable = [bool]$data.retryable
    }
  }
  $d = if ($data.data) { $data.data } else { $data }
  $status = if ($d.status) { ([string]$d.status).ToLower() } else { "processing" }
  Send-Json $ctx 200 @{ ok = $true; reference = $reference; id = $d.id; status = $status; amount = $amount }
}

function Invoke-Status($ctx) {
  $ref = [string]$ctx.Request.QueryString["ref"]
  if ($ref -notmatch '^(SKYLINK_|S|W)') { return Send-Json $ctx 400 @{ ok = $false; code = "invalid_reference" } }

  $msg = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "$AblinerBase/transactions?limit=100")
  $msg.Headers.TryAddWithoutValidation("Authorization", "Bearer $ApiKey") | Out-Null
  $msg.Headers.TryAddWithoutValidation("Accept", "application/json") | Out-Null
  $res = $client.SendAsync($msg).GetAwaiter().GetResult()
  if (-not $res.IsSuccessStatusCode) { return Send-Json $ctx 502 @{ ok = $false; code = "abliner_unavailable" } }

  $data = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
  $tx = @($data.data) | Where-Object { $_.customer_reference -eq $ref } | Select-Object -First 1
  $status = if ($tx) { ([string]$tx.status).ToLower() } else { "processing" }
  Write-Host ("[{0}] STATUS {1} -> {2}" -f (Get-Date -Format HH:mm:ss), $ref, $status)
  Send-Json $ctx 200 @{ ok = $true; reference = $ref; status = $status }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "SKYLINK Pay Relay (local) listening on http://localhost:$Port  —  Ctrl+C to stop"

try {
  while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.Wait(500)) {}
    $ctx = $task.Result
    try {
      $req = $ctx.Request
      $path = $req.Url.AbsolutePath.TrimEnd('/')
      if ($req.HttpMethod -eq "OPTIONS") {
        Add-Cors $ctx.Response; $ctx.Response.StatusCode = 204; $ctx.Response.Close(); continue
      }
      if ($path -eq "/pay" -and $req.HttpMethod -eq "POST") { Invoke-Pay $ctx }
      elseif ($path -eq "/status" -and $req.HttpMethod -eq "GET") { Invoke-Status $ctx }
      elseif ($path -eq "/health") { Send-Json $ctx 200 @{ ok = $true; service = "skylink-pay-relay-local" } }
      else { Send-Json $ctx 404 @{ ok = $false; code = "not_found" } }
    } catch {
      Write-Host "ERROR: $($_.Exception.Message)"
      try { Send-Json $ctx 500 @{ ok = $false; code = "relay_error"; message = $_.Exception.Message } } catch {}
    }
  }
} finally {
  $listener.Stop()
}
