# 업데이트 키트 시험:  pwsh -File tests/Run-Tests.ps1   (또는 powershell -ExecutionPolicy Bypass -File tests/Run-Tests.ps1)
# 가짜 GitHub 서버를 띄워 확인·받기·교체·되돌리기·토큰 보호·오류 처리 등을 실제로 돌려 봅니다. 인터넷·실제 토큰은 쓰지 않습니다.
param([int]$Port = 0, [switch]$KeepTemp)
$ErrorActionPreference = 'Stop'
$Kit = Split-Path $PSScriptRoot -Parent
. (Join-Path $Kit 'Updater.Config.ps1')
. (Join-Path $Kit 'Updater.ps1')
$utf8 = New-Object Text.UTF8Encoding($false)
$T = Join-Path ([IO.Path]::GetTempPath()) ('updtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $T | Out-Null
if (-not $Port) { $Port = Get-Random -Minimum 20000 -Maximum 40000 }
$TOKEN = 'zz-TESTTOKEN-12345'
$S1 = '1' * 40; $S2 = '2' * 40; $S3 = '3' * 40
$D1 = '2026-10-01T00:00:00Z'; $D2 = '2026-10-10T00:00:00Z'; $D3 = '2026-10-20T00:00:00Z'
$pass = 0; $fail = 0
function Ok($cond, [string]$name) { if ($cond) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name" -ForegroundColor Red } }
function WriteT($path, $text) { $d = Split-Path $path -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }; [IO.File]::WriteAllText($path, $text, $utf8) }
function ReadT($path) { if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path, $utf8) } else { $null } }

# ── 가짜 서버 ──
$FD = Join-Path $T 'fake'; New-Item -ItemType Directory -Force -Path $FD | Out-Null
function Set-Fake([hashtable]$h) {
    $p = Join-Path $FD 'state.json'; $cur = @{ repo = 'acme/app'; branch = 'main'; token = $TOKEN; mode = 'ok'; delay = 0 }
    if (Test-Path $p) { (ReadT $p | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cur[$_.Name] = $_.Value } }
    foreach ($k in $h.Keys) { $cur[$k] = $h[$k] }
    WriteT $p (ConvertTo-Json -InputObject $cur -Depth 6)
}
function New-FakeZip([string]$path, [string]$prefix, [hashtable]$files, [hashtable]$raw = @{}) {
    if (Test-Path $path) { Remove-Item $path -Force }
    $fs = [IO.File]::Open($path, 'Create'); $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $all = @{}; foreach ($k in $files.Keys) { $all[$prefix + '/' + $k] = $files[$k] }; foreach ($k in $raw.Keys) { $all[$k] = $raw[$k] }
        foreach ($n in $all.Keys) { $e = $za.CreateEntry($n); $s = $e.Open(); $b = $utf8.GetBytes([string]$all[$n]); $s.Write($b, 0, $b.Length); $s.Dispose() }
    } finally { $za.Dispose(); $fs.Dispose() }
}
function Reqs { $r = ReadT (Join-Path $FD 'requests.log'); if ($r) { @($r -split "`n" | Where-Object { $_ }) } else { @() } }
function Reset-Reqs { WriteT (Join-Path $FD 'requests.log') '' }

$psExe = Get-UpdPsPath
function Start-Hidden($exe, $argList) { if (Test-UpdWindows) { Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden } else { Start-Process -FilePath $exe -ArgumentList $argList -PassThru } }
$srv = Start-Hidden $psExe @('-NoProfile', '-File', ('"' + (Join-Path $PSScriptRoot 'FakeGitHub.ps1') + '"'), '-Port', $Port, '-Dir', ('"' + $FD + '"'))
$env:UPDATER_API_BASE = "http://127.0.0.1:$Port"

