param(
    [Parameter(Mandatory=$true)]
    [string]$ManifestPath
)

$TenantHost = "zahe.sharepoint.com"
$SitePath   = "/sites/ZaheZoneOperations"
$Library    = "Copilot-Manifests"

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Sites

# Authenticate (interactive, MFA-safe)
Connect-MgGraph -Scopes "Sites.ReadWrite.All"

# Resolve site
$site = Get-MgSite -SiteId "${TenantHost}:${SitePath}"

if (-not $site) {
    throw "Unable to resolve SharePoint site"
}

# Resolve document library drive
$drive = Get-MgSiteDrive -SiteId $site.Id | Where-Object { $_.Name -eq $Library }

if (-not $drive) {
    throw "Document library '$Library' not found"
}

$filename = Split-Path $ManifestPath -Leaf
$content  = [System.IO.File]::ReadAllBytes($ManifestPath)

$uri = "https://graph.microsoft.com/v1.0/drives/$($drive.Id)/root:/$filename:/content"

Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $content -ContentType "application/octet-stream"

Write-Host "[OK] Manifest uploaded to SharePoint/Copilot-Manifests"