# claude-skills

Claude Code에서 쓰는 개인 스킬과 서브에이전트 모음입니다.
사내 정보를 제거한 공개판이라, 경로·서버 주소 같은 값은 예시로 바꿔 두었습니다.
쓰시기 전에 본인 환경에 맞게 고쳐 주세요.

## 설치

`~/.claude/` (Windows는 `%USERPROFILE%\.claude\`) 아래에 복사합니다.

```bash
git clone https://github.com/joojoo1226/claude-skills.git
cp -r claude-skills/skills/* ~/.claude/skills/
cp -r claude-skills/agents/* ~/.claude/agents/
```

프로젝트 단위로 쓰려면 프로젝트 폴더의 `.claude/` 아래에 두면 됩니다.

## 스킬

| 스킬 | 하는 일 |
|---|---|
| `task-observer` | 작업 중 드러난 개선점을 관찰 로그로 쌓고, 주기적으로 검토해 스킬로 발전시킵니다. 가장 규모가 큰 스킬입니다 |
| `commit_msg` | 변경 내역을 분석해 Conventional Commits 형식의 커밋 메시지와 PR 본문을 만듭니다 (한국어) |
| `database` | 읽기 전용으로 DB에 붙어 스키마를 탐색하고, 코드와 테이블의 대응을 설명하고, SELECT 쿼리를 작성합니다. 쓰기는 하지 않습니다 |
| `test` | 정적분석 후 빌드해 오류 0을 확인하고, 수동 확인용 체크리스트를 만듭니다 |
| `team` | 요구사항 하나를 기획 → 백엔드/프론트엔드 → 테스트 → 매뉴얼 순서로 서브에이전트에 넘깁니다 |
| `daily` | 프로젝트별 개발일지를 기록하고, 남은 할 일을 뽑습니다 |
| `drive` | Nextcloud에서 파일을 검색·탐색·다운로드합니다 (Windows PowerShell) |

## 서브에이전트

`team` 스킬이 부르는 역할별 에이전트입니다.

`team-planner` · `team-backend` · `team-frontend` · `team-test-auto` ·
`team-test-manual` · `team-manual`

`team-sync.ps1` 로 여러 프로젝트에 한 번에 복사·갱신할 수 있습니다.

```powershell
# 새 프로젝트에 넣기
powershell -File team-sync.ps1 "D:\경로\새프로젝트"

# 원본 수정 후 전체 갱신
powershell -File team-sync.ps1
```

## 쓰기 전에 고쳐야 하는 값

| 파일 | 고칠 것 |
|---|---|
| `skills/daily/SKILL.md` | 프로젝트 경로표, 개발일지 파일 경로 |
| `skills/drive/SKILL.md` | Nextcloud 주소 (`nextcloud.example.com`) |
| `skills/drive/scripts/nxdrive.ps1` | 같은 주소. 환경변수 `NXDRIVE_URL` 로도 지정 가능 |

## drive 스킬 자격증명

비밀번호를 파일에 적지 않습니다. Nextcloud 설정에서 **앱 비밀번호**를 만든 뒤
`LOGIN.cmd` 를 실행해 한 번 등록하면 Windows DPAPI로 암호화해 보관합니다.

```
%USERPROFILE%\.claude\.nxdrive\credential.xml
```

환경변수 `NXDRIVE_USER` / `NXDRIVE_APP_PASSWORD` 가 있으면 그쪽이 우선합니다.

## 라이선스

MIT. 자세한 내용은 [LICENSE](LICENSE) 참고.
