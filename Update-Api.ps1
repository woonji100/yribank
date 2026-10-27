# 웹 화면용 업데이트 API (HttpListener 요청 한 건을 처리).  Launch.ps1의 요청 루프에서 부릅니다.
#   처리했으면 $true, 업데이트와 상관없는 요청이면 $false 를 돌려줍니다.
function Send-UpdJson($res, $obj, [int]$code = 200) {
    $b = $script:Utf8.GetBytes((ConvertTo-Json -InputObject $obj -Depth 8))
    $res.StatusCode = $code; $res.ContentType = 'application/json; charset=utf-8'
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.OutputStream.Write($b, 0, $b.Length); $res.Close()
}

function Invoke-UpdApiRequest {
    param($ctx, $context, [string]$Launcher, [scriptblock]$OnRestart)
    $req = $context.Request; $res = $context.Response; $path = $req.Url.AbsolutePath
    if (-not ($path.StartsWith('/api/update/') -or $path -eq '/update-ui.js')) { return $false }
    try {
        # 같은 PC의 화면에서 온 요청만 (다른 웹사이트가 몰래 누르는 것 방지)
        $hostName = $req.Url.Host
        if ($hostName -ne 'localhost' -and $hostName -ne '127.0.0.1') { Send-UpdJson $res @{ error = 'host' } 403; return $true }
        if ($path -eq '/update-ui.js') {
            $f = Join-Path (Join-Path $ctx.Root 'web') 'update-ui.js'
            $b = [IO.File]::ReadAllBytes($f); $res.ContentType = 'application/javascript; charset=utf-8'
            $res.OutputStream.Write($b, 0, $b.Length); $res.Close(); return $true
        }
        if ($req.HttpMethod -eq 'POST') {
            $origin = $req.Headers['Origin']
            if ($origin -and $origin -notmatch '^http://(localhost|127\.0\.0\.1)(:\d+)?$') { Send-UpdJson $res @{ error = 'origin' } 403; return $true }
            if ($req.Headers['X-Requested-With'] -ne 'update-ui') { Send-UpdJson $res @{ error = 'header' } 403; return $true }
        }
        switch ($path) {
            '/api/update/status' { Send-UpdJson $res (Get-UpdStatus $ctx) }
            '/api/update/check' {
                if ($req.HttpMethod -ne 'POST') { Send-UpdJson $res @{ error = 'method' } 405; break }
                if ((Test-UpdDev $ctx) -and -not $ctx.AllowDev) { Send-UpdJson $res @{ started = $false; dev = $true }; break }
                if (Test-UpdLockHeld $ctx) { Send-UpdJson $res @{ started = $false; busy = $true }; break }
                Save-UpdCheck $ctx @{ state = 'checking'; startedAt = (Get-Date).ToString('o') } | Out-Null
                Start-UpdWorker $ctx
                Send-UpdJson $res @{ started = $true }
            }
            '/api/update/restart' {
                if ($req.HttpMethod -ne 'POST') { Send-UpdJson $res @{ error = 'method' } 405; break }
                Send-UpdJson $res @{ ok = $true }
                if ($OnRestart) { & $OnRestart }
            }
            default { Send-UpdJson $res @{ error = 'not found' } 404 }
        }
    } catch {
        try { Write-UpdLog $ctx ('API 오류: ' + $_.Exception.Message); Send-UpdJson $res @{ error = 'internal' } 500 } catch {}
    }
    return $true
}
