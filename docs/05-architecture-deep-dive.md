# 아키텍처 심화 — 각 단계가 실제로 어디서 도나

"로그파일 → 대시보드"는 평면적 이해. 실제론 **4개의 분리된 머신(1 호스트 + 3 컨테이너)**이 각자 프로세스를 돌리며 네트워크로 통신한다.

```
[1] kali 호스트        [2] 매니저 컨테이너     [3] 인덱서 컨테이너   [4] 대시보드 컨테이너
   (에이전트)      →       (분석 두뇌)      →     (저장/검색)     ←     (화면)
```

## 단계별 실행 위치

| 단계 | 프로세스 | 위치 | 하는 일 |
|---|---|---|---|
| 로그수집 | `wazuh-logcollector` | [1] 호스트 에이전트 | journald/파일 tail |
| 전송 | `wazuh-agentd` | [1] 호스트 에이전트 | 버퍼링 후 암호화 전송 |
| 수신 | `wazuh-remoted` | [2] 매니저 | 에이전트 데이터 수신 (:1514) |
| **디코더+룰** | `wazuh-analysisd` | [2] 매니저 | 필드추출→조건매칭→레벨판정 (**두뇌**) |
| 상태저장 | `wazuh-db` | [2] 매니저 | 에이전트 인벤토리/상태 (SQLite) |
| 알림기록 | `wazuh-analysisd`→`alerts.json` | [2] 매니저 | `/var/ossec/logs/alerts/alerts.json` |
| 색인전송 | `filebeat` | [2] 매니저 | alerts.json 읽어 인덱서로 (:9200) |
| 저장/검색 | OpenSearch(JVM) | [3] 인덱서 | 날짜별 인덱스 색인 |
| 조회/시각화 | Node.js | [4] 대시보드 | 인덱서 쿼리 + 매니저 API 호출 |

## 컴포넌트 셋

### 에이전트 (호스트)
엔드포인트마다 하나. **경량 수집기, 판단 안 함.**
- `wazuh-agentd`: 매니저 연결. **끊기면 로컬 버퍼 → 복구 시 재전송(유실 방지)**
- `wazuh-logcollector`: journald/파일 읽기
- `wazuh-syscheckd`: FIM(파일 무결성)
- `wazuh-modulesd`: SCA 등
- `wazuh-execd`: 액티브 리스폰스 실행

### 매니저 (컨테이너, 데몬 다수)
탐지의 심장.
- `wazuh-remoted`(:1514 수신), `wazuh-analysisd`(디코더+룰=두뇌, alerts.json 생성)
- `wazuh-db`(상태 DB), `wazuh-authd`(:1515 등록), `wazuh-apid`(:55000 REST API), `wazuh-execd`(리스폰스 조율)
- `filebeat`(별도 프로세스): alerts.json → 인덱서
- 매니저도 자기 자신 감시(agent 000) → 컨테이너 안에도 logcollector/syscheckd 존재(호스트 것과 이름 겹침, WSL은 커널 공유라 `pgrep` 시 섞여 보임)

### 인덱서 = OpenSearch (컨테이너)
Elasticsearch 오픈소스 포크. **JVM이라 무겁다(메모리 문제 주범).**
- 날짜별 인덱스로 색인. 실측:
  ```
  wazuh-alerts-4.x-2026.09.29   1566건  2.3mb
  wazuh-alerts-4.x-2026.09.30    451건  758kb
  ```
- 날짜 분할 이유: 기간 검색 빠름 + 오래된 것 통째 삭제(보관주기 관리) 쉬움

### 대시보드 (컨테이너)
OpenSearch Dashboards + Wazuh 플러그인. **두 곳에 붙음:**
- 인덱서(:9200) — 알림 검색/그래프 ("Alerts evolution over time")
- 매니저 API(:55000) — 에이전트 목록/룰/SCA

## 데이터 물리 흐름 — 어디에 남나

```
journald(호스트)
  │ wazuh-agentd 전송 (TCP 1514, 암호화)
  ▼
매니저: analysisd 판정 → /var/ossec/logs/alerts/alerts.json (평문 파일)
  │ filebeat이 tail 전송 (TCP 9200)
  ▼
인덱서: wazuh-alerts-4.x-<날짜> 인덱스 색인 (디스크 영구저장)
  ▲
  │ 대시보드 검색 쿼리 (TCP 9200)
대시보드 화면
```

**통찰 2가지:**
1. **알림은 두 군데 남는다** — 매니저 `alerts.json`(원본 파일) + 인덱서(검색용 색인). 대시보드는 인덱서를 봄. 그래서 filebeat→인덱서가 죽으면 **탐지는 되는데(파일엔 남는데) 화면엔 안 뜸.**
2. **머신 넘는 홉 3개** — 에이전트→매니저(1514), 매니저→인덱서(9200 filebeat), 대시보드→인덱서+매니저(9200/55000). 각 홉이 장애 포인트.

## 로그 소스 (이 랩 특이점)
- Kali엔 `/var/log/auth.log` 없음(rsyslog `inactive`). sshd 로그는 **journald 바이너리** `/var/log/journal/<machine-id>/`에 저장.
- 에이전트가 journald 직접 읽음 → alerts에 `"location":"journald"`. Ubuntu 기준 가이드의 auth.log 전제와 다름.
- 비루트는 시스템 저널 못 읽음(`systemd-journal` 그룹 아님) → `sudo journalctl -u ssh`.
