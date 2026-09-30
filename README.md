# Wazuh SIEM 실습 랩 — 이식 패키지

위메이드 블루팀 면접 대비로 세운 Wazuh SIEM 랩. **다른 로컬 머신에서 이 폴더만으로 동일하게 재현**하기 위한 패키지다.

- 원 환경: Windows 11 + kali WSL2 안의 네이티브 dockerd (Docker Desktop 아님)
- Wazuh 버전: **4.9.2** (single-node)
- 작성 시점 기준 진행상황·함정·다음 단계까지 이 문서에 다 있다.

> **2026-09-30 상태**: 원래 실습 PC를 더 못 씀 → 살아있던 랩은 접근 불가. **새 머신에선 §1 setup.sh로 재구축.** **금요일(10/2) 위메이드 면접이 최우선 → `docs/04-wemade-interview-prep.md` 참조.** Claude 세션 인수인계는 `HANDOFF.md`.

---

## 0. 지금 어디까지 했나 (진행상황)

| 단계 | 상태 | 메모 |
|---|---|---|
| Wazuh 스택 기동 (manager/indexer/dashboard) | ✅ 완료 | 4.9.2, 인덱서 green |
| WSL 크래시 문제 해결 | ✅ 완료 | 메모리 튜닝 + 클린 재생성 (§5 함정) |
| 에이전트 등록 | ✅ 완료 | `kali-victim` (ID 001), Active |
| SSH 브루트포스 탐지 확인 | ✅ 완료 | rule 5710→5758→2502, MITRE T1110, **journald 소스** |
| Configuration Assessment(SCA) 이해 | ✅ 완료 | `unix_audit` 정책, 12h 주기, Pass 3/Fail 13 |
| 오탐 사례 발견 (postfix 노이즈) | ✅ 완료 | Email Collection 폭증=고장난 postfix(rule 3398) 노이즈. 면접 핵심 재료 |
| 룰 튜닝 (local_rules.xml 오탐 억제) | 🔧 중단 | PC 교체로 편집 단계 중단. 억제룰 설계·초안은 `custom-rules/`·`HANDOFF §5` |
| 웹 공격 탐지 (crAPI/juiceshop + OKRA 연계) | ⬜ 미착수 | §6 다음 단계 |
| 면접 정리 | ✅ 완료 | `docs/04-wemade-interview-prep.md` (회사분석+예상질문+패착처방) |

---

## 1. 빠른 시작 (다른 로컬에서)

### 전제
- Docker + docker compose 설치됨
- 리눅스/WSL2면 `vm.max_map_count >= 262144` (인덱서 필수)
- **가용 RAM 최소 4GB** 이 스택에 확보 가능해야 함 (§5 필독)

### 온라인 환경 (인터넷 됨)
```bash
bash setup.sh
```
스크립트가 하는 일: 공식 wazuh-docker(v4.9.2) 클론 → 인증서 생성 → `docker compose up -d` → 커스텀 룰 적용 → 접속정보 출력.

### 폐쇄망 환경 (오프라인)
1. 인터넷 되는 곳에서 이미지 4개를 파일로:
   ```bash
   docker save -o wazuh-images-4.9.2.tar \
     wazuh/wazuh-manager:4.9.2 wazuh/wazuh-indexer:4.9.2 \
     wazuh/wazuh-dashboard:4.9.2 wazuh/wazuh-certs-generator:0.0.2
   ```
2. 이 폴더 + tar를 대상 머신으로 복사
3. 대상에서: `docker load -i wazuh-images-4.9.2.tar` 후 `bash setup.sh --offline`

---

## 2. 접속 정보

| 대상 | 주소 | 계정 |
|---|---|---|
| 대시보드 | `https://<호스트 IP>:443` | `admin` / `SecretPassword` |
| 매니저 API | `https://<호스트 IP>:55000` | `wazuh-wui` / `MyS3cr37P450r.*-` |
| 인덱서 | `https://<호스트 IP>:9200` | `admin` / `SecretPassword` |

> WSL이면 `localhost` 대신 `ip addr show eth0`의 IP를 써라 (WSL2 localhost 포워딩이 불안정).
> self-signed 인증서 경고는 통과(고급 → 계속).
> **실습이라 기본 비번을 둔다. 운영이라면 반드시 교체 — 이 인지 자체가 관제 감각(면접 포인트).**

---

## 3. 폴더 구성

```
wazuh-lab/
├── README.md                    ← 이 문서 (마스터 상태/가이드, 사람용)
├── HANDOFF.md                   ← Claude 세션 인수인계용 (AI가 콜드 스타트로 이어받기)
├── setup.sh                     ← 부트스트랩 (온라인/오프라인)
├── .wslconfig.example           ← WSL 메모리 설정 (호스트에 복사)
├── compose/
│   └── docker-compose.yml       ← 실제 사용 중인 compose 원본 (4.9.2)
├── custom-rules/
│   └── local_rules.xml          ← 오탐 억제 튜닝 룰 (바로 적용 가능)
└── docs/
    ├── 01-detection-concepts.md ← SIEM이 어떻게 탐지하는가 (파이프라인)
    ├── 02-agent-and-test.md     ← 에이전트 설치 + 공격→탐지 테스트 절차
    ├── 03-interview-notes.md    ← 면접 노트 초판 (Q&A)
    ├── 04-wemade-interview-prep.md ← ★ 위메이드 면접 최종 대비 (회사분석+예상질문+패착처방)
    └── 05-architecture-deep-dive.md ← 각 파이프라인 단계가 실제로 어디서 도나
```

