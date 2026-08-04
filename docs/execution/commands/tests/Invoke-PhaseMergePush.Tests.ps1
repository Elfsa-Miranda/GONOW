$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-PhaseMerge.ps1'
$CanonicalRemote = 'https://github.com/Elfsa-Miranda/GO_NOW.git'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('gonow-phase-push-' + [Guid]::NewGuid().ToString('N'))
$Control = Join-Path $Root 'control'
$Source = Join-Path $Root 'source'
$Bare = Join-Path $Root 'remote.git'

function Invoke-Git {
  param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string[]]$Arguments)
  $Previous=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$Output=@(& git -C $Repository @Arguments 2>&1);$Exit=$LASTEXITCODE}finally{$ErrorActionPreference=$Previous};if($Exit-ne0){throw "git failed: $($Arguments -join ' ')`n$($Output -join "`n")"};return $Output
}
function Write-Utf8 {
  param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Value)
  $Parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $Parent)){New-Item -ItemType Directory -Path $Parent -Force|Out-Null};[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
}
function Get-RemoteOid {
  param([string]$Ref)
  $Rows=@(& git -C $Control ls-remote --heads origin $Ref);if($LASTEXITCODE-ne0){throw "ls-remote failed: $Ref"};if($Rows.Count-eq0){return ''};return (([string]$Rows[0])-split'\s+')[0]
}

New-Item -ItemType Directory -Path $Root -Force|Out-Null
try {
  & git init --bare $Bare | Out-Null;if($LASTEXITCODE-ne0){throw 'bare init failed'}
  & git init -b main $Control | Out-Null;if($LASTEXITCODE-ne0){throw 'control init failed'}
  Invoke-Git $Control @('config','user.name','GoNow Push Test')|Out-Null;Invoke-Git $Control @('config','user.email','push-test@example.invalid')|Out-Null;Invoke-Git $Control @('config','core.autocrlf','false')|Out-Null
  Write-Utf8 (Join-Path $Control 'fixture.txt') "base`n";Invoke-Git $Control @('add','fixture.txt')|Out-Null;Invoke-Git $Control @('commit','-m','base')|Out-Null;$Base=(Invoke-Git $Control @('rev-parse','HEAD')|Select-Object -Last 1).Trim()
  Invoke-Git $Control @('checkout','-b','codex/phase-10-release-b-gates')|Out-Null;Write-Utf8 (Join-Path $Control 'fixture.txt') "candidate`n";Invoke-Git $Control @('add','fixture.txt')|Out-Null;Invoke-Git $Control @('commit','-m','candidate')|Out-Null;$Candidate=(Invoke-Git $Control @('rev-parse','HEAD')|Select-Object -Last 1).Trim()
  Write-Utf8 (Join-Path $Control 'approval.txt') "approval`n";Invoke-Git $Control @('add','approval.txt')|Out-Null;Invoke-Git $Control @('commit','-m','approval')|Out-Null
  Invoke-Git $Control @('checkout','main')|Out-Null;Invoke-Git $Control @('checkout','-b','codex/gonow-agent-landing')|Out-Null;Write-Utf8 (Join-Path $Control 'close.txt') "close`n";Invoke-Git $Control @('add','close.txt')|Out-Null;Invoke-Git $Control @('commit','-m','phase close')|Out-Null;$Close=(Invoke-Git $Control @('rev-parse','HEAD')|Select-Object -Last 1).Trim()
  Invoke-Git $Control @('worktree','add',$Source,'codex/phase-10-release-b-gates')|Out-Null
  $BareUri=([Uri]::new($Bare)).AbsoluteUri;Invoke-Git $Control @('remote','add','origin',$CanonicalRemote)|Out-Null;Invoke-Git $Control @('config',"url.$BareUri.insteadOf",$CanonicalRemote)|Out-Null
  Invoke-Git $Control @('push','origin',"$Base`:refs/heads/main")|Out-Null
  $EvidenceRoot=Join-Path $Control 'docs/execution/evidence';New-Item -ItemType Directory -Path $EvidenceRoot -Force|Out-Null
  $StatePath=Join-Path $Control '.git/gonow-phase-merge/TASK-P10-999/state.json'
  $State=[ordered]@{schema_version='1.0';task_id='TASK-P10-999';source_worktree=$Source;source_branch='codex/phase-10-release-b-gates';landing_branch='codex/gonow-agent-landing';requested_landing_evidence_root=$EvidenceRoot;phase_base_oid=$Base;candidate_head_oid=$Candidate;approval_tip_oid=(Invoke-Git $Source @('rev-parse','HEAD')|Select-Object -Last 1).Trim();landing_premerge_oid=$Base;landing_worktree=$Control;merge_oid=$Candidate;smoke_attestation_oid=$Candidate;phase_close_oid=$Close;history=@([ordered]@{mode='CloseVerify';status='passed';reason_code='';checks=[ordered]@{phase_close_chain_valid=$true};recorded_at=[DateTimeOffset]::Now.ToString('o')})}
  Write-Utf8 $StatePath (($State|ConvertTo-Json -Depth 20)+"`n")

  $Output=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -TaskId 'TASK-P10-999' -ControlRepo $Control -SourceWorktree $Source -SourceBranch 'codex/phase-10-release-b-gates' -LandingBranch 'codex/gonow-agent-landing' -LandingEvidenceRoot $EvidenceRoot -Mode Push 2>&1);$Exit=$LASTEXITCODE
  if($Exit-ne0){throw "positive push failed: $($Output -join "`n")"};$Result=([string]$Output[-1])|ConvertFrom-Json
  if([string]$Result.status-cne'passed'-or[bool]$Result.checks.force-or-not[bool]$Result.checks.atomic-or[int]$Result.checks.unexpected_remote_ref_writes-ne0){throw 'positive push result contract failed'}
  if((Get-RemoteOid 'refs/heads/main')-cne$Base-or(Get-RemoteOid 'refs/heads/codex/phase-10-release-b-gates')-cne$Candidate-or(Get-RemoteOid 'refs/heads/codex/gonow-agent-landing')-cne$Close){throw 'positive push remote OID contract failed'}
  $ReceiptPath=Join-Path $Control 'docs/execution/evidence/phase-10/push.json';$Receipt=Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$Receipt.phase_remote_oid-cne$Candidate-or[string]$Receipt.landing_remote_oid-cne$Close-or[bool]$Receipt.force-or-not[bool]$Receipt.atomic-or[int]$Receipt.unexpected_remote_ref_writes-ne0-or[int]$Receipt.remote_write_count-ne2){throw 'positive push receipt contract failed'}

  $Second=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -TaskId 'TASK-P10-999' -ControlRepo $Control -SourceWorktree $Source -SourceBranch 'codex/phase-10-release-b-gates' -LandingBranch 'codex/gonow-agent-landing' -LandingEvidenceRoot $EvidenceRoot -Mode Push 2>&1);if($LASTEXITCODE-ne0){throw "idempotent push failed: $($Second -join "`n")"};$SecondResult=([string]$Second[-1])|ConvertFrom-Json
  if(-not[bool]$SecondResult.checks.idempotent_noop-or[int]$SecondResult.remote_write_count-ne0){throw 'idempotent push performed a remote write'}

  $Receipt.force=$true;Write-Utf8 $ReceiptPath (($Receipt|ConvertTo-Json -Depth 20)+"`n");$Tampered=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -TaskId 'TASK-P10-999' -ControlRepo $Control -SourceWorktree $Source -SourceBranch 'codex/phase-10-release-b-gates' -LandingBranch 'codex/gonow-agent-landing' -LandingEvidenceRoot $EvidenceRoot -Mode Push 2>&1)
  if($LASTEXITCODE-eq0-or([string]$Tampered[-1]|ConvertFrom-Json).reason_code-cne'p10_999_push_receipt_conflict'){throw 'tampered push receipt was accepted'}
} finally {
  if(Test-Path -LiteralPath $Root){$Resolved=[IO.Path]::GetFullPath($Root);$Temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath());if(-not$Resolved.StartsWith($Temp,[StringComparison]::OrdinalIgnoreCase)){throw 'temporary cleanup target escaped temp root'};Remove-Item -LiteralPath $Resolved -Recurse -Force}
}
exit 0
