# 시험용 가짜 GitHub API 서버 (내 PC 안에서만).  state.json 을 요청마다 읽어서 동작을 바꿉니다.
param([int]$Port, [string]$Dir)
$ErrorActionPreference = 'Stop'
$l = New-Object Net.HttpListener; $l.Prefixes.Add("http://127.0.0.1:$Port/"); $l.Start()
function Send($res, [int]$code, [byte[]]$body, [string]$type = 'application/json; charset=utf-8') {
    $res.StatusCode = $code; $res.ContentType = $type; $res.ContentLength64 = $body.Length
    $res.OutputStream.Write($body, 0, $body.Length); $res.Close()
}
$enc = New-Object Text.UTF8Encoding($false)
while ($true) {
    $c = $l.GetContext(); $req = $c.Request; $res = $c.Response
    try {
        $st = [IO.File]::ReadAllText((Join-Path $Dir 'state.json'), $enc) | ConvertFrom-Json
        $path = $req.Url.AbsolutePath; $auth = $req.Headers['Authorization']
        [IO.File]::AppendAllText((Join-Path $Dir 'requests.log'), ("{0} {1} auth={2}`n" -f $req.HttpMethod, $path, [bool]$auth), $enc)
        if ($path -eq "/repos/$($st.repo)/commits/$($st.branch)") {
            if ($st.delay) { Start-Sleep -Seconds ([int]$st.delay) }
            if ($st.mode -eq '401' -or $auth -ne "Bearer $($st.token)") { Send $res 401 $enc.GetBytes('{"message":"Bad credentials"}'); continue }
            if ($st.mode -eq '403') { Send $res 403 $enc.GetBytes('{"message":"rate limit"}'); continue }
            if ($st.mode -eq '404') { Send $res 404 $enc.GetBytes('{"message":"Not Found"}'); continue }
            $o = @{ sha = $st.head.sha; commit = @{ message = $st.head.message; committer = @{ date = $st.head.date } } }
            Send $res 200 $enc.GetBytes((ConvertTo-Json -InputObject $o -Depth 6)); continue
        }
        if ($path -like "/repos/$($st.repo)/zipball/*") {
            if ($auth -ne "Bearer $($st.token)") { Send $res 401 $enc.GetBytes('{}'); continue }
            $sha = $path.Split('/')[-1]
            $res.StatusCode = 302; $res.RedirectLocation = "http://127.0.0.1:$Port/codeload/$sha.zip"; $res.Close(); continue
        }
        if ($path -like '/codeload/*') {
            if ($st.mode -eq 'corrupt') { Send $res 200 $enc.GetBytes('this is not a zip file at all, just text ....') 'application/zip'; continue }
            Send $res 200 ([IO.File]::ReadAllBytes([string]$st.zip)) 'application/zip'; continue
        }
        Send $res 404 $enc.GetBytes('{}')
    } catch { try { Send $res 500 $enc.GetBytes('{}') } catch {} }
}