---

## 4. 아키텍처 (한 장 요약)

```
[공격자 역할]  ──SSH 인증시도──▶  [피해자 = 엔드포인트 / agent "kali-victim"]
 (hydra 등)                              │  에이전트가 journald(sshd 로그) 수집
                                         ▼
                        [Wazuh 매니저]  ← analysisd: 디코더→룰 매칭→알림 생성
                                         │  (+ filebeat → 인덱서 색인)
                                         ▼
                        [인덱서 OpenSearch]  ──▶  [대시보드]  ← Security events 확인
```

리소스 제약으로 **공격자·피해자·SIEM을 한 호스트에 논리적으로 분리**해 압축 구성. 실제 관제는 다수 엔드포인트의 에이전트를 매니저가 중앙 수집하는 구조이고, 여기선 그 최소 단위를 재현.

---

## 5. 반드시 알아야 할 함정 (여기서 시간 다 날렸다)

1. **호스트 RAM이 병목** — 이 랩 최대 리스크.
   - 인덱서(JVM 1GB 힙+오버헤드)+대시보드+매니저 = 부하 시 순간 4~5GB.
   - Windows가 이미 ~8GB 쓰면 WSL에 줄 여유가 적다. **`.wslconfig` 메모리는 호스트 가용에 맞춰라. 무리하게 올리면(예: 호스트 가용 7.7GB인데 10GB) 호스트가 못 받쳐 WSL VM이 통째로 크래시**한다. 6~8GB가 현실적.
   - Wazuh 외 컨테이너(juiceshop, crapi 등)는 정지시켜 부하를 줄여라: `docker update --restart=no <c> && docker stop <c>`.

2. **"컨테이너가 죽는다"의 진짜 원인이 WSL VM 크래시일 수 있다.** 증상(데몬)→컨테이너→dockerd→WSL VM→호스트RAM 순으로 레이어를 내려가며 격리하라. 컨테이너·systemd·커널 uptime을 비교하면 무엇이 도는지 보인다.

3. **dockerd를 너무 자주 재시작시키지 마라.** 매니저 초기화(s6 cont-init)가 완주하는 데 1~2분 걸리는데, 그 사이 재시작하면 데몬이 안정될 창을 못 얻어 계속 죽는 것처럼 보인다. **손 떼고 `docker compose down && up -d` 후 무간섭 정착**이 정답.

4. **인증서는 첫 기동 전에 생성해야 한다.** 안 하면 bind-mount가 없는 인증서 경로를 **디렉터리로** 만들어버려 인덱서가 크래시 루프에 빠진다. setup.sh가 순서를 지킨다.

5. **Kali엔 `/var/log/auth.log`가 없다** (rsyslog 기본 off). Wazuh 4.9 에이전트는 이 경우 **journald를 직접 읽는다**(`"location":"journald"`). 그래서 파일이 없어도 sshd 탐지는 정상 동작. Ubuntu 기준 가이드의 `auth.log` 전제와 다르니 헷갈리지 말 것.

6. **매니저 재시작 후 데몬 완전 기동에 1~2분.** `agent_control`/API가 잠깐 "Cannot find queue/db/wdb" 뱉는 건 정상(부팅 중).

7. **sudo는 암호 필요, 비루트는 시스템 journal/ossec.conf 못 읽음** (`systemd-journal` 그룹 아님). 진단 시 참고.

8. **좀비 `vmmem`**: WSL이 반복 크래시하면 보호 프로세스 `vmmem`이 남아 `Wsl/Service/CreateInstance/E_FAIL`로 재기동 불가. 확실한 복구는 **Windows 재부팅**.

---

## 6. 다음에 할 일

1. **룰 튜닝 완주** — `custom-rules/local_rules.xml`의 억제룰 적용 → 재시험 → Before/After 확인. (`docs/02` 참고)
2. **웹 공격 탐지 (OKRA 연계)** — crAPI/juiceshop 컨테이너 start → 웹 access log를 에이전트에 물리기(`<localfile>` 또는 볼륨) → 웹 룰셋으로 OKRA 공격 탐지. 이게 "진단도구(OKRA) ↔ 관제(SIEM)" 면접 핵심 스토리.
3. **스크린샷 3장 확보** (면접용): ① 브루트포스 알림+ATT&CK ② 룰 튜닝 전/후 ③ 대시보드 전체 구조.

자세한 절차/개념은 `docs/` 참고.
