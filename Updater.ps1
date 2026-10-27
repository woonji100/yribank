# ─────────────────────────────────────────────────────────────
#  Updater.ps1  —  GitHub 비공개 저장소 기반 자동 업데이트 (핵심 함수 모음)
#  Windows PowerShell 5.1 / PowerShell 7 호환.  다른 스크립트에서 점(.)으로 불러 씁니다.
#     . "$PSScriptRoot\Updater.Config.ps1"
#     . "$PSScriptRoot\Updater.ps1"
# ─────────────────────────────────────────────────────────────
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch {}
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:UpdToken = ''

# 항상 보호되는 파일 (설정과 상관없이)
$script:UpdAlwaysPreserve = @('installed.json', 'update-check.json', 'update.log', 'start.log', 'config/update.secret.json', '.update/*')

# ───────── 기본 도구 ─────────
function New-UpdContext {
    param([string]$Root, [switch]$AllowDev)
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $st = Join-Path $r '.update'
    [pscustomobject]@{
        Root = $r; State = $st; AllowDev = [bool]$AllowDev
        Installed = Join-Path $r 'installed.json'
        Check     = Join-Path $r 'update-check.json'
        Secret    = Join-Path (Join-Path $r 'config') 'update.secret.json'
        Staged    = Join-Path $st 'staged.json'
        StagedDir = Join-Path $st 'staged'
        Lock      = Join-Path $st 'lock'
    }
}

function Get-UpdProp($o, [string]$name, $default = $null) {
    if ($null -ne $o -and $o.PSObject.Properties[$name]) { return $o.$name }
    return $default
}

# 로그·화면에 토큰이 새지 않게 가리기
function Protect-UpdText([string]$t) {
    if (-not $t) { return $t }
    $t = [regex]::Replace($t, '(github_pat_|ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_]+', '***')
    $t = [regex]::Replace($t, '(?i)(bearer\s+)\S+', '$1***')
    if ($script:UpdToken) { $t = $t.Replace($script:UpdToken, '***') }
    return $t
}

function Write-UpdLog($ctx, [string]$msg, [string]$file = 'update.log') {
    try {
        $p = Join-Path $ctx.Root $file
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -gt 512KB)) {
            $old = [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)
            [IO.File]::WriteAllLines($p, ($old | Select-Object -Last 200), $script:Utf8)
        }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + (Protect-UpdText $msg) + "`r`n"
        [IO.File]::AppendAllText($p, $line, $script:Utf8)
    } catch {}
}

function Read-UpdJson([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $t = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        return ($t | ConvertFrom-Json)
    } catch { return $null }
}

function Write-UpdJson([string]$path, $obj) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Depth 8), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function New-UpdFail([string]$code, [string]$text) {
    $e = New-Object System.Exception($text)
    $e.Data['code'] = $code
    return $e
}

function Test-UpdMatch([string]$rel, [string[]]$patterns) {
    $r = $rel.Replace('\', '/')
    foreach ($p in $patterns) { if ($r -like $p) { return $true } }
    return $false
}

function Get-UpdPreserve { return @($script:UpdAlwaysPreserve) + @($script:UpdApp.Preserve) }

# PowerShell 7은 JSON 안의 날짜 글자를 날짜 값으로 바꿔 버리므로, 항상 ISO 글자로 되돌려 씀
function ConvertTo-UpdDateStr($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [DateTime]) { return $v.ToUniversalTime().ToString('o') }
    if ($v -is [DateTimeOffset]) { return $v.UtcDateTime.ToString('o') }
    return [string]$v
}

function Get-UpdFirstLine([string]$m) {
    if (-not $m) { return '' }
    $l = ($m -split "`r?`n")[0].Trim()
    if ($l.Length -gt 200) { $l = $l.Substring(0, 200) }
    return $l
}

