# 뒤에서 조용히 실행되는 업데이트 확인·받기 작업 (창 없음).  Launch.ps1이 띄웁니다.
param([string]$Root, [switch]$AllowDev)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = $PSScriptRoot }
. (Join-Path $PSScriptRoot 'Updater.Config.ps1')
. (Join-Path $PSScriptRoot 'Updater.ps1')
$ctx = New-UpdContext -Root $Root -AllowDev:($AllowDev -or ($env:UPDATER_ALLOW_DEV -eq '1'))
try { Invoke-UpdCheck $ctx | Out-Null }
catch { Write-UpdLog $ctx ('작업 오류: ' + $_.Exception.Message) }
