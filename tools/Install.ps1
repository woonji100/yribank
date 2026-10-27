# 처음 한 번 설치: 이 폴더의 파일을 설치 위치로 복사하고 바탕화면·시작 메뉴 바로가기를 만듭니다.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$src = $PSScriptRoot
. (Join-Path $src 'Updater.Config.ps1')
. (Join-Path $src 'Updater.ps1')
$dest = [string]$script:UpdApp.InstallDir
if (-not $dest) { throw '설치 위치를 알 수 없습니다 (LOCALAPPDATA).' }
$name = $script:UpdApp.Name

# 이미 더 새 버전이 설치되어 있으면 덮어쓰지 않음
$newInst = Read-UpdJson (Join-Path $src 'installed.json'); $oldInst = Read-UpdJson (Join-Path $dest 'installed.json')
if ($newInst -and $oldInst -and $newInst.date -and $oldInst.date) {
    $a = [DateTimeOffset]::Parse((ConvertTo-UpdDateStr $oldInst.date), [Globalization.CultureInfo]::InvariantCulture); $b = [DateTimeOffset]::Parse((ConvertTo-UpdDateStr $newInst.date), [Globalization.CultureInfo]::InvariantCulture)
    if ($a -gt $b) { Write-Host "이미 더 새 버전이 설치되어 있어 그대로 둡니다. ($dest)"; exit 0 }
}
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$pres = Get-UpdPreserve
$sl = $src.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$n = 0
foreach ($f in (Get-ChildItem -LiteralPath $src -Recurse -File)) {
    $rel = $f.FullName.Substring($sl.Length).Replace('\', '/')
    if ($rel -ieq 'Install.ps1' -or $rel -ieq 'Install.cmd') { continue }
    $to = Join-Path $dest $rel
    $isPres = Test-UpdMatch $rel $pres
    # 내 데이터·설정은 그대로. 단, installed.json(버전 기록)과 토큰 파일은 새 zip(관리자가 발급)의 것으로 갱신 — 토큰이 바뀌었을 때 다시 설치하면 새 토큰이 들어감
    if ($isPres -and (Test-Path -LiteralPath $to) -and $rel -ne 'installed.json' -and $rel -ne 'config/update.secret.json') { continue }
    $td = Split-Path $to -Parent
    if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Force -Path $td | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $to -Force; $n++
}
try { Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File } catch {}

# 바로가기
$launch = Join-Path $dest 'Launch.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    $ws = New-Object -ComObject WScript.Shell
    $dirs = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) ''))
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $l = $ws.CreateShortcut((Join-Path $d ($name + '.lnk')))
        $l.TargetPath = $psExe
        $l.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launch + '"'
        $l.WorkingDirectory = $dest
        $l.Save()
    }
} catch { Write-Warning ('바로가기를 만들지 못했습니다: ' + $_.Exception.Message) }

Write-Host ''
Write-Host "설치했습니다: $dest  (파일 $($n)개)"
Write-Host "바탕화면의 「$name」 바로가기로 실행하세요. 이후 업데이트는 자동으로 받아 옵니다."
