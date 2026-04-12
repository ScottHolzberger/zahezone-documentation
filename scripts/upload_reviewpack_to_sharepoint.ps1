param(
  [Parameter(Mandatory=$true)][string]$PackRoot,
  [Parameter(Mandatory=$true)][string]$PackStamp,
  [Parameter(Mandatory=$true)][string]$ManifestPath
)

$ErrorActionPreference = "Stop"

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

# Resolve Site + Library Drive
$site  = Get-MgSite -SiteId "${TenantHost}:${SitePath}"
$drive = Get-MgSiteDrive -SiteId $site.Id | Where-Object { $_.Name -eq $Library }
if (-not $drive) { throw "Document library '$Library' not found" }

# ------------------------------
# Helpers: URL encoding + Graph URI builders
# ------------------------------
function Encode-GraphPath([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return "" }
  $clean = $path.Trim('/')
  if ([string]::IsNullOrWhiteSpace($clean)) { return "" }

  $segments = $clean -split '/'
  return ($segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
}

function Get-GraphChildrenUri([string]$driveId, [string]$parentPath) {
  # Root children: /root/children
  # Path children: /root:/{path}:/children
  if ([string]::IsNullOrWhiteSpace($parentPath) -or $parentPath.Trim('/') -eq "") {
    return "https://graph.microsoft.com/v1.0/drives/$driveId/root/children"
  }

  $encoded = Encode-GraphPath $parentPath
  return "https://graph.microsoft.com/v1.0/drives/$driveId/root:/$encoded:/children"
}

function Get-GraphContentUri([string]$driveId, [string]$remotePath) {
  $encoded = Encode-GraphPath $remotePath
  return "https://graph.microsoft.com/v1.0/drives/$driveId/root:/$encoded:/content"
}

# ------------------------------
# Graph actions
# ------------------------------
function Ensure-Folder([string]$parentPath, [string]$folderName) {
  $uri = Get-GraphChildrenUri -driveId $drive.Id -parentPath $parentPath
  $body = @{
    name   = $folderName
    folder = @{}
    "@microsoft.graph.conflictBehavior" = "replace"
  } | ConvertTo-Json -Depth 5

  Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" | Out-Null
}

function Ensure-FolderPath([string]$fullPath) {
  # Ensures every segment exists, starting from root.
  # Example: "ReviewPacks/20260413_083652/runbooks/component"
  $clean = ($fullPath ?? "").Trim('/')
  if ($clean -eq "") { return }

  $parts = $clean -split '/'
  $parent = ""

  foreach ($p in $parts) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    Ensure-Folder $parent $p
    if ($parent -eq "") { $parent = $p } else { $parent = "$parent/$p" }
  }
}

function Upload-File([string]$localPath, [string]$remotePath) {
  if (-not (Test-Path -LiteralPath $localPath)) {
    throw "Local file not found: $localPath"
  }

  # Ensure parent folders exist
  $rp = $remotePath.Trim('/')
  $parent = Split-Path -Path $rp -Parent
  if ($parent -and $parent -ne "." -and $parent -ne "\") {
    # Split-Path can return backslashes on Windows; normalize.
    $parent = ($parent -replace '\\','/').Trim('/')
    if ($parent -ne "") { Ensure-FolderPath $parent }
  }

  $bytes = [System.IO.File]::ReadAllBytes($localPath)
  $uri   = Get-GraphContentUri -driveId $drive.Id -remotePath $remotePath

  Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $bytes -ContentType "application/octet-stream" | Out-Null
}

# ------------------------------
# Validate inputs
# ------------------------------
if (-not (Test-Path -LiteralPath $PackRoot)) {
  throw "PackRoot not found: $PackRoot (this script expects an extracted folder, not the ZIP file)"
}
if (-not (Test-Path -LiteralPath $ManifestPath)) {
  throw "ManifestPath not found: $ManifestPath"
}

# ------------------------------
# Create base folder structure
# ReviewPacks/<PackStamp>/
# ------------------------------
Ensure-FolderPath "ReviewPacks/$PackStamp"

# ------------------------------
# Build REVIEWPACK_MANIFEST.md that the agent can read
# ------------------------------
$reviewPackManifest = Join-Path (Split-Path $ManifestPath -Parent) ("REVIEWPACK_MANIFEST_$PackStamp.md")
$repoUrl = (Select-String -Path $ManifestPath -Pattern '^Repository URL:' -SimpleMatch -ErrorAction SilentlyContinue).Line
$gitHead = (Select-String -Path $ManifestPath -Pattern '^Git HEAD:'        -SimpleMatch -ErrorAction SilentlyContinue).Line

@"
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# SharePoint Review Pack Manifest

Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
Pack: ReviewPacks/$PackStamp
Source Manifest: $(Split-Path $ManifestPath -Leaf)
$repoUrl
$gitHead

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
Upload-File $ManifestPath        "ReviewPacks/$PackStamp/$manifestName"
Upload-File $reviewPackManifest  "ReviewPacks/$PackStamp/REVIEWPACK_MANIFEST.md"

# ------------------------------
# Upload docs-only evidence into ReviewPacks/<stamp>/
# ------------------------------
$readme = Join-Path $PackRoot "README.md"
if (Test-Path -LiteralPath $readme) { Upload-File $readme "ReviewPacks/$PackStamp/README.md" }

$index = Join-Path $PackRoot "INDEX.md"
if (Test-Path -LiteralPath $index) { Upload-File $index "ReviewPacks/$PackStamp/INDEX.md" }

# ------------------------------
# Upload all runbooks (preserve relative structure)
# ------------------------------
$runbooks = Join-Path $PackRoot "runbooks"
if (Test-Path -LiteralPath $runbooks) {
  Get-ChildItem -Path $runbooks -Recurse -Filter "*_runbook.md" | ForEach-Object {
    # Build relative path from PackRoot
    $rel = $_.FullName.Substring($PackRoot.Length).TrimStart('\','/')
    $rel = $rel -replace '\\','/'

    $remote = ("ReviewPacks/$PackStamp/" + $rel).TrimEnd('/')
    Upload-File $_.FullName $remote
  }
}

Write-Host "[OK] Review pack uploaded to SharePoint: ReviewPacks/$PackStamp"
Write-Host "[OK] ReviewPack manifest: ReviewPacks/$PackStamp/REVIEWPACK_MANIFEST.md"
Write-Host "[OK] Source manifest: ReviewPacks/$PackStamp/$manifestName"
