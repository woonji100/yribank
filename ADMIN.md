# 관리자 절차 (한 번만 하면 됩니다)

## 1. 저장소 만들기
1. GitHub에서 **Private** 저장소를 만듭니다. (브랜치: `main`)
2. 프로그램 파일과 이 키트를 올립니다. `.gitignore`에 `.gitignore.sample` 내용이 들어 있는지 확인하세요(토큰 파일이 저장소에 올라가면 안 됩니다).

## 2. 토큰 만들기 (저장소 하나, 읽기 전용)
GitHub → 오른쪽 위 프로필 → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
- Token name: 예) `내프로그램-업데이트`
- Expiration: 만료일 지정 (최대 1년). 만료 때 새로 만들어야 하니 달력에 적어 두세요.
- Resource owner: 저장소 소유자(개인 또는 조직)
- Repository access: **Only select repositories** → 이 저장소 **하나만**
- Permissions → Repository permissions → **Contents: Read-only** (Metadata: Read-only는 자동)
- 만들어진 `github_pat_…` 값은 **한 번만** 보이니 복사해 두세요. 조직 저장소는 조직 관리자의 토큰 승인이 필요할 수 있습니다.

## 3. 토큰 파일 넣기
토큰은 코드나 저장소에 쓰지 않습니다. 배포 zip을 만들 때 자동으로 `config\update.secret.json`에 들어갑니다.
```json
{"update":{"repo":"내계정/내저장소","branch":"main","token":"github_pat_..."}}
```
(내 PC에서 개발 폴더로 실행할 때는 업데이트가 꺼져 있으므로 이 파일이 필요 없습니다.)

## 4. 배포 zip 만들기
저장소 폴더에서 (커밋·push를 끝낸 상태):
```
powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1
```
토큰을 물어보면 붙여넣습니다(화면에 안 보임). 먼저 토큰으로 GitHub에 접속해 보고, 토큰이 git에 올라가 있으면 중단합니다. 결과: `dist\<폴더이름>-<커밋7자리>.zip`
- 이 zip 안에는 **토큰이 들어 있으므로** 직원에게만 전달하세요(공개 게시판·전체 메일 금지).
- 직원은 zip을 풀고 `Install.cmd`를 더블클릭하면 설치됩니다(`%LOCALAPPDATA%\<폴더이름>`, 바탕화면 바로가기).

## 5. 이후에는 `git push`만
`main`에 push하면, 각 PC가 다음에 켤 때(또는 [지금 업데이트 확인]) 자동으로 받아 갑니다. 배포 zip은 새 PC 설치용이며 매번 다시 만들 필요 없습니다.

## 운영 메모
- **문제가 있는 버전**: 옛 커밋으로 force push 하지 마세요(설치본이 더 새것으로 보여 따라가지 않습니다). `git revert`로 되돌리는 **새 커밋**을 push하면 모두 따라갑니다.
- **토큰 만료/교체**: 새 토큰으로 Build-Release를 다시 실행해 zip을 전달하고, 직원이 `Install.cmd`를 다시 실행하면 토큰만 새로 들어갑니다(데이터·설정 유지). 또는 각 PC의 `config\update.secret.json`의 `token` 값을 직접 바꿔도 됩니다.
- **토큰이 유출된 것 같으면**: GitHub에서 즉시 토큰을 폐기(Revoke)하고 새로 발급하세요. 읽기 전용·저장소 1개 권한이라 피해 범위는 그 저장소 읽기로 제한됩니다.
- **직전 상태로 복구**: `설치폴더\.update\backup\<날짜시간>\`에 마지막으로 바뀐 파일의 이전 본이 있습니다.
- **로그**: `start.log`(켤 때 적용 기록), `update.log`(확인·받기·오류), `update-check.json`(마지막 확인 결과).

## 문제 해결 (설정 화면에 보이는 문구)
| 문구 | 원인 → 조치 |
|---|---|
| 토큰이 만료되었거나 올바르지 않습니다(401) | 토큰 만료·오타 → 새 토큰 |
| 토큰에 권한이 없거나 … 사용 한도를 넘었습니다(403) | 권한 부족/요청 한도 → 잠시 뒤 재시도, 계속되면 토큰 권한(Contents: Read-only) 확인 |
| 저장소를 찾을 수 없거나 접근 권한이 없습니다(404) | 저장소 이름·브랜치 오타, 또는 토큰에 그 저장소 권한 없음 |
| 인터넷에 연결되지 않아 … | 네트워크/프록시 문제. 조용히 건너뛰며 평소처럼 실행됨 |
| 업데이트 설정(config/update.secret.json)이 없거나 … | 설치 zip이 아닌 방법으로 설치했거나 파일 삭제 → 다시 설치 |
| 받은 압축 파일이 깨져 … | 네트워크 중단 → 다음 확인 때 자동 재시도 |
