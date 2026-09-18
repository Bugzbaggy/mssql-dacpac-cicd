<#
.SYNOPSIS
  Windows/PowerShell-native PolicyGate release-gate client for DB CI/CD pipelines.

.DESCRIPTION
  The shared Jenkins library `example/jenkins-policygate-integration` is implemented entirely
  with the Unix `sh` step plus `curl`/`jq`, so it cannot run on the Windows DB build
  agents (`dev-win-slave1`). This script reproduces the same PolicyGate contract using
  `Invoke-RestMethod`, so the gates work natively on PowerShell agents.

  Phases:
    pre-release  -> POST /gate/release , then POLL until gate resolves -> returns signal
    pre-deploy   -> POST /gate/service , then POLL until gate resolves -> returns signal
    post-deploy  -> POST /gate/service (fire-and-forget notification)
    post-release -> POST /gate/release (fire-and-forget notification)

  Gate behaviour (matches the agreed policy: hard gate on DENY, fail-open on outage):
    - signal == DENY    -> written to the result file; the Jenkinsfile blocks the deploy.
    - PolicyGate unreachable / timeout / non-2xx / missing API key -> signal = UNKNOWN and
      the script still exits 0 so a PolicyGate outage never blocks a DB release.

  The API key is read from the POLICYGATE_API_KEY environment variable and is never echoed.

.OUTPUTS
  Writes a JSON result file (-ResultFile) the Jenkinsfile reads with readJSON:
    { "signal": "...", "status": "...", "rpTicket": "...", "httpStatus": "...", "phase": "..." }
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('pre-release', 'pre-deploy', 'post-deploy', 'post-release')]
  [string]$Phase,

  [Parameter(Mandatory = $true)]
  [string]$Environment,            # production | staging

  [Parameter(Mandatory = $true)]
  [string]$ReleaseId,

  [Parameter(Mandatory = $true)]
  [string]$ServiceName,            # Backstage component name (e.g. AppDb_ANALYTICS)

  [string]$Version       = 'unknown',
  [string]$Ticket        = '',
  [string]$FastTrack     = 'true', # 'true' | 'false'
  [string]$Success       = 'true', # 'true' | 'false' (used by post-* phases)

  # Change context (passed in by the Jenkinsfile so we never depend on `git` on the agent)
  [string]$GitCommit     = 'unknown',
  [string]$GitBranch     = 'unknown',
  [string]$GitRepo       = 'unknown',

  [string]$BuildNumber   = 'unknown',
  [string]$BuildUrl      = 'unknown',
  [string]$JobName       = 'unknown',
  [string]$RequestedBy   = 'jenkins',

  [string]$PolicyGateDomain = 'policygate.example.com',
  [string]$ArtifactType  = 'sql',
  [string]$ArtifactLocation = '',

  [int]$PollSeconds      = 15,
  [int]$TimeoutSeconds   = 1800,

  [string]$ResultFile    = 'policygate_gate_result.json'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---- helpers ---------------------------------------------------------------

