# ─────────────────────────────────────────────────────────────
#  Build-Release.ps1  —  (관리자용) 직원에게 나눠 줄 "처음 설치용 zip" 만들기
#  저장소 폴더에서:  powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1
#  - 토큰은 실행 중에 물어봅니다 (또는 환경변수 UPDATE_TOKEN). 코드·저장소에는 남지 않고, 만들어진 zip 안의 config\update.secret.json 에만 들어갑니다.
# ─────────────────────────────────────────────────────────────
param([string]$Repo = '', [string]$Branch = 'main', [string]$OutDir = '', [switch]$Force)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Kit = Split-Path $PSScriptRoot -Parent
. (Join-Path $Kit 'Updater.Config.ps1')
. (Join-Path $Kit 'Updater.ps1')
Set-Location $Kit
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git 이 필요합니다. https://git-scm.com 에서 설치한 뒤 다시 실행하세요.' }
if (-not (Test-Path -LiteralPath (Join-Path $Kit '.git'))) { throw '저장소(git) 폴더에서 실행해야 합니다.' }

# 1) 저장소 이름
if (-not $Repo) {
    $url = (git remote get-url origin) 2>$null
    if ($url -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$') { $Repo = $Matches[1] + '/' + $Matches[2] }
}
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw '저장소 이름을 알 수 없습니다.  -Repo 계정/저장소  로 지정하세요.' }

# 2) 올리지 않은 변경이 있으면 경고 (이 zip의 "기준 버전"이 GitHub와 달라지기 때문)
$dirty = git status --porcelain
if ($dirty -and -not $Force) { throw "저장소에 커밋하지 않은 변경이 있습니다. 커밋·push 한 뒤 다시 실행하세요. (무시하려면 -Force)`n$dirty" }
$sha = (git rev-parse HEAD).Trim()
$date = (git log -1 --format=%cI).Trim()
$msg = Get-UpdFirstLine ((git log -1 --format=%s) -join "`n")

# 2-1) 토큰이 저장소에 올라가 있지 않은지 점검
if (git ls-files 'config/update.secret.json') { throw 'config/update.secret.json 이 git에 올라가 있습니다. .gitignore 에 추가하고 `git rm --cached config/update.secret.json` 으로 빼세요. (이미 올렸다면 그 토큰은 폐기하고 새로 만드세요)' }
$leak = git grep -l -E 'github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{30,}' -- . ':!tests' 2>$null
if ($leak) { throw "저장소 파일 안에 토큰처럼 보이는 글자가 있습니다. 확인하세요:`n$leak" }

# 3) 토큰 받기·확인
$token = $env:UPDATE_TOKEN
if (-not $token) {
    $sec = Read-Host 'GitHub 토큰 (읽기 전용 Fine-grained token) 붙여넣기' -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if (-not $token) { throw '토큰이 없습니다.' }
$script:UpdToken = $token
$api = 'https://api.github.com'; if ($env:UPDATER_API_BASE -match '^http://127\.0\.0\.1:\d+$') { $api = $env:UPDATER_API_BASE }
$cfg = [pscustomobject]@{ Repo = $Repo; Branch = $Branch; Token = $token; Api = $api }
try { $head = Invoke-UpdHttp $cfg "$api/repos/$Repo/commits/$Branch" $null }
catch { $f = ConvertTo-UpdFail $_.Exception; throw ('토큰/저장소 확인 실패: ' + $f.text) }
Write-Host "토큰 확인 OK — GitHub $Branch 최신: $(([string]$head.sha).Substring(0,7))"
if ([string]$head.sha -ne $sha) { Write-Warning "이 PC의 HEAD($($sha.Substring(0,7)))가 GitHub $Branch ($(([string]$head.sha).Substring(0,7)))와 다릅니다. push 여부를 확인하세요. (이 zip은 이 PC의 HEAD 기준이며, GitHub가 더 새것이면 첫 실행 때 자동으로 따라갑니다)" }

# 4) 파일 모으기
$stage = Join-Path ([IO.Path]::GetTempPath()) ('build-' + $sha.Substring(0, 7))
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$pres = Get-UpdPreserve; $excl = @($script:UpdApp.Exclude); $owned = @()
foreach ($rel in (git -c core.quotepath=false ls-files)) {
    if (Test-UpdMatch $rel $excl) { continue }
    if ($rel -ieq 'Install.ps1' -or $rel -ieq 'Install.cmd') { continue }
    $to = Join-Path $stage $rel; $td = Split-Path $to -Parent
    if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Force -Path $td | Out-Null }
    Copy-Item -LiteralPath (Join-Path $Kit $rel) -Destination $to -Force
    if (-not (Test-UpdMatch $rel $pres)) { $owned += $rel }
}
Write-UpdJson (Join-Path $stage 'installed.json') ([ordered]@{ sha = $sha; date = $date; message = $msg; appliedAt = (Get-Date).ToString('o'); repo = $Repo; branch = $Branch; files = @($owned) })
$sd = Join-Path $stage 'config'; if (-not (Test-Path -LiteralPath $sd)) { New-Item -ItemType Directory -Force -Path $sd | Out-Null }
Write-UpdJson (Join-Path $sd 'update.secret.json') ([ordered]@{ update = [ordered]@{ repo = $Repo; branch = $Branch; token = $token } })
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install.ps1') -Destination (Join-Path $stage 'Install.ps1') -Force
[IO.File]::WriteAllText((Join-Path $stage 'Install.cmd'), "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Install.ps1`"`r`npause`r`n", (New-Object Text.UTF8Encoding($false)))

# 5) zip
if (-not $OutDir) { $OutDir = Join-Path $Kit 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir ($script:UpdApp.FolderName + '-' + $sha.Substring(0, 7) + '.zip')
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host ''
Write-Host "만들었습니다: $zip"
Write-Host "  기준 버전: $($sha.Substring(0,7)) · $date · $msg"
Write-Host '  ※ 이 zip 안에는 토큰이 들어 있습니다. 직원에게만 전달하고, 공개 장소(메일 전체 발송·공개 게시판 등)에는 올리지 마세요.'