function Get-UpdFileHash([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

# 한 번에 한 곳에서만 확인/적용하도록 잠그기 (프로세스가 죽으면 OS가 자동으로 풀어 줌)
function Enter-UpdLock($ctx, [int]$waitMs = 0) {
    if (-not (Test-Path -LiteralPath $ctx.State)) { New-Item -ItemType Directory -Force -Path $ctx.State | Out-Null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return (New-Object IO.FileStream($ctx.Lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 16, [IO.FileOptions]::DeleteOnClose)) }
        catch { Start-Sleep -Milliseconds 150 }
    } while ($sw.ElapsedMilliseconds -lt $waitMs)
    return $null
}
function Test-UpdLockHeld($ctx) {
    $l = Enter-UpdLock $ctx 0
    if ($l) { $l.Dispose(); return $false }
    return $true
}

# ───────── 설정(토큰) 읽기 ─────────
function Get-UpdConfig($ctx) {
    $u = Get-UpdProp (Read-UpdJson $ctx.Secret) 'update'
    if (-not $u) { return $null }
    $repo = [string](Get-UpdProp $u 'repo' ''); $branch = [string](Get-UpdProp $u 'branch' 'main'); $token = [string](Get-UpdProp $u 'token' '')
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return $null }
    if ($branch -notmatch '^[A-Za-z0-9_./-]+$') { return $null }
    if (-not $token) { return $null }
    $script:UpdToken = $token
    $api = 'https://api.github.com'
    if ($env:UPDATER_API_BASE -match '^http://127\.0\.0\.1:\d+$') { $api = $env:UPDATER_API_BASE }   # 시험용(내 PC 안에서만)
    return [pscustomobject]@{ Repo = $repo; Branch = $branch; Token = $token; Api = $api }
}

# ───────── GitHub 호출 ─────────
function Invoke-UpdHttp($cfg, [string]$url, [string]$outFile) {
    $h = @{ 'Authorization' = "Bearer $($cfg.Token)"; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'UpdaterKit/1.0' }
    $ProgressPreference = 'SilentlyContinue'
    if ($outFile) {
        Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -OutFile $outFile -TimeoutSec 300 | Out-Null
        return $null
    }
    $r = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 30
    $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    return ($txt | ConvertFrom-Json)
}

# 예외 → { state, code, text }
function ConvertTo-UpdFail($ex) {
    $c = $null; try { $c = $ex.Data['code'] } catch {}
    if ($c) { return @{ state = 'error'; code = [string]$c; text = (Protect-UpdText $ex.Message) } }
    $http = 0
    try { if ($ex.Response) { $http = [int]$ex.Response.StatusCode } } catch {}
    switch ($http) {
        401 { return @{ state = 'error'; code = '401'; text = '토큰이 만료되었거나 올바르지 않습니다(401). 관리자에게 새 토큰을 요청하세요.' } }
        403 { return @{ state = 'error'; code = '403'; text = '토큰에 권한이 없거나 GitHub 사용 한도를 넘었습니다(403). 잠시 뒤 다시 시도하고, 계속되면 관리자에게 문의하세요.' } }
        404 { return @{ state = 'error'; code = '404'; text = '저장소를 찾을 수 없거나 접근 권한이 없습니다(404). 저장소 이름·브랜치·토큰의 저장소 권한을 확인하세요.' } }
    }
    if ($http -ge 400) { return @{ state = 'error'; code = [string]$http; text = "GitHub가 오류를 돌려주었습니다($http). 잠시 뒤 다시 시도하세요." } }
    $tn = $ex.GetType().FullName
    if ($ex -is [Net.WebException] -or $tn -match 'HttpRequestException|TaskCanceled|SocketException|OperationCanceled|Timeout') {
        return @{ state = 'offline'; code = 'offline'; text = '인터넷에 연결되지 않아 업데이트를 확인하지 못했습니다.' }
    }
    if ($tn -match 'IOException|UnauthorizedAccess') { return @{ state = 'error'; code = 'io'; text = '파일을 저장하지 못했습니다: ' + (Protect-UpdText $ex.Message) } }
    return @{ state = 'error'; code = 'unknown'; text = '알 수 없는 오류: ' + (Protect-UpdText $ex.Message) }
}

# ───────── 설치 상태 ─────────
function Get-UpdInstalled($ctx) { return (Read-UpdJson $ctx.Installed) }