function Write-GateResult {
  param([string]$Signal, [string]$Status, [string]$RpTicket = '', [string]$HttpStatus = '')
  $obj = [ordered]@{
    signal     = $Signal
    status     = $Status
    rpTicket   = $RpTicket
    httpStatus = $HttpStatus
    phase      = $Phase
  }
  $json = $obj | ConvertTo-Json -Depth 5
  # BOM-less UTF-8 so Jenkins readJSON can parse the file on Windows (PS 5.1).
  $resolved = Join-Path (Get-Location).Path $ResultFile
  [System.IO.File]::WriteAllText($resolved, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "PolicyGate ${Phase}: signal=$Signal status=$Status$(if($RpTicket){" rpTicket=$RpTicket"})"
}

# Reproduces the library's extractRpTicket: pull RP-#### out of the LLM_AGENT step.
function Get-RpTicket {
  param($GateResult)
  try {
    if (-not $GateResult) { return '' }
    $llmStep = $null
    foreach ($step in @($GateResult.stepResults)) {
      if ($step.action -and $step.action.type -eq 'LLM_AGENT') { $llmStep = $step; break }
    }
    if (-not $llmStep -or -not $llmStep.message) { return '' }

    $msg = ($llmStep.message).Trim() | ConvertFrom-Json
    $rp  = $msg.RP_ticket
    if (-not $rp -and $msg.output) {
      # The LLM_AGENT may wrap its JSON in markdown prose/fences. Instead of
      # matching every possible fence shape, take the object boundaries
      # (first '{' .. last '}') and parse that. Handles fenced, unfenced and
      # prose-wrapped output with nothing to maintain.
      $out = [string]$msg.output
      $a = $out.IndexOf('{'); $b = $out.LastIndexOf('}')
      if ($a -ge 0 -and $b -gt $a) {
        try { $rp = ($out.Substring($a, $b - $a + 1) | ConvertFrom-Json).RP_ticket } catch {}
      }
    }
    # Trust the structured RP_ticket field; only sanity-check it is RP-<number>
    # using a parse (no rigid format regex that breaks if the scheme evolves).
    $rpStr = ([string]$rp).Trim()
    $n = 0
    if ($rpStr.StartsWith('RP-') -and [int]::TryParse($rpStr.Substring(3), [ref]$n)) { return $rpStr }
    return ''
  } catch { return '' }
}

# ---- guards ----------------------------------------------------------------

$allowedDomains = @('policygate.example.com', 'policygate.example.com', 'policygate.staging.cloud.example.com', 'policygate.example.com')
if ($allowedDomains -notcontains $PolicyGateDomain) {
  throw "policygateDomain '$PolicyGateDomain' is not allowed. Must be one of: $($allowedDomains -join ', ')"
}

$apiKey = $env:POLICYGATE_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  Write-Host "WARNING: POLICYGATE_API_KEY not set - skipping PolicyGate $Phase notification (fail-open)"
  Write-GateResult -Signal 'UNKNOWN' -Status 'NO_API_KEY'
  exit 0
}

$fastTrackBool = ($FastTrack -eq 'true')
$successBool   = ($Success   -eq 'true')
# The Jenkinsfile passes a canonical https://github.com/example/<repo> URL, so use
# it as-is (just trim any trailing slash). No SSH/.git normalization needed.
$gitRepoHttps  = $GitRepo.TrimEnd('/')
$nowUtc        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$isReleaseGate = ($Phase -eq 'pre-release' -or $Phase -eq 'post-release')
$endpoint      = if ($isReleaseGate) { "https://$PolicyGateDomain/gate/release" } else { "https://$PolicyGateDomain/gate/service" }
$artLocation   = if ($ArtifactLocation) { $ArtifactLocation } else { $gitRepoHttps }
$headers       = @{ Authorization = "Bearer $apiKey"; 'content-type' = 'application/json' }

# ---- payload ---------------------------------------------------------------

if ($isReleaseGate) {
  $finishedAt = if ($Phase -eq 'post-release') { $nowUtc } else { '' }
  $clusterLabel = (Get-Culture).TextInfo.ToTitleCase($Environment)
  $meta = [ordered]@{
    cluster_label         = $clusterLabel
    cluster_name          = "$Environment-cluster"
    group_label           = $clusterLabel
    group_name            = $ServiceName
    group_release_version = ''
    service_build_number  = $BuildNumber
    service_version       = $Version
  }
  $payload = [ordered]@{
    phase     = $Phase
    releaseId = $ReleaseId
    context   = [ordered]@{
      environment = $Environment
      name        = $ReleaseId
      pipeline    = [ordered]@{
        id          = $ReleaseId
        source      = 'Jenkins'
        sourceUrl   = $BuildUrl
        startedAt   = $nowUtc
        finishedAt  = $finishedAt
        requestedBy = $RequestedBy
        success     = $successBool
      }
      components  = @(
        [ordered]@{
          name     = $ServiceName
          artifact = [ordered]@{ type = $ArtifactType; version = $Version; location = $artLocation }
          git      = [ordered]@{ repository = $gitRepoHttps; commit = $GitCommit; branch = $GitBranch; pr = '' }
          metadata = $meta
        }
      )
      change      = [ordered]@{ ticket = $Ticket; fastTrack = $fastTrackBool }
      metadata    = $meta
    }
  }
}
else {
  # service-gate: pre-deploy sends success=null, post-deploy sends the real value + finishedAt
  $svcSuccess  = if ($Phase -eq 'post-deploy') { $successBool } else { $null }
  $finishedAt  = if ($Phase -eq 'post-deploy') { $nowUtc } else { $null }
  $payload = [ordered]@{
    phase   = $Phase
    context = [ordered]@{
      environment = $Environment
      git         = [ordered]@{ pr = $null; branch = $GitBranch; commit = $GitCommit; repository = $gitRepoHttps }
      change      = [ordered]@{ ticket = $(if ($Ticket) { $Ticket } else { $null }); fastTrack = $fastTrackBool }
      component   = [ordered]@{ name = $ServiceName }
      artifact    = [ordered]@{
        tag = $Version; type = $ArtifactType; chart = $null; image = $null
        package = $null; version = $Version; location = $artLocation
      }
      metadata    = [ordered]@{ serviceName = $ServiceName; buildNumber = $BuildNumber; jobName = $JobName }
      pipeline    = [ordered]@{
        id          = $ReleaseId
        success     = $svcSuccess
        sourceUrl   = $BuildUrl
        startedAt   = $nowUtc
        finishedAt  = $finishedAt
        requestedBy = $RequestedBy
      }
    }
  }
}

