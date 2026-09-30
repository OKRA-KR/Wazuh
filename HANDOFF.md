# HANDOFF — Wazuh SIEM 랩 (Claude 세션 인수인계)

> 다른 Claude 세션이 이 작업을 **콜드 스타트로 이어받기 위한** 문서다. 사람용 개요는 `README.md`, 개념/절차는 `docs/`. 이 파일은 "지금 뭘 어떻게 조작하고, 다음에 뭘 하고, 뭘 조심하나"에 집중한다.

---

## ⚠️ 중요 (2026-09-30 갱신)

- **원래 실습 PC를 더 못 씀.** 아래 §5의 살아있던 랩(에이전트 등록·알림 등)은 그 PC에 있었고 **접근 불가**. 재개하려면 **새 머신에서 `README.md`의 setup.sh로 재구축** 필요(configs·룰은 이 repo에 있음).
- **최우선 = 금요일(2026-10-02) 위메이드 면접.** 대비 자료는 **`docs/04-wemade-interview-prep.md`**(회사 최근 보안사고 인텔 + 예상질문·키워드답안 + 요기요 패착 처방).
- 로컬 자동 메모리는 옛 PC에만 있으니 **이 repo가 유일한 durable 인수인계**다.

## 0. 한 줄 요약

위메이드 블루팀 면접(**2026-10-02 금**) 대비 Wazuh SIEM 실습랩. 스택·에이전트·SSH 브루트포스 탐지·SCA 이해·오탐(postfix 노이즈) 발견까지 완료. 룰 튜닝 편집 단계에서 PC 교체로 중단. **면접이 최우선 → `docs/04` 집중.** 랩 재개 시엔 룰 튜닝 재시험 → 웹공격(OKRA) 탐지.

## 1. 사용자 & 작업 스타일 (꼭 지킬 것)

- SK쉴더스 직원, 한국어로 소통. 진단/모의해킹 배경은 있으나 **SIEM/블루팀은 처음**.
- **선생-제자식 설명 선호**: 접근 기준·참고 근거·왜 그런지를 드러내며 가르치듯. 답을 던지지 말고 원리를 보여줄 것.
- **"직접 하지 말고 방법부터"** 요구가 잦다. 공격 실행·서버 붙이기 같은 조작은 **절차를 주고 사용자가 실행**하게 하라. 읽기전용 확인(로그/상태 조회)은 네가 해도 됨.
- 글은 AI 티 안 나게(간결·구체·직접). `im-not-ai` 스킬 있음.
- 추측으로 단정하지 말 것. 이 랩에서 "API로 강제 재스캔 된다"고 추측했다가 틀린 적 있음 → **소스/스펙으로 검증 후 답하라.**

## 2. 환경 & 명령 실행 방법

- 호스트: Windows 11. 랩은 **kali WSL2 안의 네이티브 dockerd**(Docker Desktop 아님, `27.5.x+dfsg`, systemd 활성).
- Claude의 Bash 툴은 **Windows Git Bash**다. kali 안에서 실행하려면:
  ```bash
  MSYS_NO_PATHCONV=1 wsl --exec bash -lc '<명령>'
  ```
  `MSYS_NO_PATHCONV=1`은 경로(`/var/...`)가 Windows 경로로 변환되는 것 방지. 필수.
- compose 위치(kali 안): `/home/kali/wazuh-docker/single-node/`
- 컨테이너명: `single-node-wazuh.{manager,indexer,dashboard}-1`
- 긴 대기(정착 등)는 `run_in_background: true`로 돌리고 알림 기다려라(120s 포그라운드 타임아웃 있음).

## 3. 제약 (여기서 막힌다)

- **sudo는 암호 필요** → 패키지 설치(`dpkg`)·서비스 등록(`systemctl`)·`sudo cat` 전부 네가 못 한다. **사용자가 kali 터미널에서 직접** 실행해야 함. `wsl --exec`로 sudo 쓰면 암호 프롬프트에서 멈춰 백그라운드로 넘어가니 하지 말 것.
- 비루트라 시스템 **journal / `/var/ossec/etc/ossec.conf`(에이전트) 못 읽음** (`systemd-journal` 그룹 아님, 파일 0640 root).
- **docker 명령은 sudo 불필요** → 컨테이너 조작(`docker exec/cp/restart`, 매니저 내부 파일 편집)은 네가 가능.
- **dockerd/컨테이너를 잦게 재시작하지 마라.** 매니저 s6 cont-init 완주에 1~2분. 그 사이 건드리면 데몬이 계속 죽는 것처럼 보임. 클린하게 한 번 올리고 무간섭 정착시켜라.
- **호스트 가용 RAM ~7.7GB(물리 15.7, 윈도우가 ~8 사용).** `.wslconfig` memory는 6~8GB. 더 올리면 WSL VM 통째 크래시. 부하 줄이려면 Wazuh 외 컨테이너 정지.

