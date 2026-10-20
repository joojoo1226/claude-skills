---
name: drive
description: 사내 Nextcloud Drive(Nextcloud, https://nextcloud.example.com)에서 파일을 검색·탐색·다운로드해 답변한다. "/drive", "nextcloud", "넥스트클라우드", "사내 드라이브", "드라이브에서 ~ 찾아줘/있어?" 같은 요청에 사용.
---

# Nextcloud Drive 검색

사내 파일 서버 **Nextcloud Drive**(Nextcloud 32, `https://nextcloud.example.com`)를 조회한다.
모든 접근은 `scripts/nxdrive.ps1` 한 개를 통해서만 한다. 직접 `Invoke-WebRequest`로
드라이브를 때리지 말 것 — 인증·인코딩·WebDAV 동사 처리가 스크립트에 들어있다.

## 실행 방법

PowerShell 툴에서 호출 연산자로 직접 실행한다 (`powershell.exe`가 PATH에 없을 수 있으므로 `powershell -File` 형식은 쓰지 않는다):

```powershell
& "%USERPROFILE%\.claude\skills\drive\scripts\nxdrive.ps1" -Action <액션> [옵션]
```

스크립트는 **항상 JSON 한 덩어리**를 stdout으로 낸다. 실패 시 `{"ok":false,"error":...,"hint":...}` + 종료코드 1.

## 액션

| 액션 | 용도 | 주요 옵션 |
|---|---|---|
| `search` | 파일명 검색 (기본) | `-Query <검색어>` `-Path <범위폴더>` `-Ext xlsx,pdf` `-Limit 25` `-Mode auto\|unified\|webdav` |
| `recent` | 최근 수정 파일 | `-Path` `-Limit` `-Ext` |
| `ls` | 폴더 내용 나열 | `-Path <폴더>` `-Depth 1` |
| `get` | 파일 다운로드 | `-Path <원격경로>` `-Out <로컬경로>` |
| `test` | 로그인 상태·계정 확인 | — |
| `providers` | 서버가 지원하는 검색 프로바이더 | — |
| `login` / `logout` | 자격증명 저장 / 삭제 | `-User` `-AppPassword` |

### 검색 모드
- `unified` — Nextcloud 통합 검색 API. 웹 UI 검색창과 동일한 결과. 폴더 범위 지정은 안 된다.
- `webdav` — WebDAV `SEARCH`. 파일명 부분일치(`%term%`), **폴더 범위 지정**과 수정일 내림차순 정렬이 정확하다.
- `auto` (기본) — `-Path`가 있으면 곧바로 webdav, 없으면 unified를 먼저 쓰고 0건일 때 webdav로 재시도.

> **중요 — 이 서버는 파일명 검색만 된다.** 2026-08-03 확인 기준 검색 프로바이더는
> `files`, `systemtags`, `circles`, `comments`, `calendar`, `tasks`, `forms`, `settings`뿐이고
> **`fulltextsearch` 앱이 없다.** 즉 파일 *내용*으로는 검색되지 않는다. 사용자가 내용 기반으로
> 찾아달라고 하면 이 한계를 밝히고, 파일명·폴더 구조로 후보를 좁힌 뒤 `get`으로 열어 확인한다.
> 없는 기능을 있는 것처럼 답하지 말 것. (`-Action providers`로 언제든 재확인 가능)

### 루트 폴더 (2026-08-03 기준, 변할 수 있음 — 확실치 않으면 `ls`로 확인)
`전체 공유`(공용), `<개인 폴더>`, `<부서 폴더>` 등 — 조직마다 다르므로
  `providers` 액션으로 실제 목록을 먼저 확인한다
(`/전체 공유/총무`, `/전체 공유/프로젝트`, `/전체 공유/온보딩` 등).

## 최초 1회: 자격증명 등록

`test`가 `No stored Nextcloud Drive credential` 또는 401을 내면 아직 연결 전이다.
**앱 비밀번호를 대화창에서 받지 않는다.** 사용자에게 아래를 안내한다:

1. `https://nextcloud.example.com/settings/user/security` → 하단 "앱 비밀번호" 생성
2. **`%USERPROFILE%\.claude\skills\drive\LOGIN.cmd` 를 더블클릭** → 창이 뜨면 아이디와
   앱 비밀번호를 입력(입력은 화면에 안 보임). 성공하면 초록색 `SUCCESS` 줄이 뜬다.

`LOGIN.cmd`는 따옴표·셸 문법 문제가 없고 비밀번호가 명령 기록에도 남지 않는다.
`-Action login`을 인자 없이 콘솔에서 직접 실행해도 같은 대화형 프롬프트가 뜬다.
(비대화형 환경에서는 즉시 에러로 끝나며 절대 멈춰 있지 않는다.)

등록 여부는 `-Action test`로 확인한다. 사용자가 "했다"고 해도 반드시 `test`로 검증한 뒤 답한다.

저장 위치는 `%USERPROFILE%\.claude\.nxdrive\credential.xml` 이며 Windows DPAPI로
암호화된다(해당 사용자 계정 + 해당 PC에서만 복호화 가능). 환경변수
`NXDRIVE_USER` / `NXDRIVE_APP_PASSWORD` 가 있으면 그쪽이 우선한다.

## 답변 규칙

1. **원시 JSON을 그대로 붙여넣지 않는다.** 표로 정리해서 보여준다:
   파일명 / 경로 / 수정일 / 크기, 그리고 `url` 필드를 마크다운 링크로.
2. 검색어가 애매하면 한 번에 여러 각도로 돌린다 — 예: `"예산"` 검색이 빈약하면
   `"budget"`, 연도(`2026`), 확장자 필터(`-Ext xlsx,pdf`)를 바꿔 재시도한 뒤 종합해 답한다.
   한 번 돌려보고 "없습니다"로 끝내지 말 것.
3. 결과 0건이면 그렇다고 명확히 말하고, 시도한 검색어·범위를 밝힌다.
4. 사용자가 내용까지 물으면(`~파일 요약해줘`) `get`으로 받아 로컬 경로를 Read 한다.
   응답의 `readable: false`(xlsx/docx/pptx/hwp 등 바이너리)면 Read로 못 읽으니,
   경로를 알려주고 변환·파싱이 필요하다고 밝힌다. 임의로 내용을 추측하지 않는다.
5. 다운로드 기본 위치는 `%TEMP%\nxdrive\`. 사용자가 원하는 위치를 말하면 `-Out`으로 지정한다.
6. **쓰기 작업(업로드·삭제·이동)은 이 스킬에 없다.** 요청받으면 지원 범위 밖임을 밝히고,
   추가할지 사용자에게 확인받는다. 임의로 다른 방법을 동원하지 않는다.
7. 앱 비밀번호·`credential.xml` 내용은 절대 출력하지 않는다.

## 경로 표기

경로는 사용자 루트 기준이다. 웹 UI에서 `/팀공유/2026/기획.xlsx` 로 보이면
`-Path "/팀공유/2026/기획.xlsx"` 그대로 쓴다. 공백·한글은 스크립트가 인코딩하므로
따옴표만 씌우면 된다.

## 예시

```powershell
# "인사" 들어간 파일 찾기
... -Action search -Query "인사"

# 팀공유 폴더 안에서 엑셀만
... -Action search -Query "예산" -Path "/팀공유" -Ext xlsx

# 루트 폴더 구조 파악
... -Action ls -Path "/"

# 최근 바뀐 파일 10개
... -Action recent -Limit 10

# 파일 받아서 읽기
... -Action get -Path "/팀공유/회의록.md"
```