# 저장소 내용 (v2)
$zip2 = Join-Path $T 'v2.zip'
$kitFiles = @{}
foreach ($f in 'Launch.ps1', 'Updater.ps1', 'Updater.Config.ps1', 'Update-Worker.ps1', 'Update-Api.ps1', 'web/index.html', 'web/update-ui.js') { $kitFiles[$f] = [IO.File]::ReadAllText((Join-Path $Kit $f), $utf8) }
$v2 = @{
    'app.txt' = 'v2'; 'new.txt' = 'new in v2'; 'sub/dir/deep.txt' = 'deep v2'
    'settings.json' = '{"from":"REPO-DEFAULT"}'; 'data/notes.json' = '{"from":"REPO-DATA"}'; 'han글.txt' = '한글 v2'
    '.github/x.yml' = 'ci'; 'tools/t.ps1' = 'admin'; '.gitignore' = 'x'
}
foreach ($k in $kitFiles.Keys) { $v2[$k] = $kitFiles[$k] }
New-FakeZip $zip2 "acme-app-$($S2.Substring(0,7))" $v2
Set-Fake @{ head = @{ sha = $S2; date = $D2; message = "두번째 커밋`n/n자세한 내용" }; zip = $zip2 }
Write-Host "가짜 GitHub 서버: 127.0.0.1:$Port"
for ($i = 0; $i -lt 50; $i++) { try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/ping" -UseBasicParsing } catch { if ($_.Exception.Response) { break } }; Start-Sleep -Milliseconds 200 }

function New-Install([string]$name, [string]$sha = $S1, [string]$date = $D1) {
    $d = Join-Path $T $name
    WriteT "$d/Launch.ps1" '# launcher v1'; WriteT "$d/app.txt" 'v1'; WriteT "$d/old-only.txt" 'old'
    WriteT "$d/data/notes.json" '{"mine":"USER-DATA"}'; WriteT "$d/settings.json" '{"mine":"USER-SET"}'
    WriteT "$d/config/update.secret.json" (ConvertTo-Json -InputObject @{ update = @{ repo = 'acme/app'; branch = 'main'; token = $TOKEN } })
    WriteT "$d/installed.json" (ConvertTo-Json -InputObject ([ordered]@{ sha = $sha; date = $date; message = 'first'; files = @('Launch.ps1', 'app.txt', 'old-only.txt') }) -Depth 4)
    return (New-UpdContext -Root $d -AllowDev)
}
function Chk($ctx) { Invoke-UpdCheck $ctx | Out-Null; return (Read-UpdJson $ctx.Check) }
function NoToken($ctx) {
    foreach ($f in @($ctx.Check, (Join-Path $ctx.Root 'update.log'), (Join-Path $ctx.Root 'start.log'), $ctx.Staged)) { $t = ReadT $f; if ($t -and $t.Contains($TOKEN)) { return $false } }
    return $true
}

Write-Host "`n[1] 같은 커밋이면 아무것도 안 함"
$c = New-Install 'i1' $S2 $D2; Reset-Reqs
$r = Chk $c
Ok ($r.state -eq 'uptodate' -and $r.code -eq 'same') '상태 = 이미 최신'
Ok (-not (Test-Path $c.StagedDir)) '받아 둔 것 없음'
Ok ((Reqs | Where-Object { $_ -like '*zipball*' }).Count -eq 0) 'zip 내려받기 요청 없음'
Ok ((Reqs | Where-Object { $_ -like '*commits*' }).Count -eq 1) '커밋 확인 요청 1번'

Write-Host "`n[2] 새 커밋 → 받아 두기만 하고 바꾸지는 않음"
$c = New-Install 'i2'; Reset-Reqs
$r = Chk $c
Ok ($r.state -eq 'staged') '상태 = staged'
Ok ((ReadT "$($c.Root)/app.txt") -eq 'v1') '프로그램 파일은 그대로(v1)'
Ok ((Read-UpdJson $c.Installed).sha -eq $S1) 'installed.json 그대로'
Ok ((Read-UpdJson $c.Staged).sha -eq $S2) 'staged.json = 새 커밋'
Ok ((Reqs | Where-Object { $_ -like '*zipball*' }).Count -eq 1) 'zip 1번 받음(리다이렉트 포함)'
Ok (-not (Test-Path (Join-Path $c.StagedDir "$S2/.github")) -and -not (Test-Path (Join-Path $c.StagedDir "$S2/tools"))) '관리용 파일(.github, tools)은 제외'
Ok (NoToken $c) '로그·상태 파일에 토큰 없음'
Reset-Reqs; $r = Chk $c
Ok ($r.state -eq 'staged' -and (Reqs | Where-Object { $_ -like '*zipball*' }).Count -eq 0) '다시 확인해도 같은 버전은 다시 안 받음'

Write-Host "`n[3] 다음에 켤 때 바꿔 끼우기 — 사용자 데이터는 그대로"
$a = Invoke-UpdApply $c
Ok ($a.applied) '적용됨'
Ok ((ReadT "$($c.Root)/app.txt") -eq 'v2' -and (ReadT "$($c.Root)/new.txt") -eq 'new in v2') '프로그램 파일 교체·추가'
Ok ((ReadT "$($c.Root)/sub/dir/deep.txt") -eq 'deep v2' -and (ReadT "$($c.Root)/han글.txt") -eq '한글 v2') '하위 폴더·한글 파일명'
Ok (-not (Test-Path "$($c.Root)/old-only.txt")) '새 버전에서 없어진 파일 삭제'
Ok ((ReadT "$($c.Root)/data/notes.json") -like '*USER-DATA*') 'data 폴더 사용자 데이터 유지'
Ok ((ReadT "$($c.Root)/settings.json") -like '*USER-SET*') 'settings.json 사용자 설정 유지'
Ok (((ReadT "$($c.Root)/config/update.secret.json") | ConvertFrom-Json).update.token -eq $TOKEN) '토큰 설정 파일 그대로'
Ok (-not (Test-Path "$($c.Root)/.github") -and -not (Test-Path "$($c.Root)/tools")) '관리용 파일은 설치 안 됨'
$i = Read-UpdJson $c.Installed
Ok ($i.sha -eq $S2 -and (ConvertTo-UpdDateStr $i.date) -like '2026-10-10*' -and $i.message -like '두번째 커밋*') 'installed.json에 커밋 번호·날짜·메시지 기록'
Ok (-not (Test-Path $c.Staged) -and -not (Test-Path $c.StagedDir)) '받아 둔 것 정리됨'
Ok (NoToken $c) '토큰이 로그에 없음'
$r = Chk $c
Ok ($r.state -eq 'uptodate') '적용 뒤 확인하면 최신'

Write-Host "`n[4] 사용자 파일이 아직 없으면 저장소 기본 파일을 넣어 줌"
$c = New-Install 'i4'; Remove-Item "$($c.Root)/settings.json"; Remove-Item "$($c.Root)/data" -Recurse
Chk $c | Out-Null; Invoke-UpdApply $c | Out-Null
Ok ((ReadT "$($c.Root)/settings.json") -like '*REPO-DEFAULT*' -and (ReadT "$($c.Root)/data/notes.json") -like '*REPO-DATA*') '없던 사용자 파일은 기본값으로 생성'
Ok ((Read-UpdJson $c.Installed).files -notcontains 'settings.json') '사용자 파일은 프로그램 파일 목록에 안 넣음'

Write-Host "`n[5] 오류 안내 (401/403/404/인터넷 끊김)"
foreach ($m in '401', '403', '404') {
    Set-Fake @{ mode = $m }; $c = New-Install "i5$m"; $r = Chk $c
    Ok ($r.state -eq 'error' -and $r.code -eq $m -and $r.text -like "*($m)*") "$m → 안내 문구"
    Ok ((ReadT "$($c.Root)/app.txt") -eq 'v1') "$m → 기존 버전 유지"
    Ok (NoToken $c) "$m → 토큰 노출 없음"
}
Set-Fake @{ mode = 'ok' }
$c = New-Install 'i5bad'; $cfgPath = $c.Secret
WriteT $cfgPath (ConvertTo-Json -InputObject @{ update = @{ repo = 'acme/app'; branch = 'main'; token = 'WRONG-TOKEN' } })
$r = Chk $c
Ok ($r.state -eq 'error' -and $r.code -eq '401') '틀린 토큰 → 401 안내'
$saved = $env:UPDATER_API_BASE; $env:UPDATER_API_BASE = 'http://127.0.0.1:1'
$c = New-Install 'i5off'; $r = Chk $c
Ok ($r.state -eq 'offline') '접속 불가 → offline (조용히 건너뜀)'
$env:UPDATER_API_BASE = $saved
$c = New-Install 'i5cfg'; Remove-Item $c.Secret; $r = Chk $c
Ok ($r.state -eq 'error' -and $r.code -eq 'config') '설정 파일 없음 → 안내'

Write-Host "`n[6] 깨진 압축 → 버리고 기존 버전 유지"
Set-Fake @{ mode = 'corrupt' }; $c = New-Install 'i6'; $r = Chk $c
Ok ($r.state -eq 'error' -and $r.code -eq 'zip') '깨진 zip 감지'
Ok (-not (Test-Path $c.Staged) -and (ReadT "$($c.Root)/app.txt") -eq 'v1') '받아 둔 것 없음 · 기존 버전 유지'
Ok (-not (Test-Path (Join-Path $c.State 'staging')) -and -not (Test-Path (Join-Path $c.State 'dl'))) '임시 폴더 정리'
Set-Fake @{ mode = 'ok' }

Write-Host "`n[7] 설치본이 GitHub보다 새것이면 되돌아가지 않음"
$c = New-Install 'i7' $S3 $D3; Reset-Reqs; $r = Chk $c
Ok ($r.state -eq 'uptodate' -and $r.code -eq 'newer-local') '상태 = 설치본이 더 새것'
Ok ((Reqs | Where-Object { $_ -like '*zipball*' }).Count -eq 0 -and (ReadT "$($c.Root)/app.txt") -eq 'v1') '내려받기·교체 없음'

Write-Host "`n[8] 개발 폴더에서는 업데이트 안 함"
$c = New-Install 'i8'; New-Item -ItemType Directory "$($c.Root)/.git" | Out-Null
$c2 = New-UpdContext -Root $c.Root; Reset-Reqs; $r = Chk $c2
Ok ($r.state -eq 'skipped' -and $r.code -eq 'dev' -and (Reqs).Count -eq 0) '.git 폴더 → 건너뜀(요청 0건)'
$c3 = New-Install 'i8b'; $c4 = New-UpdContext -Root $c3.Root; $r = Chk $c4
Ok ($r.state -eq 'skipped') '설치 위치가 아닌 곳 → 건너뜀'
Chk $c | Out-Null  # (AllowDev 컨텍스트는 .git 이 있어도 시험 가능)
$ap = Invoke-UpdApply $c2
Ok (-not $ap.applied) '개발 폴더에서는 적용도 안 함'

Write-Host "`n[9] 압축 안의 위험한 경로(../) 거부"
$evil = Join-Path $T 'evil.zip'
New-FakeZip $evil "acme-app-evil" @{ 'ok.txt' = 'x' } @{ 'acme-app-evil/../../escaped.txt' = 'pwned' }
Set-Fake @{ zip = $evil }; $c = New-Install 'i9'; $r = Chk $c
Ok ($r.state -eq 'error' -and $r.code -eq 'zip') '위험 경로 → 거부'
Ok (-not (Test-Path (Join-Path $T 'escaped.txt')) -and -not (Test-Path (Join-Path (Split-Path $c.Root -Parent) 'escaped.txt'))) '바깥에 파일이 생기지 않음'
Set-Fake @{ zip = $zip2 }

Write-Host "`n[10] 적용 도중 실패 → 전부 이전 상태로 되돌림"
$c = New-Install 'i10'; Chk $c | Out-Null
$global:UpdTestFailAt = 3
$a = Invoke-UpdApply $c
$global:UpdTestFailAt = 0
Ok ($a.failed -and -not $a.applied) '실패로 처리'
Ok ((ReadT "$($c.Root)/app.txt") -eq 'v1' -and (ReadT "$($c.Root)/old-only.txt") -eq 'old' -and -not (Test-Path "$($c.Root)/new.txt")) '파일 모두 원래대로'
Ok ((Read-UpdJson $c.Installed).sha -eq $S1) 'installed.json 그대로'
Ok ((Read-UpdJson $c.Check).code -eq 'apply' -and -not (Test-Path $c.Staged)) '실패 기록 · 받아 둔 것 폐기'
$r = Chk $c
Ok ($r.state -eq 'staged') '다음 확인 때 다시 받아 둠'
$a = Invoke-UpdApply $c; Ok ($a.applied) '그 뒤 정상 적용'

Write-Host "`n[11] 받아 둔 파일이 변조·손상되면 적용 안 함"
$c = New-Install 'i11'; Chk $c | Out-Null
WriteT (Join-Path $c.StagedDir "$S2/app.txt") 'TAMPERED'
$a = Invoke-UpdApply $c
Ok (-not $a.applied -and (ReadT "$($c.Root)/app.txt") -eq 'v1') '해시 불일치 → 적용 안 함'
Ok (-not (Test-Path $c.Staged)) '손상본 폐기'

Write-Host "`n[12] 설정(json)이 새것으로 바뀌어도 이 PC의 토큰은 유지"
$saveApp = $script:UpdApp.Preserve
$script:UpdApp.Preserve = @('data/*')    # config/app.json 은 보호 대상이 아님 → 덮어써짐
$zip12 = Join-Path $T 'v12.zip'
New-FakeZip $zip12 "acme-app-$($S2.Substring(0,7))" @{ 'app.txt' = 'v2'; 'config/app.json' = '{"theme":"new","update":{"repo":"acme/app","branch":"main"}}' }
Set-Fake @{ zip = $zip12 }
$c = New-Install 'i12'; WriteT "$($c.Root)/config/app.json" (ConvertTo-Json -InputObject @{ theme = 'old'; update = @{ repo = 'acme/app'; branch = 'main'; token = $TOKEN } })
Chk $c | Out-Null; Invoke-UpdApply $c | Out-Null
$j = (ReadT "$($c.Root)/config/app.json") | ConvertFrom-Json
Ok ($j.theme -eq 'new' -and $j.update.token -eq $TOKEN) '새 설정으로 바뀌고 토큰은 이어 붙음'
$script:UpdApp.Preserve = $saveApp; Set-Fake @{ zip = $zip2 }

Write-Host "`n[13] 화면용 상태(토큰 미포함)"
$c = New-Install 'i13'; Chk $c | Out-Null
$js = ConvertTo-Json -InputObject (Get-UpdStatus $c) -Depth 8
$st = $js | ConvertFrom-Json
Ok ($st.current.short -eq '1111111' -and $st.staged.short -eq '2222222' -and $st.check.state -eq 'staged') '현재/받아 둔 버전·상태 포함'
Ok (-not $js.Contains($TOKEN)) '상태 응답에 토큰 없음'

Write-Host "`n[14] 종단 시험: Launch.ps1 → 창 즉시 열림 · 뒤에서 확인 · 알림 · 다시 켜기"
$lp = Get-Random -Minimum 41000 -Maximum 49000
$ei = Join-Path $T 'e2e'; New-Item -ItemType Directory -Force -Path $ei | Out-Null
foreach ($f in 'Launch.ps1', 'Updater.ps1', 'Updater.Config.ps1', 'Update-Worker.ps1', 'Update-Api.ps1') { Copy-Item (Join-Path $Kit $f) $ei }
New-Item -ItemType Directory -Force -Path "$ei/web" | Out-Null; Copy-Item (Join-Path $Kit 'web/*') "$ei/web" -Recurse
WriteT "$ei/app.txt" 'v1'; WriteT "$ei/data/notes.json" '{"mine":"USER-DATA"}'
WriteT "$ei/config/update.secret.json" (ConvertTo-Json -InputObject @{ update = @{ repo = 'acme/app'; branch = 'main'; token = $TOKEN } })
WriteT "$ei/installed.json" (ConvertTo-Json -InputObject ([ordered]@{ sha = $S1; date = $D1; message = 'first'; files = @('app.txt', 'Launch.ps1', 'Updater.ps1', 'Updater.Config.ps1', 'Update-Worker.ps1', 'Update-Api.ps1', 'web/index.html', 'web/update-ui.js') }) -Depth 4)
Set-Fake @{ delay = 3 }          # GitHub 응답이 3초 걸려도 창은 바로 떠야 함
$env:UPDATER_INSTALL_DIR = $ei
$sw = [Diagnostics.Stopwatch]::StartNew()
$app = Start-Hidden $psExe @('-NoProfile', '-File', ('"' + "$ei/Launch.ps1" + '"'), '-Port', $lp, '-NoBrowser')
$base = "http://localhost:$lp"
$ui = $null
for ($i = 0; $i -lt 100 -and -not $ui; $i++) { try { $ui = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 100 } }
$tFirst = $sw.Elapsed.TotalSeconds
Ok ($ui -and $ui.StatusCode -eq 200 -and $tFirst -lt 3.0) ("화면이 확인(3초 지연)을 기다리지 않고 바로 열림 (" + [math]::Round($tFirst, 1) + '초)')
$H = @{ 'X-Requested-With' = 'update-ui' }
$s0 = (Invoke-WebRequest -Uri "$base/api/update/status" -UseBasicParsing).Content | ConvertFrom-Json
Ok ($s0.current.short -eq '1111111') '설정 화면용 현재 버전 표시'
$got = $null
for ($i = 0; $i -lt 100 -and -not $got; $i++) { Start-Sleep -Milliseconds 300; $s = (Invoke-WebRequest -Uri "$base/api/update/status" -UseBasicParsing).Content | ConvertFrom-Json; if ($s.check.state -eq 'staged') { $got = $s } }
Ok ($null -ne $got -and $got.staged.short -eq '2222222') '뒤에서 확인이 끝나 "새 버전 받아 둠" 상태가 됨'
Ok ((ReadT "$ei/app.txt") -eq 'v1') '받아 둔 것만 있고 아직 안 바뀜'
# 보안: 헤더/Origin/Host 검사
$code = 0; try { Invoke-WebRequest -Uri "$base/api/update/restart" -Method Post -UseBasicParsing | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
Ok ($code -eq 403) 'POST에 X-Requested-With 없으면 403'
$code = 0; try { Invoke-WebRequest -Uri "$base/api/update/restart" -Method Post -Headers @{ 'X-Requested-With' = 'update-ui'; 'Origin' = 'http://evil.example' } -UseBasicParsing | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
Ok ($code -eq 403) '다른 사이트 Origin이면 403'
# [지금 다시 켜기]
Invoke-WebRequest -Uri "$base/api/update/restart" -Method Post -Headers $H -UseBasicParsing | Out-Null
$app.WaitForExit(15000) | Out-Null
Ok ($app.HasExited) '이전 프로그램이 종료됨'
$s2 = $null
for ($i = 0; $i -lt 150 -and -not $s2; $i++) { try { $x = (Invoke-WebRequest -Uri "$base/api/update/status" -UseBasicParsing -TimeoutSec 2).Content | ConvertFrom-Json; if ($x.current.short -eq '2222222') { $s2 = $x } } catch {}; Start-Sleep -Milliseconds 300 }
Ok ($null -ne $s2) '다시 켜진 프로그램이 새 버전(2222222)으로 시작'
Ok ((ReadT "$ei/app.txt") -eq 'v2' -and (ReadT "$ei/data/notes.json") -like '*USER-DATA*') '파일 교체됨 · 사용자 데이터 유지'
Ok ((ReadT "$ei/start.log") -like '*적용*') 'start.log에 적용 기록'
# 정리
$env:UPDATER_INSTALL_DIR = $null

Write-Host "`n[15] 관리자용: 배포 zip 만들기 → 설치 (git 필요)"
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gr = Join-Path $T 'repo'; New-Item -ItemType Directory -Force -Path $gr | Out-Null
    foreach ($f in (Get-ChildItem -LiteralPath $Kit -Recurse -File | Where-Object { $_.FullName -notmatch '[/\\]\.git[/\\]' -and $_.FullName -notmatch '[/\\]dist[/\\]' })) {
        $rel = $f.FullName.Substring($Kit.Length + 1); $to = Join-Path $gr $rel; $td = Split-Path $to -Parent
        if (-not (Test-Path $td)) { New-Item -ItemType Directory -Force -Path $td | Out-Null }; Copy-Item $f.FullName $to
    }
    WriteT "$gr/settings.json" '{"from":"REPO-DEFAULT"}'; WriteT "$gr/data/seed.json" '{"seed":1}'; WriteT "$gr/.gitignore" "config/update.secret.json`ninstalled.json`ndist/`n"
    Push-Location $gr
    try {
        git init -q 2>&1 | Out-Null; git remote add origin https://github.com/acme/app.git
        git add -A 2>&1 | Out-Null; git -c user.name=t -c user.email=t@t commit -q -m "배포 시험 커밋" 2>&1 | Out-Null
        $head = (git rev-parse HEAD).Trim(); $hd = (git log -1 --format=%cI).Trim()
        Set-Fake @{ head = @{ sha = $head; date = $hd; message = 'x' } }
        $env:UPDATE_TOKEN = $TOKEN
        $out = & $psExe -NoProfile -File (Join-Path $gr 'tools/Build-Release.ps1') -OutDir (Join-Path $T 'dist') 2>&1 | Out-String
        $env:UPDATE_TOKEN = $null
        $zipf = Get-ChildItem (Join-Path $T 'dist') -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
        Ok ($null -ne $zipf) 'zip 생성됨'
        if ($zipf) {
            $ex = Join-Path $T 'pkg'; [IO.Compression.ZipFile]::ExtractToDirectory($zipf.FullName, $ex)
            $inst = Read-UpdJson "$ex/installed.json"
            Ok ($inst.sha -eq $head -and $inst.message -eq '배포 시험 커밋') 'installed.json = 현재 커밋'
            Ok ((Read-UpdJson "$ex/config/update.secret.json").update.token -eq $TOKEN) 'zip 안 설정 파일에만 토큰'
            Ok (-not (Test-Path "$ex/tools") -and -not (Test-Path "$ex/tests") -and (Test-Path "$ex/Install.ps1") -and (Test-Path "$ex/Launch.ps1")) '관리용 폴더 제외 · 설치 스크립트 포함'
            Ok (@($inst.files) -notcontains 'settings.json' -and @($inst.files) -contains 'Launch.ps1') '프로그램 파일 목록에 사용자 파일은 없음'
            Ok (-not $out.Contains($TOKEN)) '빌드 화면 출력에 토큰 없음'
            # 설치
            $dest = Join-Path $T 'installed-here'; $env:UPDATER_INSTALL_DIR = $dest
            & $psExe -NoProfile -File "$ex/Install.ps1" 2>&1 | Out-Null
            Ok ((Test-Path "$dest/Launch.ps1") -and -not (Test-Path "$dest/Install.ps1")) '설치 위치로 복사 (Install 파일은 제외)'
            Ok ((ReadT "$dest/settings.json") -like '*REPO-DEFAULT*') '처음 설치 땐 기본 설정 생성'
            WriteT "$dest/settings.json" '{"mine":"USER-SET"}'; WriteT "$dest/data/mine.json" 'x'
            $tok2 = ReadT "$dest/config/update.secret.json"
            & $psExe -NoProfile -File "$ex/Install.ps1" 2>&1 | Out-Null
            Ok ((ReadT "$dest/settings.json") -like '*USER-SET*' -and (Test-Path "$dest/data/mine.json")) '다시 설치해도 내 설정·데이터 유지'
            Ok ((ReadT "$dest/config/update.secret.json") -eq $tok2) '다시 설치해도 토큰 파일 유지'
            $j = Read-UpdJson "$dest/installed.json"; $j2 = [ordered]@{ sha = $S3; date = '2099-01-01T00:00:00Z'; message = 'newer'; files = @() }
            WriteT "$dest/installed.json" (ConvertTo-Json -InputObject $j2); WriteT "$dest/Launch.ps1" '# newer launcher'
            & $psExe -NoProfile -File "$ex/Install.ps1" 2>&1 | Out-Null
            Ok ((ReadT "$dest/Launch.ps1") -eq '# newer launcher') '더 새 버전이 설치돼 있으면 옛 zip으로 덮어쓰지 않음'
            $env:UPDATER_INSTALL_DIR = $null
        }
        # 토큰 파일이 실수로 git에 올라가 있으면 빌드 중단
        WriteT "$gr/config/update.secret.json" '{"update":{"token":"x"}}'
        git add -f config/update.secret.json 2>&1 | Out-Null; git -c user.name=t -c user.email=t@t commit -q -m leak 2>&1 | Out-Null
        $env:UPDATE_TOKEN = $TOKEN
        $before = @(Get-ChildItem (Join-Path $T 'dist') -Filter '*.zip').Count
        $out2 = & $psExe -NoProfile -File (Join-Path $gr 'tools/Build-Release.ps1') -OutDir (Join-Path $T 'dist') 2>&1 | Out-String
        $env:UPDATE_TOKEN = $null
        Ok ($out2 -like '*git에 올라가 있습니다*' -and @(Get-ChildItem (Join-Path $T 'dist') -Filter '*.zip').Count -eq $before) '토큰 파일이 git에 올라가 있으면 빌드 중단'
    } finally { Pop-Location }
} else { Write-Host '  (git이 없어 건너뜀)' }

Write-Host "`n─────────────"
Write-Host ("결과: PASS {0} / FAIL {1}" -f $pass, $fail)
try { $srv.Kill() } catch {}
function Stop-ByPath([string]$needle) {
    if (Test-UpdWindows) { try { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$needle*" -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } } catch {} }
    else { foreach ($d in (Get-ChildItem /proc -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' })) { try { $cl = [IO.File]::ReadAllText("$($d.FullName)/cmdline"); if ($cl -like "*$needle*" -and [int]$d.Name -ne $PID) { Stop-Process -Id ([int]$d.Name) -Force } } catch {} } }
}
Stop-ByPath $ei
if (-not $KeepTemp) { try { Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
if ($fail -gt 0) { exit 1 } else { exit 0 }
