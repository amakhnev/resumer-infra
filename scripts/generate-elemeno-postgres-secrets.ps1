param(
  [string]$TargetFile = "elemeno-dev/secrets/postgres.secrets.sops.yaml",
  [string]$SopsConfig = ".sops.yaml"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command sops -ErrorAction SilentlyContinue)) {
  throw "sops is required but not installed."
}

if (-not (Test-Path -Path $SopsConfig)) {
  throw "Missing SOPS config at $SopsConfig."
}

function New-SecurePassword([int]$bytes = 48) {
  $buffer = New-Object byte[] $bytes
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
  return [Convert]::ToBase64String($buffer).TrimEnd('=').Replace('+', '').Replace('/', '')
}

$appPassword = New-SecurePassword
$rootPassword = New-SecurePassword
$targetDir = Split-Path -Parent $TargetFile

if (-not (Test-Path -Path $targetDir)) {
  New-Item -ItemType Directory -Path $targetDir | Out-Null
}

$tmp = New-TemporaryFile
try {
  @(
    "postgres_app_password: `"$appPassword`""
    "postgres_root_password: `"$rootPassword`""
  ) | Set-Content -Path $tmp.FullName -NoNewline

  sops --config $SopsConfig --filename-override $TargetFile --input-type yaml --output-type yaml -e $tmp.FullName | Set-Content -Path $TargetFile -NoNewline
}
finally {
  Remove-Item -Force $tmp.FullName -ErrorAction SilentlyContinue
}

Write-Host "Generated encrypted Postgres secrets at $TargetFile"
