$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-LatestGhMsiAsset {
  $release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/cli/cli/releases/latest" `
    -Headers @{ "User-Agent" = "codex-gh-installer" }

  if (-not $release.assets) {
    throw "No assets found in latest release payload."
  }

  $asset = $release.assets |
    Where-Object { $_.name -match "windows_amd64\.msi$" } |
    Select-Object -First 1

  if (-not $asset) {
    $names = ($release.assets | ForEach-Object { $_.name }) -join ", "
    throw "Could not find a windows_amd64.msi asset. Assets: $names"
  }

  return $asset
}

function Get-LatestGhZipAsset {
  param(
    [Parameter(Mandatory = $true)]
    $release
  )

  $asset = $release.assets |
    Where-Object { $_.name -match "windows_amd64\.zip$" } |
    Select-Object -First 1

  if (-not $asset) {
    $names = ($release.assets | ForEach-Object { $_.name }) -join ", "
    throw "Could not find a windows_amd64.zip asset. Assets: $names"
  }

  return $asset
}

function Add-ToUserPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$dir
  )

  $dir = $dir.TrimEnd("\")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $parts = $userPath.Split(";") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  }

  if ($parts -contains $dir) { return }

  $newUserPath = if ($parts.Count -eq 0) { $dir } else { ($parts + $dir) -join ";" }
  [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")

  if ($env:PATH -notlike "*$dir*") {
    $env:PATH = $dir + ";" + $env:PATH
  }
}

function Find-GhExePath {
  $cmd = Get-Command gh -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  $candidates = @(
    (Join-Path $env:ProgramFiles "GitHub CLI\gh.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "GitHub CLI\gh.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\gh.exe"),
    (Join-Path $env:LOCALAPPDATA "GitHub CLI\gh.exe")
  )

  foreach ($p in $candidates) {
    if (Test-Path $p) { return $p }
  }

  return $null
}

$release = Invoke-RestMethod `
  -Uri "https://api.github.com/repos/cli/cli/releases/latest" `
  -Headers @{ "User-Agent" = "codex-gh-installer" }

$tmpDir = Join-Path $PSScriptRoot "tmp"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
  $msiAsset = ($release.assets | Where-Object { $_.name -match "windows_amd64\.msi$" } | Select-Object -First 1)
  if ($msiAsset) {
    $msiPath = Join-Path $tmpDir $msiAsset.name
    Write-Host ("Downloading MSI: " + $msiAsset.browser_download_url)
    curl.exe -sS -L --fail --max-time 600 -o $msiPath $msiAsset.browser_download_url

    $sig = Get-AuthenticodeSignature $msiPath
    $sig | Format-List -Property Status, StatusMessage, SignerCertificate
    if ($sig.Status -ne "Valid") {
      throw ("MSI signature not valid: " + $sig.Status)
    }

    Write-Host "Installing GitHub CLI (gh) via MSI..."
    $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
      "/i", $msiPath,
      "MSIINSTALLPERUSER=1",
      "ALLUSERS=2",
      "/qn",
      "/norestart"
    )
    if ($proc.ExitCode -eq 0) {
      Write-Host "MSI install succeeded."
    } else {
      throw ("msiexec failed with exit code: " + $proc.ExitCode)
    }
  } else {
    throw "No MSI asset found."
  }
} catch {
  Write-Warning ("MSI install failed (" + $_.Exception.Message + "). Falling back to portable ZIP install...")

  $zipAsset = Get-LatestGhZipAsset -release $release
  $zipPath = Join-Path $tmpDir $zipAsset.name
  Write-Host ("Downloading ZIP: " + $zipAsset.browser_download_url)
  curl.exe -sS -L --fail --max-time 600 -o $zipPath $zipAsset.browser_download_url

  $installRoot = Join-Path $env:LOCALAPPDATA "Programs\\GitHub CLI"
  New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
  Expand-Archive -Force -Path $zipPath -DestinationPath $installRoot

  $foundGh = Get-ChildItem -Path $installRoot -Recurse -Filter "gh.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $foundGh) {
    throw ("ZIP install completed but gh.exe was not found under: " + $installRoot)
  }

  $ghExe = $foundGh.FullName
  $binDir = Split-Path -Parent $ghExe

  Add-ToUserPath -dir $binDir
  Write-Host ("Installed gh (portable) at: " + $ghExe)
  & $ghExe --version
}

$ghExeFinal = Find-GhExePath
if (-not $ghExeFinal) {
  Write-Warning "gh is installed but not visible to this terminal. Open a new PowerShell window and run: gh --version"
}
