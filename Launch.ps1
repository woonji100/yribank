# ─────────────────────────────────────────────────────────────
#  Launch.ps1  —  시작 파일(예시).  바로가기가 이 파일을 실행합니다.
#  ★ 이미 쓰시는 시작 파일이 있으면, 아래 [UPDATE-1]~[UPDATE-4] 표시된 부분만 옮겨 넣으세요.
# ─────────────────────────────────────────────────────────────
param([int]$WaitPid = 0, [int]$Port = 8765, [switch]$NoBrowser, [switch]$NoApply)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
. (Join-Path $Root 'Updater.Config.ps1')
. (Join-Path $Root 'Updater.ps1')
. (Join-Path $Root 'Update-Api.ps1')
$ctx = New-UpdContext -Root $Root
$state = @{ Stop = $false }

# 다시 켜기로 시작된 경우: 이전 프로세스가 끝나길 기다림
if ($WaitPid) { try { (Get-Process -Id $WaitPid -ErrorAction Stop).WaitForExit(30000) | Out-Null } catch {} }

# [UPDATE-1] 화면을 열기 전에, 받아 둔 새 버전이 있으면 바꿔 끼움 (몇 초)
if (-not $NoApply) {
    $r = Invoke-UpdApply $ctx
    if ($r.applied) {                       # 시작 파일 자체가 바뀌었을 수 있으니 새 파일로 다시 시작
        $ex = @('-NoApply', '-Port', $Port); if ($NoBrowser) { $ex += '-NoBrowser' }
        Start-UpdRelaunch $ctx (Join-Path $Root 'Launch.ps1') $ex
        exit 0
    }
}
Write-UpdLog $ctx "시작 (포트 $Port)" 'start.log'

# ── 여기부터는 프로그램 본체(예시: 간단한 웹 서버) — 실제 프로그램 코드로 바꾸세요 ──
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }          # 창은 바로 띄움

# [UPDATE-2] 업데이트 확인은 뒤에서 따로 (켜는 속도에 영향 없음)
Start-UpdWorker $ctx

$web = Join-Path $Root 'web'
$restart = { $state.Stop = $true; Start-UpdRelaunch $ctx (Join-Path $Root 'Launch.ps1') @('-Port', $Port, '-NoBrowser') }
try {
    while (-not $state.Stop) {
        $t = $listener.GetContextAsync()
        while (-not $t.Wait(300)) { if ($state.Stop) { break } }
        if (-not $t.IsCompleted) { break }
        $c = $t.Result
        # [UPDATE-3] 업데이트 관련 요청(/api/update/*, /update-ui.js)은 여기서 처리
        if (Invoke-UpdApiRequest -ctx $ctx -context $c -Launcher (Join-Path $Root 'Launch.ps1') -OnRestart $restart) { continue }
        # 이 아래는 프로그램 자체 요청 (예시)
        $p = $c.Request.Url.AbsolutePath; if ($p -eq '/') { $p = '/index.html' }
        $f = Join-Path $web ($p.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and ([IO.Path]::GetFullPath($f)).StartsWith([IO.Path]::GetFullPath($web))) {
            $b = [IO.File]::ReadAllBytes($f); $c.Response.ContentType = 'text/html; charset=utf-8'
            $c.Response.OutputStream.Write($b, 0, $b.Length)
        } else { $c.Response.StatusCode = 404 }
        $c.Response.Close()
    }
} finally {
    # [UPDATE-4] 종료 시 포트를 확실히 닫아야 새로 켠 프로그램이 같은 포트를 씀
    try { $listener.Stop(); $listener.Close() } catch {}
}
