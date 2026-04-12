param(
    [Parameter(Mandatory=$true)]
    [string]$ManifestPath
)

$SiteUrl = "https://zahe.sharepoint.com/sites/ZaheZoneOperations"
$Library = "CopilotManifests"

Import-Module Microsoft.Graph.Files

Connect-MgGraph -Scopes "Sites.ReadWrite.All","Files.ReadWrite.All"

$site = Get-MgSite -SiteId $SiteUrl
$drive = Get-MgSiteDrive -SiteId $site.Id | Where-Object { $_.Name -eq $Library }

if (-not $drive) {
    throw "Document library '$Library' not found"
}

$filename = Split-Path $ManifestPath -Leaf

Write-Host "Uploading $filename to SharePoint/$Library"

Set-MgDriveItemContent `
  -DriveId $drive.Id `
  -ItemPath "/$filename" `
  -InFile $ManifestPath

Write-Host "[OK] Manifest uploaded for Copilot indexing"