param(
  [Parameter(Position=0)]
  [ValidateSet('init','status','pull','push','save','doctor')]
  [string]$Command = 'status',
  [Parameter(Position=1)]
  [string]$Message = '',
  [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Org = 'opentribe-dev'
$Manifest = Get-Content (Join-Path $Root 'repos.json') -Raw | ConvertFrom-Json
$ReposRoot = Join-Path $Root 'repos'

function Invoke-Native {
  param([string]$Exe,[string[]]$Args=@(),[string]$Cwd='')
  $old=$ErrorActionPreference
  $o=@(); $c=127
  try {
    $ErrorActionPreference='Continue'
    if($Cwd){Push-Location $Cwd}
    try {
      if(-not (Get-Command $Exe -ErrorAction SilentlyContinue)){
        $o=@("Command not found: $Exe")
        $c=127
      } else {
        $o=@(& $Exe @Args 2>&1)
        $c=$LASTEXITCODE
      }
    } finally {if($Cwd){Pop-Location}}
  } finally {$ErrorActionPreference=$old}
  [pscustomobject]@{ExitCode=$c;Output=$o}
}
function Test-RemoteRepo([string]$Name){
  if($LocalOnly){return $false}
  $r=Invoke-Native 'gh' @('repo','view',"$Org/$Name",'--json','name')
  return $r.ExitCode -eq 0
}
function Ensure-Identity([string]$Path){
  $n=Invoke-Native 'git' @('-C',$Path,'config','user.name')
  $e=Invoke-Native 'git' @('-C',$Path,'config','user.email')
  if($n.ExitCode -eq 0 -and $e.ExitCode -eq 0 -and $n.Output -and $e.Output){return}
  if(-not $LocalOnly -and (Get-Command 'gh' -ErrorAction SilentlyContinue)){
    $login=Invoke-Native 'gh' @('api','user','--jq','.login')
    $id=Invoke-Native 'gh' @('api','user','--jq','.id')
    if($login.ExitCode -eq 0 -and $id.ExitCode -eq 0){
      $u="$($login.Output[0])".Trim(); $uid="$($id.Output[0])".Trim()
      Invoke-Native 'git' @('-C',$Path,'config','user.name',$u) | Out-Null
      Invoke-Native 'git' @('-C',$Path,'config','user.email',"$uid+$u@users.noreply.github.com") | Out-Null
      return
    }
  }
  Invoke-Native 'git' @('-C',$Path,'config','user.name','OpenCrew Bootstrap') | Out-Null
  Invoke-Native 'git' @('-C',$Path,'config','user.email','bootstrap@opentribe.dev') | Out-Null
}
function Write-Text([string]$Path,[string]$Text){
  $Text=$Text -replace "`r?`n","`r`n"
  [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))
}
function Init-One($Repo){
  $name=$Repo.name
  $path=Join-Path $ReposRoot $name
  $full="$Org/$name"
  if(Test-Path (Join-Path $path '.git')){ Write-Host "  OK  $name already initialized" -ForegroundColor Green; return }

  if((!$LocalOnly) -and (Test-RemoteRepo $name)){
    New-Item -ItemType Directory -Force -Path $ReposRoot | Out-Null
    $r=Invoke-Native 'gh' @('repo','clone',$full,$path)
    if($r.ExitCode -ne 0){throw "Clone failed: $full"}
    Write-Host "  OK  cloned $full" -ForegroundColor Green
    return
  }

  New-Item -ItemType Directory -Force -Path $path | Out-Null
  $r=Invoke-Native 'git' @('-C',$path,'init','-b','main')
  if($r.ExitCode -ne 0){Invoke-Native 'git' @('-C',$path,'init')|Out-Null;Invoke-Native 'git' @('-C',$path,'branch','-M','main')|Out-Null}

  Write-Text (Join-Path $path 'README.md') "# OpenCrew $name`r`n`r`nPart of https://github.com/$Org.`r`n"
  $rules="# OpenCrew $name`r`n`r`nThis is an independent Git repository inside the OpenCrew multi-repo workspace.`r`nKeep changes scoped to this component and coordinate protocol changes across affected repos.`r`n"
  Write-Text (Join-Path $path 'AGENTS.md') $rules
  Write-Text (Join-Path $path 'CLAUDE.md') $rules
  Write-Text (Join-Path $path '.gitignore') "node_modules/`r`ndist/`r`nbuild/`r`n.env`r`n.DS_Store`r`n"

  Ensure-Identity $path
  Invoke-Native 'git' @('-C',$path,'add','.') | Out-Null
  $commit=Invoke-Native 'git' @('-C',$path,'commit','-m','chore: initialize repository')
  if($commit.ExitCode -ne 0){throw "Initial commit failed: $name"}

  if(!$LocalOnly){
    $flag=if($Repo.visibility -eq 'private'){'--private'}else{'--public'}
    $create=Invoke-Native 'gh' @('repo','create',$full,$flag,'--description',$Repo.description,'--source',$path,'--remote','origin','--push')
    if($create.ExitCode -ne 0){
      $create.Output | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
      throw "GitHub repo create failed: $full"
    }
    Write-Host "  OK  created $full" -ForegroundColor Green
  } else { Write-Host "  OK  initialized $name locally" -ForegroundColor Green }
}

function Each-Repo([scriptblock]$Action){foreach($r in $Manifest){$p=Join-Path $ReposRoot $r.name;& $Action $r $p}}

switch($Command){
  'init' { foreach($r in $Manifest){ Init-One $r } }
  'status' {
    Each-Repo { param($r,$p)
      if(!(Test-Path (Join-Path $p '.git'))){Write-Host ("  --  {0,-10} not initialized" -f $r.name) -ForegroundColor DarkGray;return}
      $s=Invoke-Native 'git' @('-C',$p,'status','--short','--branch')
      Write-Host "`n[$($r.name)]" -ForegroundColor Cyan; $s.Output | ForEach-Object { Write-Host "  $_" }
    }
  }
  'pull' {
    Each-Repo { param($r,$p)
      if(!(Test-Path (Join-Path $p '.git'))){return}
      $dirty=Invoke-Native 'git' @('-C',$p,'status','--porcelain')
      if($dirty.Output.Count -gt 0){Write-Host "  SKIP $($r.name): dirty" -ForegroundColor Yellow;return}
      $x=Invoke-Native 'git' @('-C',$p,'pull','--ff-only')
      if($x.ExitCode -eq 0){Write-Host "  OK   $($r.name)" -ForegroundColor Green}else{Write-Host "  FAIL $($r.name)" -ForegroundColor Red}
    }
  }
  'push' {
    Each-Repo { param($r,$p)
      if(!(Test-Path (Join-Path $p '.git'))){return}
      $x=Invoke-Native 'git' @('-C',$p,'push')
      if($x.ExitCode -eq 0){Write-Host "  OK   $($r.name)" -ForegroundColor Green}else{Write-Host "  FAIL $($r.name)" -ForegroundColor Red}
    }
  }
  'save' {
    if(!$Message){throw 'Usage: .\oc.ps1 save "commit message"'}
    Each-Repo { param($r,$p)
      if(!(Test-Path (Join-Path $p '.git'))){return}
      $dirty=Invoke-Native 'git' @('-C',$p,'status','--porcelain')
      if($dirty.Output.Count -eq 0){return}
      Ensure-Identity $p
      Invoke-Native 'git' @('-C',$p,'add','.') | Out-Null
      $c=Invoke-Native 'git' @('-C',$p,'commit','-m',$Message)
      if($c.ExitCode -ne 0){throw "Commit failed: $($r.name)"}
      $push=Invoke-Native 'git' @('-C',$p,'push')
      if($push.ExitCode -ne 0){throw "Push failed: $($r.name)"}
      Write-Host "  OK   $($r.name)" -ForegroundColor Green
    }
  }
  'doctor' {
    Write-Host "OpenCrew doctor" -ForegroundColor Cyan
    foreach($tool in @('git','gh')){if(Get-Command $tool -ErrorAction SilentlyContinue){Write-Host "  OK   $tool" -ForegroundColor Green}else{Write-Host "  MISS $tool" -ForegroundColor Yellow}}
    Each-Repo { param($r,$p)
      if(Test-Path (Join-Path $p '.git')){Write-Host "  OK   repos/$($r.name)" -ForegroundColor Green}else{Write-Host "  MISS repos/$($r.name)" -ForegroundColor Yellow}
    }
  }
}