function Test-UpdDev($ctx) {
    if (Test-Path -LiteralPath (Join-Path $ctx.Root '.git')) { return $true }       # 개발 폴더(git 저장소)
    $inst = [string]$script:UpdApp.InstallDir
    if (-not $inst) { return $true }
    $inst = [IO.Path]::GetFullPath($inst).TrimEnd('\', '/')
    return -not ($ctx.Root -ieq $inst)                                              # 설치 위치가 아니면 개발 실행으로 봄
}

function Save-UpdCheck($ctx, [hashtable]$h) {
    $o = [ordered]@{ state = ''; checkedAt = ''; startedAt = ''; code = ''; text = ''; latest = $null; note = '' }
    foreach ($k in $h.Keys) { $o[$k] = $h[$k] }
    if (-not $o['checkedAt'] -and $o['state'] -ne 'checking') { $o['checkedAt'] = (Get-Date).ToString('o') }
    Write-UpdJson $ctx.Check $o
    return $o
}

function Clear-UpdStaged($ctx) {
    try { if (Test-Path -LiteralPath $ctx.StagedDir) { Remove-Item -LiteralPath $ctx.StagedDir -Recurse -Force } } catch {}
    try { if (Test-Path -LiteralPath $ctx.Staged) { Remove-Item -LiteralPath $ctx.Staged -Force } } catch {}
}

# 받아 둔 새 버전이 온전한지 (파일 수·해시)
function Test-UpdStagedOk($ctx, $st) {
    if (-not $st -or -not $st.sha -or -not $st.files) { return $false }
    $dir = Join-Path $ctx.StagedDir ([string]$st.sha)
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    foreach ($f in @($st.files)) {
        $p = Join-Path $dir ([string]$f.path)
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $p).Length -ne [int64]$f.size) { return $false }
        if ((Get-UpdFileHash $p) -ne [string]$f.sha256) { return $false }
    }
    return $true
}

# ───────── 압축 풀기 (경로 탈출 방지) ─────────
function Expand-UpdZip([string]$zipPath, [string]$dest) {
    $z = $null
    try { $z = [IO.Compression.ZipFile]::OpenRead($zipPath) }
    catch { throw (New-UpdFail 'zip' '받은 압축 파일이 깨져 있어 버렸습니다. 기존 버전을 그대로 씁니다.') }
    try {
        $rootFull = [IO.Path]::GetFullPath($dest).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $excl = @($script:UpdApp.Exclude)
        $count = 0
        foreach ($e in $z.Entries) {
            $name = $e.FullName
            if ($name.EndsWith('/')) { continue }
            $i = $name.IndexOf('/'); if ($i -lt 0) { continue }          # GitHub zip은 맨 위에 '저장소-커밋' 폴더가 있음
            $rel = $name.Substring($i + 1); if (-not $rel) { continue }
            if ($rel -match '(^|/)\.\.(/|$)' -or $rel.StartsWith('/') -or $rel.Contains(':') -or $rel.Contains('\')) {
                throw (New-UpdFail 'zip' '압축 파일에 안전하지 않은 경로가 있어 버렸습니다. 기존 버전을 그대로 씁니다.')
            }
            if (Test-UpdMatch $rel $excl) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $dest $rel))
            if (-not $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw (New-UpdFail 'zip' '압축 파일에 안전하지 않은 경로가 있어 버렸습니다. 기존 버전을 그대로 씁니다.')
            }
            $td = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Force -Path $td | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $count++
        }
        if ($count -eq 0) { throw (New-UpdFail 'zip' '받은 압축 파일이 비어 있어 버렸습니다. 기존 버전을 그대로 씁니다.') }
    } finally { $z.Dispose() }
}

