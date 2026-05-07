param(
  [string]$RootDir = ".",
  [ValidateSet("encrypt", "decrypt")]
  [string]$Action = "encrypt",
  [string]$SopsConfig = ".sops.yaml"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command sops -ErrorAction SilentlyContinue)) {
  throw "sops is required but not installed."
}

if (-not (Test-Path -Path $SopsConfig)) {
  throw "Missing SOPS config at $SopsConfig."
}

$files = @()
if ($Action -eq "encrypt") {
  $files = Get-ChildItem -Path $RootDir -Recurse -File |
    Where-Object {
      ($_.Name -eq ".env" -or $_.Name -like ".env.*.local") -and
      -not $_.Name.EndsWith(".enc") -and
      -not $_.Name.EndsWith(".example") -and
      $_.FullName -notmatch "\\node_modules\\" -and
      $_.FullName -notmatch "\\.git\\"
    }

  foreach ($file in $files) {
    $outFile = "$($file.FullName).enc"
    sops --config $SopsConfig --input-type dotenv --output-type dotenv -e $file.FullName | Set-Content -Path $outFile -NoNewline
    Write-Host "Encrypted $($file.FullName) -> $outFile"
  }

  $jsonFiles = Get-ChildItem -Path $RootDir -Recurse -File |
    Where-Object {
      $_.Name -eq "credentials.json" -and
      -not $_.Name.EndsWith(".enc") -and
      -not $_.Name.EndsWith(".example") -and
      $_.FullName -notmatch "\\node_modules\\" -and
      $_.FullName -notmatch "\\.git\\"
    }

  foreach ($file in $jsonFiles) {
    $outFile = "$($file.FullName).enc"
    sops --config $SopsConfig --input-type json --output-type json -e $file.FullName | Set-Content -Path $outFile -NoNewline
    Write-Host "Encrypted $($file.FullName) -> $outFile"
  }

  $files += $jsonFiles
} else {
  $files = Get-ChildItem -Path $RootDir -Recurse -File |
    Where-Object {
      ($_.Name -like ".env.*.local.enc" -or $_.Name -eq ".env.enc") -and
      $_.FullName -notmatch "\\node_modules\\" -and
      $_.FullName -notmatch "\\.git\\"
    }

  foreach ($file in $files) {
    $outFile = $file.FullName.Substring(0, $file.FullName.Length - 4)
    sops --config $SopsConfig --input-type dotenv --output-type dotenv -d $file.FullName | Set-Content -Path $outFile -NoNewline
    Write-Host "Decrypted $($file.FullName) -> $outFile"
  }

  $jsonFiles = Get-ChildItem -Path $RootDir -Recurse -File |
    Where-Object {
      $_.Name -eq "credentials.json.enc" -and
      $_.FullName -notmatch "\\node_modules\\" -and
      $_.FullName -notmatch "\\.git\\"
    }

  foreach ($file in $jsonFiles) {
    $outFile = $file.FullName.Substring(0, $file.FullName.Length - 4)
    sops --config $SopsConfig --input-type json --output-type json -d $file.FullName | Set-Content -Path $outFile -NoNewline
    Write-Host "Decrypted $($file.FullName) -> $outFile"
  }

  $files += $jsonFiles
}

if ($files.Count -eq 0) {
  Write-Host "No matching files found under $RootDir."
}
