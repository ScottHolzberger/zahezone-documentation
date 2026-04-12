param(
  [Parameter(Mandatory=$true)][string]$PackStamp
)

$ErrorActionPreference = "Stop"

$TenantHost = "zahe.sharepoint.com"
$SitePath   = "/sites/ZaheZoneOperations"
$Library    = "Copilot-Manifests"

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Sites

Connect-MgGraph -Scopes "Sites.Read.All","Files.Read.All","Sites.ReadWrite.All" -NoWelcome

$site  = Get-MgSite -SiteId "${TenantHost}:${SitePath}"
$drive = Get-MgSiteDrive -SiteId $site.Id | Where-Object { $_.Name -eq $Library }
if (-not $drive) { throw "Document library '$Library' not found" }

function Get-DriveItemByPath([string]$Path) {
  $u = ("https://graph.microsoft.com/v1.0/drives/{0}/root:/{1}" -f $drive.Id, $Path)
  try { return Invoke-MgGraphRequest -Method GET -Uri $u } catch { return $null }
}

function Warm-File([string]$RemotePath) {
  $item = Get-DriveItemByPath -Path $RemotePath
  if ($null -eq $item) { return }
  if ($item.PSObject.Properties.Name -contains "@microsoft.graph.downloadUrl") {
    $dl = $item."@microsoft.graph.downloadUrl"
    if ($dl) { try { Invoke-WebRequest -Uri $dl -Method GET -UseBasicParsing | Out-Null } catch {} }
  }
}

function Invoke-GraphJson([string]$Method,[string]$Uri,$Body) {
  $json = $Body | ConvertTo-Json -Depth 10
  return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $json -ContentType "application/json"
}

function Wait-SearchIndex([string]$QueryString,[string]$MustContain,[int]$MaxAttempts=20,[int]$SleepSeconds=15) {
  $searchUri = "https://graph.microsoft.com/v1.0/search/query"
  for ($i=1; $i -le $MaxAttempts; $i++) {
    $payload = @{ requests = @(@{ entityTypes = @("driveItem"); query = @{ queryString = $QueryString }; from=0; size=25 }) }
    try {
      $resp = Invoke-GraphJson -Method POST -Uri $searchUri -Body $payload
      $hits = $resp.value[0].hitsContainers[0].hits
      foreach ($h in $hits) {
        $webUrl = $h.resource.webUrl
        if ($webUrl -and $webUrl -like "*$MustContain*") { return $true }
      }
    } catch {}
    Start-Sleep -Seconds $SleepSeconds
  }
  return $false
}

$folder = ("ReviewPacks/{0}" -f $PackStamp)
$reviewManifest = ("{0}/REVIEWPACK_MANIFEST.md" -f $folder)

Warm-File $reviewManifest

$must = ("/CopilotManifests/ReviewPacks/{0}/" -f $PackStamp)
$ok = Wait-SearchIndex -QueryString ("REVIEWPACK_MANIFEST {0}" -f $PackStamp) -MustContain $must

if ($ok) {
  Write-Host "[OK] Indexed in search: $reviewManifest"
} else {
  Write-Warning "Not yet searchable. Try again shortly: $reviewManifest"
}
