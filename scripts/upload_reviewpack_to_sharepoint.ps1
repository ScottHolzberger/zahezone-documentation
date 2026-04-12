param(
  [Parameter(Mandatory=$true)][string]$PackRoot,
  [Parameter(Mandatory=$true)][string]$PackStamp,
  [Parameter(Mandatory=$true)][string]$ManifestPath
)

$ErrorActionPreference = "Stop"

$TenantHost = "zahe.sharepoint.com"
$SitePath   = "/sites/ZaheZoneOperations"
$Library    = "Copilot-Manifests"

# Connect (delegated, MFA safe)
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Sites
Connect-MgGraph -Scopes "Sites.ReadWrite.All" -NoWelcome

# Resolve Site + Library Drive
$site  = Get-MgSite -SiteId "${TenantHost}:${SitePath}"
$drive = Get-MgSiteDrive -SiteId $site.Id | Where-Object { $_.Name -eq $Library }
if (-not $drive) { throw "Document library '$Library' not found" }

# Helper: ensure folder exists
function Ensure-Folder($parentPath, $folderName) {
  $uri = "https://graph.microsoft.com/v1.0/drives/$($drive.Id)/root:/$parentPath:/children"
  $body = @{
    name = $folderName
    folder = @{}
    "@microsoft.graph.conflictBehavior" = "replace"
  } | ConvertTo-Json -Depth 5
  Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" | Out-Null
}

# Helper: upload file bytes to a path
function Upload-File($localPath, $remotePath) {
  $bytes = [System.IO.File]::ReadAllBytes($localPath)
  $uri = "https://graph.microsoft.com/v1.0/drives/$($drive.Id)/root:/$remotePath:/content"
  Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $bytes -ContentType "application/octet-stream" | Out-Null
}

# Create folder structure:
# ReviewPacks/<PackStamp>/
Ensure-Folder "" "ReviewPacks"
Ensure-Folder "ReviewPacks" $PackStamp

# Build a REVIEWPACK_MANIFEST.md that the agent can read
$reviewPackManifest = Join-Path (Split-Path $ManifestPath -Parent) ("REVIEWPACK_MANIFEST_$PackStamp.md")
$repoUrl = (Select-String -Path $ManifestPath -Pattern '^Repository URL:' -SimpleMatch -ErrorAction SilentlyContinue).Line
$gitHead = (Select-String -Path $ManifestPath -Pattern '^Git HEAD:' -SimpleMatch -ErrorAction SilentlyContinue).Line

@"
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# SharePoint Review Pack Manifest

Generated: $(Get-Date)
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

# Upload the main manifest and reviewpack manifest
$manifestName = Split-Path $ManifestPath -Leaf
Upload-File $ManifestPath "ReviewPacks/$PackStamp/$manifestName"
Upload-File $reviewPackManifest "ReviewPacks/$PackStamp/REVIEWPACK_MANIFEST.md"

# Upload docs-only evidence into ReviewPacks/<stamp>/
$readme = Join-Path $PackRoot "README.md"
if (Test-Path $readme) { Upload-File $readme "ReviewPacks/$PackStamp/README.md" }

$index = Join-Path $PackRoot "INDEX.md"
if (Test-Path $index) { Upload-File $index "ReviewPacks/$PackStamp/INDEX.md" }

# Upload all runbooks
$runbooks = Join-Path $PackRoot "runbooks"
if (Test-Path $runbooks) {
  Get-ChildItem -Path $runbooks -Recurse -Filter "*_runbook.md" | ForEach-Object {
    $rel = $_.FullName.Substring($PackRoot.Length).TrimStart('\','/')
    $remote = ("ReviewPacks/$PackStamp/" + ($rel -replace '\\','/'))
    Upload-File $_.FullName $remote
  }
}

Write-Host "[OK] Review pack uploaded to SharePoint: ReviewPacks/$PackStamp"
Write-Host "[OK] ReviewPack manifest: ReviewPacks/$PackStamp/REVIEWPACK_MANIFEST.md"