$jsonPayload = $payload | ConvertTo-Json -Depth 12

Write-Host "========== PolicyGate Request =========="
Write-Host "URL:   $endpoint"
Write-Host "Phase: $Phase"
Write-Host "Payload:"
Write-Host $jsonPayload
Write-Host "====================================="

# ---- submit ----------------------------------------------------------------

$initial = $null
try {
  $initial = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body $jsonPayload -TimeoutSec 30
}
catch {
  Write-Host "WARNING: PolicyGate $Phase POST failed: $($_.Exception.Message) - continuing (fail-open)"
  Write-GateResult -Signal 'UNKNOWN' -Status 'UNREACHABLE'
  exit 0
}

# post-* phases are fire-and-forget notifications.
if ($Phase -eq 'post-deploy' -or $Phase -eq 'post-release') {
  Write-Host "PolicyGate $Phase notification sent successfully"
  Write-GateResult -Signal 'SENT' -Status 'SENT'
  exit 0
}

# ---- poll the gate to resolution (pre-release / pre-deploy) -----------------

$statusHref = $null; $gateHref = $null
try { $statusHref = $initial._links.status.href } catch {}
try { $gateHref   = $initial._links.gate.href }   catch {}

if (-not $statusHref -or -not $gateHref) {
  Write-Host "WARNING: PolicyGate $Phase response missing _links.status/_links.gate - continuing (fail-open)"
  Write-GateResult -Signal 'UNKNOWN' -Status 'NO_LINKS'
  exit 0
}

$gateId = $initial.id
Write-Host "Waiting for PolicyGate gate $gateId to finish..."
$deadline   = (Get-Date).AddSeconds($TimeoutSeconds)
$gateStatus = 'PENDING'
try {
  while ($gateStatus -eq 'PENDING' -or $gateStatus -eq 'RUNNING') {
    if ((Get-Date) -gt $deadline) {
      Write-Host "WARNING: PolicyGate $Phase gate poll timed out after ${TimeoutSeconds}s - continuing (fail-open)"
      Write-GateResult -Signal 'UNKNOWN' -Status 'TIMEOUT'
      exit 0
    }
    Start-Sleep -Seconds $PollSeconds
    $statusResp = Invoke-RestMethod -Method Get -Uri $statusHref -Headers $headers -TimeoutSec 30
    $gateStatus = if ($statusResp.status) { $statusResp.status } else { 'UNKNOWN' }
    if ($gateStatus -eq 'PENDING' -or $gateStatus -eq 'RUNNING') {
      Write-Host "Gate status: $gateStatus - still waiting..."
    }
  }

  $gateResult = Invoke-RestMethod -Method Get -Uri $gateHref -Headers $headers -TimeoutSec 30
}
catch {
  Write-Host "WARNING: PolicyGate $Phase gate polling failed: $($_.Exception.Message) - continuing (fail-open)"
  Write-GateResult -Signal 'UNKNOWN' -Status 'POLL_ERROR'
  exit 0
}

$signal   = if ($gateResult.signal) { $gateResult.signal } else { 'UNKNOWN' }
$status   = if ($gateResult.status) { $gateResult.status } else { 'UNKNOWN' }
$rpTicket = if ($Phase -eq 'pre-release') { Get-RpTicket -GateResult $gateResult } else { '' }

Write-GateResult -Signal $signal -Status $status -RpTicket $rpTicket
exit 0
