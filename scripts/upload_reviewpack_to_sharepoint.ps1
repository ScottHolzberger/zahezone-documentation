param(
  [Parameter(Mandatory = $true)]
  [string]$PackRoot,

  [Parameter(Mandatory = $true)]
  [string]$PackStamp,

  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,

  [switch]$AlsoUpdateLatest
)

$ErrorActionPreference = "Stop"

# ------------------------------
# Guardrails
# ------------------------------
if ([string]::IsNullOrWhiteSpace($PackRoot))     { throw "PackRoot is required and must not be empty" }
if ([string]::IsNullOrWhiteSpace($PackStamp))    { throw "PackStamp is required and must not be empty" }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { throw "ManifestPath is required and must not be empty" }

if (-not (Test-Path -LiteralPath $PackRoot)) {
  throw "PackRoot not found: $PackRoot (expected extracted review pack folder)"
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
  throw "ManifestPath not found: $ManifestPath"
}

# ------------------------------
# SharePoint target
# ------------------------------
$TenantHost = "zahe.sharepoint.com"
$SitePath   = "/sites/ZaheZoneOperations"
$Library    = "Copilot-Manifests"

# ------------------------------
# Graph connect (delegated, MFA safe)
# ------------------------------
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Sites           -ErrorAction Stop

Connect-MgGraph -Scopes "Sites.ReadWrite.All" -NoWelcome

$site = Get-MgSite -SiteId "${TenantHost}:${SitePath}"
if (-not $site) { throw "Unable to resolve SharePoint site ${TenantHost}:${SitePath}" }

$drive = Get-MgSiteDrive -SiteId $site.Id | Where-Object { $_.Name -eq $Library }
if (-not $drive) { throw "Document library '$Library' not found" }

# ------------------------------
# Helper functions
# ------------------------------
function Encode-GraphPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return "" }
  ($path.Trim('/') -split '/') |
    ForEach-Object { [Uri]::EscapeDataString($_) } |
    Join-String '/'
}

function Get-GraphChildrenUri($driveId, $parentPath) {
  if ([string]::IsNullOrWhiteSpace($parentPath)) {
    return "https://graph.microsoft.com/v1.0/drives/$driveId/root/children"
  }
  $encoded = Encode-GraphPath $parentPath
  return "https://graph.microsoft.com/v1.0/drives/$driveId/root:/${encoded}:/children"
}

function Get-GraphContentUri($driveId, $remotePath) {
  $encoded = Encode-GraphPath $remotePath
  return "https://graph.microsoft.com/v1.0/drives/$driveId/root:/${encoded}:/content"
}

function Ensure-Folder($parentPath, $folderName) {
  $uri = Get-GraphChildrenUri $drive.Id $parentPath
  $body = @{
    name   = $folderName
    folder = @{}
    "@microsoft.graph.conflictBehavior" = "replace"
  } | ConvertTo-Json -Depth 5

  Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" | Out-Null
}

function Ensure-FolderPath($fullPath) {
  $clean = ($fullPath ?? "").Trim('/')
  if ($clean -eq "") { return }

  $parts  = $clean -split '/'
  $parent = ""

  foreach ($p in $parts) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    Ensure-Folder $parent $p
    $parent = if ($parent) { "$parent/$p" } else { $p }
  }
}

function Upload-File($localPath, $remotePath) {
  if (-not (Test-Path -LiteralPath $localPath)) {
    throw "Local file not found: $localPath"
  }

  $parent = (Split-Path $remotePath -Parent) -replace '\\','/'
  if ($parent -and $parent -ne ".") {
    Ensure-FolderPath $parent.Trim('/')
  }

  $bytes = [IO.File]::ReadAllBytes($localPath)
  $uri   = Get-GraphContentUri $drive.Id $remotePath

  Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $bytes -ContentType "application/octet-stream" | Out-Null
}

# ------------------------------
# Base folder
# ------------------------------
Ensure-FolderPath "ReviewPacks/$PackStamp"

# ------------------------------
# Build REVIEWPACK_MANIFEST.md
# ------------------------------
$reviewPackManifest = Join-Path (Split-Path $ManifestPath -Parent) ("REVIEWPACK_MANIFEST_$PackStamp.md")

$repoUrlLine  = (Select-String -Path $ManifestPath -Pattern '^Repository URL:' -SimpleMatch -ErrorAction SilentlyContinue).Line
$branchLine   = (Select-String -Path $ManifestPath -Pattern '^Git Branch:'    -SimpleMatch -ErrorAction SilentlyContinue).Line
$gitHeadLine  = (Select-String -Path $ManifestPath -Pattern '^Git HEAD:'       -SimpleMatch -ErrorAction SilentlyContinue).Line

@"
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# SharePoint Review Pack Manifest

Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
Pack: ReviewPacks/$PackStamp
Source Manifest: $(Split-Path $ManifestPath -Leaf)
$repoUrlLine
$branchLine
$gitHeadLine

In-scope review files (SharePoint paths):
- ReviewPacks/$PackStamp/README.md (if present)
- ReviewPacks/$PackStamp/INDEX.md (if present)
- ReviewPacks/$PackStamp/runbooks/**/_runbook.md

Instructions:
- Review must be performed against the SharePoint ReviewPack paths above.
- If a file is missing: state "Not documented".
"@ | Set-Content -Path $reviewPackManifest -Encoding UTF8

# ------------------------------
# Upload manifests
# ------------------------------
$manifestName = Split-Path $ManifestPath -Leaf
Upload-File $ManifestPath       "ReviewPacks/$PackStamp/$manifestName"
Upload-File $reviewPackManifest "ReviewPacks/$PackStamp/REVIEWPACK_MANIFEST.md"

# ------------------------------
# Upload README / INDEX (optional)
# ------------------------------
$readme = Join-Path $PackRoot "README.md"
if (Test-Path $readme) { Upload-File $readme "ReviewPacks/$PackStamp/README.md" }

$index = Join-Path $PackRoot "INDEX.md"
if (Test-Path $index) { Upload-File $index "ReviewPacks/$PackStamp/INDEX.md" }

# ------------------------------
# Upload all runbooks
# ------------------------------
$runbooks = Join-Path $PackRoot "runbooks"
if (Test-Path $runbooks) {
  Get-ChildItem $runbooks -Recurse -Filter "*_runbook.md" | ForEach-Object {
    $rel    = $_.FullName.Substring($PackRoot.Length).TrimStart('\','/') -replace '\\','/'
    $remote = "ReviewPacks/$PackStamp/$rel".TrimEnd('/')
    Upload-File $_.FullName $remote
  }
}

Write-Host "[OK] Review pack uploaded to SharePoint"
Write-Host "[OK] Path: ReviewPacks/$PackStamp"
Write-Host "[OK] Manifest: REVIEWPACK_MANIFEST.md"
Write-Host "[OK] Source manifest: $manifestName"