# 받아서 "받아 둔 새 버전(staged)"으로 표시 — 바꿔 끼우지는 않음
function Save-UpdStage($ctx, $cfg, $latest) {
    $dl = Join-Path $ctx.State 'dl'; $tmp = Join-Path $ctx.State 'staging'
    foreach ($d in @($dl, $tmp)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } ; New-Item -ItemType Directory -Force -Path $d | Out-Null }
    try {
        $zip = Join-Path $dl ($latest.sha + '.zip')
        Invoke-UpdHttp $cfg "$($cfg.Api)/repos/$($cfg.Repo)/zipball/$($latest.sha)" $zip | Out-Null
        if (-not (Test-Path -LiteralPath $zip) -or (Get-Item -LiteralPath $zip).Length -lt 22) { throw (New-UpdFail 'zip' '새 버전을 받지 못했습니다. 기존 버전을 그대로 씁니다.') }
        Expand-UpdZip $zip $tmp
        $tl = $tmp.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $files = @()
        foreach ($f in (Get-ChildItem -LiteralPath $tmp -Recurse -File)) {
            $rel = $f.FullName.Substring($tl.Length).Replace('\', '/')
            $files += @{ path = $rel; size = $f.Length; sha256 = (Get-UpdFileHash $f.FullName) }
        }
        if (-not $files.Count) { throw (New-UpdFail 'zip' '받은 새 버전에 파일이 없어 버렸습니다.') }
        Clear-UpdStaged $ctx
        New-Item -ItemType Directory -Force -Path $ctx.StagedDir | Out-Null
        Move-Item -LiteralPath $tmp -Destination (Join-Path $ctx.StagedDir $latest.sha)
        Write-UpdJson $ctx.Staged ([ordered]@{ sha = $latest.sha; date = $latest.date; message = $latest.message; stagedAt = (Get-Date).ToString('o'); files = $files })   # 맨 마지막에 기록 = 완성 표시
    } finally {
        foreach ($d in @($dl, $tmp)) { try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } } catch {} }
    }
}

# ───────── ② 확인 + ③ 받아 두기 (뒤에서 실행) ─────────
function Invoke-UpdCheck($ctx) {
    if (-not $ctx.AllowDev -and (Test-UpdDev $ctx)) {
        return (Save-UpdCheck $ctx @{ state = 'skipped'; code = 'dev'; text = '개발 폴더에서 실행 중이라 업데이트를 확인하지 않습니다.' })
    }
    $lock = Enter-UpdLock $ctx 0
    if (-not $lock) { return [ordered]@{ state = 'busy' } }
    $started = (Get-Date).ToString('o')
    try {
        $cfg = Get-UpdConfig $ctx
        if (-not $cfg) {
            Write-UpdLog $ctx '설정 없음: config/update.secret.json'
            return (Save-UpdCheck $ctx @{ state = 'error'; code = 'config'; text = '업데이트 설정(config/update.secret.json)이 없거나 형식이 올바르지 않습니다.' })
        }
        Save-UpdCheck $ctx @{ state = 'checking'; startedAt = $started } | Out-Null
        $inst = Get-UpdInstalled $ctx
        $c = Invoke-UpdHttp $cfg "$($cfg.Api)/repos/$($cfg.Repo)/commits/$($cfg.Branch)" $null
        $sha = [string](Get-UpdProp $c 'sha' '')
        if ($sha -notmatch '^[0-9a-f]{40}$') { throw (New-UpdFail 'api' 'GitHub 응답을 이해하지 못했습니다.') }
        $cm = Get-UpdProp $c 'commit'
        $latest = [ordered]@{ sha = $sha; date = (ConvertTo-UpdDateStr (Get-UpdProp (Get-UpdProp $cm 'committer') 'date' '')); message = (Get-UpdFirstLine ([string](Get-UpdProp $cm 'message' ''))) }
        $instSha = [string](Get-UpdProp $inst 'sha' ''); $instDate = (ConvertTo-UpdDateStr (Get-UpdProp $inst 'date' ''))

        # 같은 번호 → 할 일 없음
        if ($instSha -and $instSha -eq $sha) {
            Clear-UpdStaged $ctx
            Write-UpdLog $ctx "확인: 최신 ($($sha.Substring(0,7)))"
            return (Save-UpdCheck $ctx @{ state = 'uptodate'; code = 'same'; text = '이미 최신입니다.'; latest = $latest })
        }
        # 설치본이 GitHub보다 새것이면 옛 버전으로 되돌아가지 않음
        if ($instDate -and $latest.date) {
            $a = [DateTimeOffset]::Parse($instDate, [Globalization.CultureInfo]::InvariantCulture); $b = [DateTimeOffset]::Parse($latest.date, [Globalization.CultureInfo]::InvariantCulture)
            if ($b -lt $a) {
                Clear-UpdStaged $ctx
                Write-UpdLog $ctx "확인: 이 PC의 버전이 GitHub보다 새것이라 유지 (GitHub $($sha.Substring(0,7)))"
                return (Save-UpdCheck $ctx @{ state = 'uptodate'; code = 'newer-local'; text = '이 PC의 버전이 GitHub 것보다 새것이라 그대로 둡니다.'; latest = $latest })
            }
        }
        # 이미 같은 버전을 받아 둔 상태면 다시 받지 않음
        $st = Read-UpdJson $ctx.Staged
        if ($st -and [string]$st.sha -eq $sha -and (Test-UpdStagedOk $ctx $st)) {
            return (Save-UpdCheck $ctx @{ state = 'staged'; code = 'staged'; text = '새 버전을 받아 두었습니다.'; latest = $latest })
        }
        Clear-UpdStaged $ctx
        Save-UpdStage $ctx $cfg $latest
        Write-UpdLog $ctx "받아 둠: $($sha.Substring(0,7)) — $($latest.message)"
        return (Save-UpdCheck $ctx @{ state = 'staged'; code = 'staged'; text = '새 버전을 받아 두었습니다.'; latest = $latest })
    } catch {
        $f = ConvertTo-UpdFail $_.Exception
        Write-UpdLog $ctx ("확인 실패: [" + $f.code + "] " + $f.text)
        $prev = Read-UpdJson $ctx.Staged   # 받아 둔 게 온전하면 다음 실행 때 쓸 수 있도록 유지
        return (Save-UpdCheck $ctx @{ state = $f.state; code = $f.code; text = $f.text; note = $(if ($prev) { 'staged-kept' } else { '' }) })
    } finally { if ($lock) { $lock.Dispose() } }
}

