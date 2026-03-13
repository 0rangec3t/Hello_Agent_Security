$ErrorActionPreference = "Stop"

$repoName = "Hello_Agent_Security"
$gitUserName = "0rangec3t"
$gitUserEmail = "1531915673@qq.com"

function Resolve-Gh {
  $cmd = Get-Command gh -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  $fallback = Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\bin\gh.exe"
  if (Test-Path $fallback) { return $fallback }

  throw "gh not found. Expected at: $fallback"
}

$gh = Resolve-Gh

& $gh auth status -h github.com *> $null
if ($LASTEXITCODE -ne 0) {
  throw "gh is not logged in. Run: `"$gh`" auth login"
}

# Configure identity locally (repo-only) to avoid global/system changes.
git config user.name $gitUserName
git config user.email $gitUserEmail

# Ensure we have at least one commit.
git add -A
git diff --cached --quiet
if ($LASTEXITCODE -eq 1) {
  git commit -m "init"
} else {
  git rev-parse --verify HEAD *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "No changes staged and no existing commits; nothing to push."
  }
}

git branch -M main

function Get-RepoUrl([string]$name) {
  try {
    return (& $gh repo view $name --json url -q .url 2>$null)
  } catch {
    return $null
  }
}

$repoUrl = Get-RepoUrl $repoName

if (-not $repoUrl) {
  try {
    & $gh repo create $repoName --public --source . --remote origin --push -y
    exit 0
  } catch {
    # If it already exists (or creation failed), fall back to view+push.
    $repoUrl = Get-RepoUrl $repoName
  }
}

if (-not $repoUrl) {
  throw "Could not create or locate GitHub repo '$repoName' via gh."
}

$remotes = @(git remote)
if ($remotes -contains "origin") {
  git remote set-url origin $repoUrl
} else {
  git remote add origin $repoUrl
}

git push -u origin main

