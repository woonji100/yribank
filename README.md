# GitHub 비공개 저장소 자동 업데이트 키트 (Windows PowerShell + 웹 화면)

켤 때 창은 바로 뜨고, 업데이트 확인·다운로드는 뒤에서 따로 합니다. 새 버전은 "받아 두기"만 하고, **다음에 켤 때 화면을 열기 전에** 몇 초 만에 바꿔 끼웁니다. 사용자 데이터·설정·토큰은 건드리지 않습니다.

## 들어 있는 파일
| 파일 | 역할 |
|---|---|
| `Updater.Config.ps1` | **고칠 곳**: 프로그램 이름, 설치 폴더 이름, 지킬 파일 목록 |
| `Updater.ps1` | 핵심: 커밋 확인 → zip 받기 → staged 표시 → 바꿔 끼우기 → 실패 시 되돌리기 |
| `Update-Worker.ps1` | 뒤에서 조용히 확인·받기를 하는 작업 (창 없음) |
| `Update-Api.ps1` | 웹 화면용 API (`/api/update/status`, `/check`, `/restart`) |
| `web/update-ui.js` | 알림 띠("새 버전을 받아 두었습니다 — [지금 다시 켜기]") + 설정 칸([지금 업데이트 확인]) |
| `web/index.html`, `Launch.ps1` | 붙이는 방법을 보여 주는 **예시** 화면/시작 파일 |
| `tools/Build-Release.ps1` | (관리자) 처음 설치용 zip 만들기 — 토큰이 이 zip 안에만 들어감 |
| `tools/Install.ps1` | zip 안에 들어가는 설치 스크립트 (복사 + 바탕화면 바로가기) |
| `tests/Run-Tests.ps1` | 가짜 GitHub 서버로 돌려 보는 시험 (실제 인터넷·토큰 불필요) |
| `.gitignore.sample` | 저장소에 올리면 안 되는 파일 목록 → 내 `.gitignore`에 추가 |
| `ADMIN.md`, `USER.md` | 관리자 절차, 사용자 안내 |

## 내 프로그램에 붙이는 순서
1. 위 파일들을 프로그램 저장소 루트에 복사합니다(`Launch.ps1`·`web/index.html`은 예시이므로 내 것이 있으면 복사하지 않습니다).
2. `Updater.Config.ps1`에서 `Name`, `FolderName`, `Preserve`(지킬 파일)를 내 프로그램에 맞게 고칩니다.
   - `Preserve`에 적은 파일은 **PC에 이미 있으면 절대 덮어쓰거나 지우지 않고**, 아직 없을 때만 저장소의 기본 파일을 넣어 줍니다. 기본값: `data/*`, `settings.json`, `*.user.json`.
   - 사용자 `.json`이 다른 위치·이름이면 여기에 추가하세요(예: `'config/mine.json'`).
3. 이미 쓰는 시작 파일(PowerShell)이 있으면 `Launch.ps1`의 **[UPDATE-1] ~ [UPDATE-4]** 표시된 4곳만 옮겨 넣습니다.
   - [UPDATE-1] 화면 열기 전: `Invoke-UpdApply` (받아 둔 새 버전 바꿔 끼우기)
   - [UPDATE-2] 화면을 연 뒤: `Start-UpdWorker` (뒤에서 확인)
   - [UPDATE-3] 요청 처리 루프: `Invoke-UpdApiRequest` (업데이트 API)
   - [UPDATE-4] 종료 때 `HttpListener`를 확실히 닫기 (다시 켤 때 같은 포트를 쓰므로)
   - 화면이 HttpListener 웹 서버가 아니면(예: 파일을 그냥 여는 방식) 알림 띠·버튼은 쓸 수 없고, 1~2번 동작만 켤 때 자동으로 됩니다.
4. 웹 화면에 두 줄을 넣습니다: `<script src="/update-ui.js"></script>` 와 설정 화면의 `<div id="update-settings"></div>`.
5. `.gitignore.sample` 내용을 `.gitignore`에 추가하고 commit·push → `ADMIN.md` 순서대로 배포합니다.

## 동작 요약
- **확인**: `GET /repos/{owner}/{repo}/commits/{branch}` → 설치본의 `installed.json` 커밋 번호와 같으면 아무것도 안 함.
- **받기**: 다르면 `GET .../zipball/{커밋번호}` → `.update\staged`에 풀고 파일별 SHA-256을 적은 `staged.json`을 **맨 마지막에** 기록(= 완성 표시). 이때는 바꿔 끼우지 않음.
- **적용**(다음에 켤 때, 화면 열기 전): 해시 재검증 → 바뀐 파일만 백업 후 복사 → 새 버전에서 없어진 *프로그램 파일*만 삭제 → `installed.json`에 커밋 번호·날짜·메시지 기록. 중간에 실패하면 전부 원래대로 되돌리고 받아 둔 것을 버림.
- 파일: `installed.json`(설치된 버전), `update-check.json`(마지막 확인 결과), `update.log`·`start.log`, `.update\`(받아 둔 새 버전·백업).

## 안전장치 (구현·시험됨)
- 인터넷/GitHub 불통 → 조용히 건너뜀 · 401/403/404 → 설정 화면에 원인 문구 · 로그·화면·오류 메시지에서 토큰 가림
- `.git` 폴더가 있거나 설치 위치가 아닌 곳에서 실행하면 업데이트하지 않음
- 설치본이 GitHub보다 새것(커밋 날짜 기준)이면 옛 버전으로 되돌아가지 않음
- 압축이 깨졌거나 `../` 같은 위험한 경로가 있으면 버리고 기존 버전 유지
- 웹 API는 같은 PC의 화면에서 온 요청만 받음(Host·Origin·헤더 검사)

## 시험
```
pwsh -File tests\Run-Tests.ps1          # PowerShell 7
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1   # Windows PowerShell 5.1
```
가짜 GitHub 서버(내 PC 안)로 확인·받기·교체·롤백·오류·토큰 노출·배포 zip·설치·다시 켜기를 80여 개 항목으로 점검합니다.