# ───────── ④ 바꿔 끼우기 (켤 때, 화면 열기 전에) ─────────
function Merge-UpdToken([string]$oldFile, [string]$newFile) {
    # 새 설정 파일에 update.token이 없으면 이 PC의 기존 토큰을 이어 붙임
    $o = Get-UpdProp (Read-UpdJson $oldFile) 'update'; $nj = Read-UpdJson $newFile
    if (-not $o -or -not (Get-UpdProp $o 'token') -or -not $nj) { return }
    $n = Get-UpdProp $nj 'update'
    if ($n -and (Get-UpdProp $n 'token')) { return }
    if (-not $n) { $nj | Add-Member -NotePropertyName update -NotePropertyValue ([pscustomobject]@{}) -Force; $n = $nj.update }
    foreach ($k in 'repo', 'branch', 'token') {
        $v = Get-UpdProp $o $k
        if ($v -and -not (Get-UpdProp $n $k)) { $n | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force }
    }
    Write-UpdJson $newFile $nj
}

function Invoke-UpdApply($ctx) {
    $none = @{ applied = $false }
    if (-not $ctx.AllowDev -and (Test-UpdDev $ctx)) { return $none }
    if (-not (Test-Path -LiteralPath $ctx.Staged)) { return $none }
    $lock = Enter-UpdLock $ctx 3000
    if (-not $lock) { return $none }     # 다른 곳에서 확인 중 — 이번엔 건너뛰고 다음에 적용
    $bk = $null; $actions = New-Object System.Collections.ArrayList
    try {
        $st = Read-UpdJson $ctx.Staged
        if (-not (Test-UpdStagedOk $ctx $st)) {
            Write-UpdLog $ctx '받아 둔 파일이 온전하지 않아 버립니다 (기존 버전 유지)'
            Clear-UpdStaged $ctx
            Save-UpdCheck $ctx @{ state = 'error'; code = 'staged-bad'; text = '받아 둔 새 버전이 온전하지 않아 버렸습니다. 다시 확인합니다.' } | Out-Null
            return $none
        }
        $inst = Get-UpdInstalled $ctx
        $instSha = [string](Get-UpdProp $inst 'sha' ''); $instDate = (ConvertTo-UpdDateStr (Get-UpdProp $inst 'date' ''))
        $stSha = [string]$st.sha
        $newer = $false
        $stDate = (ConvertTo-UpdDateStr $st.date)
        if ($instDate -and $stDate) { $newer = ([DateTimeOffset]::Parse($instDate, [Globalization.CultureInfo]::InvariantCulture) -gt [DateTimeOffset]::Parse($stDate, [Globalization.CultureInfo]::InvariantCulture)) }
        if ($instSha -eq $stSha -or $newer) { Clear-UpdStaged $ctx; return $none }

        $pres = Get-UpdPreserve
        $src = Join-Path $ctx.StagedDir $stSha
        $bk = Join-Path (Join-Path $ctx.State 'backup') (Get-Date -Format 'yyyyMMdd-HHmmss')
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        $owned = New-Object System.Collections.ArrayList; $n = 0; $changedJson = @()

        foreach ($f in @($st.files)) {
            $rel = [string]$f.path; $dst = Join-Path $ctx.Root $rel; $from = Join-Path $src $rel
            $isPres = Test-UpdMatch $rel $pres
            $exists = Test-Path -LiteralPath $dst -PathType Leaf
            if ($isPres -and $exists) { continue }                       # 사용자 파일: 그대로
            if (-not $isPres) { [void]$owned.Add($rel) }
            if ($exists) {
                if ((Get-Item -LiteralPath $dst).Length -eq [int64]$f.size -and (Get-UpdFileHash $dst) -eq [string]$f.sha256) { continue }   # 똑같으면 건드리지 않음
                $b = Join-Path $bk $rel; $bd = Split-Path $b -Parent
                if (-not (Test-Path -LiteralPath $bd)) { New-Item -ItemType Directory -Force -Path $bd | Out-Null }
                Copy-Item -LiteralPath $dst -Destination $b -Force
                [void]$actions.Add(@{ rel = $rel; kind = 'replaced' })
                if ($rel -like '*.json') { $changedJson += $rel }
            } else { [void]$actions.Add(@{ rel = $rel; kind = 'created' }) }
            $dd = Split-Path $dst -Parent
            if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
            Copy-Item -LiteralPath $from -Destination $dst -Force
            $n++
            if ($global:UpdTestFailAt -and $n -ge [int]$global:UpdTestFailAt) { throw (New-UpdFail 'apply' '시험용 오류') }
        }
        # 새 버전에서 없어진 프로그램 파일 정리 (이전에 우리가 설치한 것만, 사용자 파일은 절대 안 지움)
        foreach ($old in @(Get-UpdProp $inst 'files' @())) {
            $rel = [string]$old
            if ($owned -contains $rel -or (Test-UpdMatch $rel $pres)) { continue }
            $dst = Join-Path $ctx.Root $rel
            if (Test-Path -LiteralPath $dst -PathType Leaf) {
                $b = Join-Path $bk $rel; $bd = Split-Path $b -Parent
                if (-not (Test-Path -LiteralPath $bd)) { New-Item -ItemType Directory -Force -Path $bd | Out-Null }
                Copy-Item -LiteralPath $dst -Destination $b -Force
                [void]$actions.Add(@{ rel = $rel; kind = 'deleted' })
                Remove-Item -LiteralPath $dst -Force
            }
        }
        # 바뀐 설정(json)에 이 PC의 토큰 이어 붙이기
        foreach ($rel in $changedJson) { Merge-UpdToken (Join-Path $bk $rel) (Join-Path $ctx.Root $rel) }

        Write-UpdJson $ctx.Installed ([ordered]@{ sha = $stSha; date = $stDate; message = [string]$st.message; appliedAt = (Get-Date).ToString('o'); repo = [string](Get-UpdProp $inst 'repo' ''); branch = [string](Get-UpdProp $inst 'branch' ''); files = @($owned) })
        Clear-UpdStaged $ctx
        # 백업은 가장 최근 1개만 남김
        $bkRoot = Split-Path $bk -Parent
        foreach ($d in (Get-ChildItem -LiteralPath $bkRoot -Directory | Sort-Object Name -Descending | Select-Object -Skip 1)) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force } catch {} }
        Write-UpdLog $ctx ("적용: $($stSha.Substring(0,7)) — $($st.message) (파일 $($n)개 바꿈)") 'start.log'
        Write-UpdLog $ctx ("적용: $($stSha.Substring(0,7)) — $($st.message)")
        Save-UpdCheck $ctx @{ state = 'uptodate'; code = 'applied'; text = '새 버전이 적용되었습니다.'; latest = @{ sha = $stSha; date = $stDate; message = [string]$st.message } } | Out-Null
        return @{ applied = $true; sha = $stSha; message = [string]$st.message }
    } catch {
        $f = ConvertTo-UpdFail $_.Exception
        # 되돌리기
        for ($i = $actions.Count - 1; $i -ge 0; $i--) {
            $a = $actions[$i]; $dst = Join-Path $ctx.Root $a.rel
            try {
                if ($a.kind -eq 'created') { if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force } }
                else { Copy-Item -LiteralPath (Join-Path $bk $a.rel) -Destination $dst -Force }
            } catch {}
        }
        Write-UpdLog $ctx ("적용 실패 → 이전 상태로 되돌림: [" + $f.code + "] " + $f.text) 'start.log'
        Write-UpdLog $ctx ("적용 실패 → 이전 상태로 되돌림: [" + $f.code + "] " + $f.text)
        Clear-UpdStaged $ctx
        Save-UpdCheck $ctx @{ state = 'error'; code = 'apply'; text = '업데이트를 적용하지 못해 이전 상태로 되돌렸습니다. 기존 버전으로 계속 씁니다.' } | Out-Null
        return @{ applied = $false; failed = $true }
    } finally { if ($lock) { $lock.Dispose() } }
}

