#!/usr/bin/env pwsh
# Stamp Contabo CI secrets onto every valuesRepo enrolled in am-gitops catalog.
# SoT for Argo token: ~/.asrax/credentials.d/argocd-prod.env (or -ArgocdEnvFile).
# Optional GITHUB_PAT: env GITHUB_PAT / GH_TOKEN / AM_GITHUB_PAT with repo access to am-gitops.
# Stored in GitHub as AM_GITHUB_PAT (names starting with GITHUB_ are reserved).
#
# Usage:
#   powershell -File scripts/ci/sync-contabo-ci-secrets.ps1
#   powershell -File scripts/ci/sync-contabo-ci-secrets.ps1 -DryRun
#   powershell -File scripts/ci/sync-contabo-ci-secrets.ps1 -AlsoOrg -OrgVisibility private
#
# Never prints secret values. Requires: gh auth with repo admin on targets (+ admin:org for -AlsoOrg).

[CmdletBinding()]
param(
  [string]$GitopsDir = "",
  [string]$ArgocdEnvFile = "",
  [string]$Org = "AM-Portfolio",
  [switch]$AlsoOrg,
  [ValidateSet("all", "private", "selected")]
  [string]$OrgVisibility = "private",
  [switch]$SkipGithubPat,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-GitopsDir {
  if ($GitopsDir -and (Test-Path $GitopsDir)) { return (Resolve-Path $GitopsDir).Path }
  if ($env:AM_GITOPS_DIR -and (Test-Path $env:AM_GITOPS_DIR)) { return (Resolve-Path $env:AM_GITOPS_DIR).Path }
  $candidates = @(
    (Join-Path (Get-Location) "am-gitops"),
    "f:/am-repos/am-repos/am-gitops",
    (Join-Path $PSScriptRoot "../../../am-gitops")
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c "catalog/services.yaml")) { return (Resolve-Path $c).Path }
  }
  throw "am-gitops not found. Pass -GitopsDir or set AM_GITOPS_DIR."
}

function Load-DotEnv([string]$path) {
  $map = @{}
  Get-Content $path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) { return }
    $i = $line.IndexOf("=")
    if ($i -lt 1) { return }
    $k = $line.Substring(0, $i).Trim()
    $v = $line.Substring($i + 1).Trim().Trim('"').Trim("'")
    $map[$k] = $v
  }
  return $map
}

function Get-EnrolledRepos([string]$gitops) {
  $catalog = Join-Path $gitops "catalog/services.yaml"
  $repos = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  [void]$repos.Add("$Org/am-pipelines")
  [void]$repos.Add("$Org/am-gitops")
  Get-Content $catalog | ForEach-Object {
    if ($_ -match 'valuesRepo:\s*https://github.com/([^/]+)/([^/.]+)') {
      [void]$repos.Add("$($Matches[1])/$($Matches[2])")
    }
  }
  return @($repos | Sort-Object)
}

function Set-RepoSecret([string]$repo, [string]$name, [string]$value) {
  if ($DryRun) {
    Write-Host "DRYRUN gh secret set $name -R $repo (len=$($value.Length))"
    return
  }
  $value | gh secret set $name -R $repo
  if ($LASTEXITCODE -ne 0) { throw "gh secret set $name -R $repo failed (exit $LASTEXITCODE)" }
  Write-Host "OK $repo :: $name"
}

function Set-OrgSecret([string]$name, [string]$value) {
  if ($DryRun) {
    Write-Host "DRYRUN gh secret set $name --org $Org --visibility $OrgVisibility (len=$($value.Length))"
    return
  }
  $value | gh secret set $name --org $Org --visibility $OrgVisibility
  if ($LASTEXITCODE -ne 0) { throw "gh secret set $name --org $Org failed (exit $LASTEXITCODE)" }
  Write-Host "OK org/$Org :: $name (visibility=$OrgVisibility)"
}

$gitops = Resolve-GitopsDir
if (-not $ArgocdEnvFile) {
  $ArgocdEnvFile = Join-Path $env:USERPROFILE ".asrax/credentials.d/argocd-prod.env"
}
if (-not (Test-Path $ArgocdEnvFile)) {
  throw "Missing $ArgocdEnvFile - create Contabo github-ci token env first."
}
$argo = Load-DotEnv $ArgocdEnvFile
$token = $argo["ARGOCD_AUTH_TOKEN"]
$server = $argo["ARGOCD_SERVER"]
if (-not $token -or -not $server) {
  throw "ARGOCD_AUTH_TOKEN / ARGOCD_SERVER required in $ArgocdEnvFile"
}
if ($server -notmatch '^https://') { throw "ARGOCD_SERVER must be https URL (got unexpected value)" }

$ghPat = $null
if (-not $SkipGithubPat) {
  foreach ($k in @("GITHUB_PAT", "GH_TOKEN", "GITHUB_TOKEN")) {
    $v = [Environment]::GetEnvironmentVariable($k)
    if ($v -and $v.Length -gt 20) { $ghPat = $v; break }
  }
}

$repos = Get-EnrolledRepos $gitops
Write-Host "Enrolled repos: $($repos.Count)  gitops=$gitops"
Write-Host "Argo token account=$($argo['ARGOCD_TOKEN_ACCOUNT']) expires=$($argo['ARGOCD_TOKEN_EXPIRES_APPROX'])"

if ($AlsoOrg) {
  try {
    Set-OrgSecret "ARGOCD_AUTH_TOKEN" $token
    Set-OrgSecret "ARGOCD_SERVER" $server
    if ($ghPat) { Set-OrgSecret "AM_GITHUB_PAT" $ghPat }
  } catch {
    Write-Warning "Org secrets skipped (need admin:org): $($_.Exception.Message)"
  }
}

foreach ($repo in $repos) {
  try {
    Set-RepoSecret $repo "ARGOCD_AUTH_TOKEN" $token
    Set-RepoSecret $repo "ARGOCD_SERVER" $server
    # GitHub forbids secret names starting with GITHUB_ — use AM_GITHUB_PAT in workflows.
    if ($ghPat) { Set-RepoSecret $repo "AM_GITHUB_PAT" $ghPat }
  } catch {
    Write-Warning "SKIP $repo : $($_.Exception.Message)"
  }
}

Write-Host "Done. Contabo Approve needs ARGOCD_* (and AM_GITHUB_PAT for prod/dr promote to am-gitops)."