## 4. 접속 정보 / 경로

| 항목 | 값 |
|---|---|
| 대시보드 | `https://<eth0 IP>:443` — `admin`/`SecretPassword` |
| 매니저 API | `https://127.0.0.1:55000` — `wazuh-wui`/`MyS3cr37P450r.*-` |
| 인덱서 | `https://localhost:9200` — `admin`/`SecretPassword` |
| 커스텀 룰(매니저 내부) | `/var/ossec/etc/rules/local_rules.xml` |
| 기본 룰(읽기용) | `/var/ossec/ruleset/rules/` (예: `0095-sshd_rules.xml`) |
| 알림 원본 | `/var/ossec/logs/alerts/alerts.json` |
| SCA 정책 | `/var/ossec/ruleset/sca/` (활성: `sca_unix_audit.yml`) |

**API 토큰 받는 법(검증된 방식):**
```bash
MSYS_NO_PATHCONV=1 wsl --exec bash -lc 'TOKEN=$(curl -sk -u "wazuh-wui:MyS3cr37P450r.*-" -X POST https://127.0.0.1:55000/security/user/authenticate | python3 -c "import sys,json;print(json.load(sys.stdin)[\"data\"][\"token\"])"); curl -sk -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:55000/sca/001"'
```
(토큰은 `data.token`에 있음. grep으로 대충 뽑지 말고 python으로 파싱.)

## 5. 현재 상태 (검증 완료)

- ✅ 스택 정상: 인덱서 green, 매니저 데몬(analysisd/remoted/db/apid 등) 기동, API 200, 대시보드 302.
- ✅ 에이전트 **ID 001 `kali-victim` Active** (`agent_control -l`로 확인). 127.0.0.1로 붙음.
- ✅ SSH 브루트포스 탐지 확인: rule **5710→5758→2502**(level 10), **MITRE T1110**. 로그 소스는 **journald**(Kali에 auth.log 없음/rsyslog off — 정상).
- ✅ SCA 이해: `unix_audit` 정책, interval 43200s(12h), scan_on_start, Pass3/Fail13. **SCA 강제재스캔 API 없음**(`/sca/{agent}`는 GET만) → 에이전트 재시작 또는 interval 축소로만 재스캔.
- ✅ **오탐 사례 발견**(면접 핵심 재료): SSH만 테스트했는데 대시보드 "Email Collection(T1114)"이 폭증(885건). 원인은 공격이 아니라 **고장난 postfix가 10초마다 뱉는 로그 노이즈**(rule **3398** "Illegal address", full_log=`mail_queue_enter ... No such file`)가 오분류된 것. → "많이 뜨는 알림 ≠ 위협, full_log 역추적" 교훈.
- 🔧 룰 튜닝 진행중(PC교체로 중단): postfix 노이즈 억제룰 편집 시도했으나 **매니저 컨테이너에 vi/nano 없음** → 방법=`docker cp`로 넣거나 `cat >>` heredoc으로 append. 억제룰 설계: `<rule id="100030" level="0"><if_sid>3398</if_sid><match>mail_queue_enter</match></rule>` (노이즈만 콕 집어 억제, 진짜 스팸은 유지). SSH용 억제(100010: 127.0.0.1)+격상(100020: root 성공)은 `custom-rules/local_rules.xml`에 있음.

## 6. 다음 액션 (바로 이어서 할 것)

### (A) 룰 튜닝 재시험 — 즉시 다음
1. 사용자가 `local_rules.xml`에 억제룰을 넣었는지 확인:
   ```bash
   MSYS_NO_PATHCONV=1 wsl --exec bash -lc 'docker exec single-node-wazuh.manager-1 cat /var/ossec/etc/rules/local_rules.xml'
   ```
   (안 넣었으면 이 패키지 `custom-rules/local_rules.xml`을 `docker cp`로 주입 제안. 문법검증: `docker exec ... /var/ossec/bin/wazuh-logtest -t`)
2. 매니저 재시작 → 1~2분 대기.
3. **사용자에게** hydra 재시험 요청(직접 실행): `hydra -l testuser -P <wordlist> -t 4 -f ssh://127.0.0.1`.
4. 네가 `alerts.json`에서 Before/After 확인 — 127.0.0.1 실패가 rule 100010(level 0)로 억제됐는지:
   ```bash
   MSYS_NO_PATHCONV=1 wsl --exec bash -lc 'docker exec single-node-wazuh.manager-1 bash -lc "grep 100010 /var/ossec/logs/alerts/alerts.json | tail -3"'
   ```
   (억제해도 상관룰 2502가 살아있으면 그것도 튜닝 → tune-test-refine 사이클로 설명.)

