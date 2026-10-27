# ─────────────────────────────────────────────────────────────
#  Updater.Config.ps1  —  업데이트 기능 설정 (이 파일만 고치면 됩니다)
#  ※ 이 파일도 업데이트 때 새 버전으로 바뀝니다. 바꾼 내용은 저장소(git)에 올려 두세요.
# ─────────────────────────────────────────────────────────────
$script:UpdApp = @{
    # 화면·바로가기에 보이는 프로그램 이름
    Name       = '내프로그램'

    # 설치 폴더 이름: %LOCALAPPDATA%\<FolderName>  (영문·숫자 권장)
    FolderName = 'MyProgram'

    # ★ 업데이트가 절대 덮어쓰거나 지우지 않는 사용자 파일/폴더 (상대 경로, * 사용 가능)
    #   - 이미 PC에 있으면 그대로 두고, 아직 없을 때만 저장소의 기본 파일을 넣어 줍니다.
    #   - 아래 기본값 외에 항상 보호되는 것: installed.json, update-check.json, *.log,
    #     config/update.secret.json(토큰), .update 폴더
    Preserve   = @(
        'data/*',          # 사용자 데이터 폴더
        'settings.json',   # 사용자 설정
        '*.user.json'      # 이름이 ○○.user.json 인 파일
    )

    # 설치본에 넣지 않는 저장소 파일 (관리용 파일)
    Exclude    = @(
        '.git*', '.github/*', 'tools/*', 'tests/*', 'docs/*', 'README.md', 'ADMIN.md'
    )
}

# 설치 폴더 전체 경로 (시험용으로 UPDATER_INSTALL_DIR 환경변수가 있으면 그것을 씀)
if ($env:UPDATER_INSTALL_DIR) { $script:UpdApp.InstallDir = $env:UPDATER_INSTALL_DIR }
elseif ($env:LOCALAPPDATA)    { $script:UpdApp.InstallDir = Join-Path $env:LOCALAPPDATA $script:UpdApp.FolderName }
else                          { $script:UpdApp.InstallDir = '' }