# ───────── 화면용 상태 ─────────
function Get-UpdStatus($ctx) {
    $inst = Get-UpdInstalled $ctx; $chk = Read-UpdJson $ctx.Check; $st = Read-UpdJson $ctx.Staged
    if ($chk -and [string]$chk.state -eq 'checking') {      # 확인 중이라고 적혀 있는데 실제로는 멈춘 경우
        $age = 999
        try { $age = ((Get-Date) - [DateTimeOffset]::Parse((ConvertTo-UpdDateStr $chk.startedAt), [Globalization.CultureInfo]::InvariantCulture).LocalDateTime).TotalSeconds } catch {}
        if ($age -gt 15 -and -not (Test-UpdLockHeld $ctx)) { $chk = [pscustomobject]@{ state = 'error'; code = 'aborted'; text = '업데이트 확인이 중간에 멈췄습니다. 다시 시도해 주세요.'; checkedAt = (Get-Date).ToString('o') } }
    }
    $short = { param($s) if ($s) { ([string]$s).Substring(0, [Math]::Min(7, ([string]$s).Length)) } else { '' } }
    $stagedOut = $null
    if ($st -and $st.sha) { $stagedOut = [ordered]@{ sha = [string]$st.sha; short = (& $short $st.sha); date = (ConvertTo-UpdDateStr $st.date); message = [string]$st.message } }
    return [ordered]@{
        app = [string]$script:UpdApp.Name; dev = [bool](Test-UpdDev $ctx)
        current = [ordered]@{ sha = [string](Get-UpdProp $inst 'sha' ''); short = (& $short (Get-UpdProp $inst 'sha' '')); date = (ConvertTo-UpdDateStr (Get-UpdProp $inst 'date' '')); message = [string](Get-UpdProp $inst 'message' '') }
        check = $chk; staged = $stagedOut
    }
}