### (B) 웹공격 탐지 (OKRA 연계) — 면접 핵심
- 표적 컨테이너 start(`docker start juiceshop` 또는 crapi 스택). **현재 정지 상태**(트러블슈팅 때 juiceshop 정지, crapi Exited).
- 웹 access log가 컨테이너 안이라 에이전트에 안 감 → **로그를 에이전트 `<localfile>`로 물리거나 볼륨 노출** 필요.
- 웹 룰셋(web/attack/appsec)으로 OKRA의 SQLi/XSS/경로탐색 탐지 → 대시보드 확인.
- 스토리: "진단도구(OKRA)가 쏜 공격을 SIEM이 잡는다."

### (C) 마무리
- 스크린샷 3장(브루트포스+ATT&CK / 룰튜닝 전후 / 대시보드 구조).
- `docs/03-interview-notes.md` 면접 스크립트 최종 점검.

## 7. 함정 (이미 겪은 것, 재발 방지)

README §5에 8개 상세. 요점:
1. "컨테이너가 죽는다"의 진짜 원인이 **WSL VM 메모리 크래시**일 수 있다. 증상→컨테이너→dockerd→WSL VM→호스트RAM 순 격리.
2. 좀비 `vmmem` 남으면 WSL 재기동 불가(`CreateInstance/E_FAIL`) → **Windows 재부팅**이 확실.
3. 인증서 첫 기동 전 생성 필수(안 하면 cert 경로가 디렉터리로 생성돼 인덱서 크래시 루프).
4. 매니저 cont-init `find`가 /proc 훑으며 멈추면 → `docker compose down && up -d` 클린 재생성.
5. 컨테이너 내부 `ss`로 55000 안 잡혀도 API 200이면 정상(측정 아티팩트).

## 8. 관련 파일 / 메모리

- 이 repo(=유일한 durable 인수인계): `github.com/OKRA-KR/Wazuh`
  - `README.md`(사람용 상태/재구축), `HANDOFF.md`(이 문서), `setup.sh`, `compose/`, `custom-rules/local_rules.xml`, `.wslconfig.example`
  - `docs/01-detection-concepts.md`(탐지 파이프라인), `02-agent-and-test.md`(에이전트·공격 절차), `03-interview-notes.md`(면접 노트 초판), **`04-wemade-interview-prep.md`(면접 최종 대비, 최우선)**, `05-architecture-deep-dive.md`(각 단계 실행위치)
- 원본 가이드(옛 PC): `C:\Users\user\Downloads\Wazuh_SIEM_실습랩_구축가이드.md`
- 자동 메모리(옛 PC에만): `proj-wazuh-siem-lab.md`. 새 머신엔 없으니 이 repo로 대체.
- 연관: OKRA SAST+DAST(`sast-dast-project`) — 성립검증=오탐제거 논리 공유(면접 핵심 연결).

## 9. 이 세션에서 한 일 (작업 내역 / 근거)

무엇을 했나 → 무엇에 기반했나:
1. **환경 트러블슈팅** — 컨테이너 반복 재시작의 진짜 원인이 **WSL VM 메모리 크래시**임을 레이어별(데몬→컨테이너→dockerd→WSL→호스트RAM) 격리로 규명. 근거: `wsl -l -v`(Stopped), `docker inspect`(RestartCount/StartedAt), 커널 uptime 샘플링, `free -h`. 조치: `.wslconfig` 튜닝 + 좀비 vmmem은 재부팅 + 클린 재생성.
2. **에이전트 부착** — kali 호스트에 wazuh-agent 설치(사용자가 sudo로), 매니저에 001 Active 확인.
3. **SSH 브루트포스 탐지** — hydra(loopback) → alerts.json에서 rule 5710/5758/2502, T1110, `location:journald` 확인.
4. **탐지 파이프라인/아키텍처 규명** — 각 단계 실행 위치를 실물 프로세스·포트·인덱스(`wazuh-alerts-4.x-<날짜>`)로 확인 → `docs/05`.
5. **SCA 이해** — API로 `unix_audit` 정책·interval·Pass/Fail 확인, 강제재스캔 API 부재를 spec.yaml로 검증.
6. **오탐 발견** — Email Collection 폭증이 postfix 노이즈(rule 3398)임을 alerts.json 집계로 규명.
7. **면접 전략** — 요기요 3패착 + 위메이드 최근 보안사고(2026-07 WEMIX$ 77억, 4년 묵은 코드취약점, 망분리·키교체 대응) 웹조사 → `docs/04`로 정리.