# ───────── 프로세스 도우미 ─────────
function Get-UpdPsPath { return (Get-Process -Id $PID).Path }
function Test-UpdWindows { return ($PSVersionTable.Platform -ne 'Unix') }

function Start-UpdWorker($ctx) {
    $args1 = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (Test-UpdWindows) { $args1 += @('-WindowStyle', 'Hidden') }
    $args1 += @('-File', ('"' + (Join-Path $ctx.Root 'Update-Worker.ps1') + '"'), '-Root', ('"' + $ctx.Root + '"'))
    if (Test-UpdWindows) { Start-Process -FilePath (Get-UpdPsPath) -ArgumentList $args1 -WindowStyle Hidden | Out-Null }
    else { Start-Process -FilePath (Get-UpdPsPath) -ArgumentList $args1 | Out-Null }
}

# 지금 프로세스가 끝나기를 기다렸다가 Launch.ps1을 다시 켜는 도우미를 띄움
function Start-UpdRelaunch($ctx, [string]$launcher, [string[]]$extra = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (Test-UpdWindows) { $a += @('-WindowStyle', 'Hidden') }
    $a += @('-File', ('"' + $launcher + '"'), '-WaitPid', $PID) + $extra
    if (Test-UpdWindows) { Start-Process -FilePath (Get-UpdPsPath) -ArgumentList $a -WindowStyle Hidden | Out-Null }
    else { Start-Process -FilePath (Get-UpdPsPath) -ArgumentList $a | Out-Null }
}
