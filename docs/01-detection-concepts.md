# SIEM은 어떻게 탐지하는가 (Wazuh 파이프라인)

로그 한 줄이 "공격"으로 판정돼 화면에 뜨기까지 내부에서 벌어지는 일.

## 전체 파이프라인

```
로그 한 줄  →  [로그수집]  →  [디코더]  →  [룰]  →  [알림생성]  →  [저장]  →  [대시보드]
 (엔드포인트)   logcollector   필드 추출   조건매칭   레벨판정      indexer     Security
               (에이전트)     (매니저)    (매니저)   (매니저)     (OpenSearch)  events
```

핵심은 매니저 안의 **`analysisd`** 데몬. 여기서 **디코더 → 룰** 두 단계를 돈다. (랩 트러블슈팅에서 그렇게 살리려던 그 데몬)

## 단계별

### 1. 로그 수집 — 에이전트 `logcollector`
에이전트 `ossec.conf`에 등록된 소스를 실시간 tail. Kali는 auth.log가 없어 journald를 직접 읽는다:
```xml
<localfile>
  <log_format>journald</log_format>
  <location>journald</location>
</localfile>
```
가공 없이 매니저로 전송(1514, 암호화). 에이전트는 "눈", 판단은 매니저가.

### 2. 디코더 — 로그를 필드로 쪼갬
원본:
```
Sep 29 05:52:25 host sshd-session[7611]: Failed password for invalid user ssh from 127.0.0.1 port 45940 ssh2
```
추출:
```
program_name = sshd    srcuser = ssh    srcip = 127.0.0.1
```
필드가 있어야 룰이 "이 IP", "이 계정" 같은 조건을 건다. (`/var/ossec/ruleset/decoders/`)

### 3. 룰 — 조건 매칭 → 경보 승격
개별 실패(atomic rule):
```xml
<rule id="5710" level="5">
  <decoded_as>sshd</decoded_as>
  <match>Failed password|authentication failure</match>
  <description>sshd: 존재하지 않는 계정 로그인 시도</description>
</rule>
```
실패 한 번은 오타일 수 있다. 브루트포스는 "짧은 시간에 여러 번" → **상관분석(correlation) 룰**:
```xml
<rule id="5712" level="10" frequency="8" timeframe="120">
  <if_matched_sid>5710</if_matched_sid>
  <description>sshd: 브루트포스 (T1110)</description>
  <mitre><id>T1110</id></mitre>
</rule>
```
- `if_matched_sid` = 다른 룰이 먼저 떠야 작동(체이닝)
- `frequency`+`timeframe` = 시간축 누적을 봄 → **SIEM이 "패턴"을 잡는 방식**
- `mitre` = ATT&CK 기법 매핑

### 4. 알림 생성 — 레벨로 거름
룰 매칭 이벤트가 전부 알림은 아님. `<log_alert_level>` 임계값 이상만 `alerts.json`에 기록.

| 레벨 | 의미 |
|---|---|
| 0 | 무시(오탐 억제용) |
| 3~5 | 참고/저위험 |
| 7~9 | 주의 |
| 10~12 | 공격 성립 가능성 높음 |
| 13~15 | 심각/즉시대응 |

### 5. 저장 & 시각화
`alerts.json` → **filebeat** → **indexer(OpenSearch)** 색인 → 대시보드가 쿼리해 표시.
(트러블슈팅에서 본 `Connection to wazuh.indexer:9200 established`가 이 배선. 죽으면 탐지돼도 화면에 안 뜸.)

## 실제 관측된 브루트포스 체인 (이 랩에서)

우리가 본 알림 (버전 4.9.2 룰셋):

| Rule ID | Level | 설명 | MITRE |
|---|---|---|---|
| 5710 | 5 | 존재하지 않는 계정 로그인 시도(누적) | T1110.001 |
| 5758 | 8 | 최대 인증 시도 초과 | T1110 |
| 2502 | **10** | 비밀번호 여러 번 틀림 = 브루트포스 확정 | T1110 |

`full_log`에 원본 로그가 그대로 남아 역추적 가능. **원본 로그 → 어떤 한 줄이 이 알림을 만들었나를 추적하는 게 분석가의 일.**

## 두 개의 탐지 축 — 헷갈리지 말 것

| | Security events | Configuration Assessment (SCA / Endpoint) |
|---|---|---|
| 뭘 보나 | 실시간 로그(행위) | 시스템 설정 상태(스냅샷) |
| 트리거 | 이벤트 발생 즉시 | 타이머(기본 12h) 또는 에이전트 시작 |
| 판정 위치 | 매니저 analysisd(룰엔진) | **에이전트 자신**이 로컬 스크립트로 판정 후 결과만 전송 |
| 결과 | 알림(Level 0~15) | Passed/Failed (CIS 벤치마크) |
| 비유 | "지금 누가 문을 두드린다" | "문 잠금장치가 제대로 달렸나 점검" |

- Security events = 사후 탐지(reactive). SCA = 사전 하드닝 점검(proactive).
- 브루트포스를 100번 더 돌려도 SCA 결과는 안 바뀐다(이벤트가 아니라 상태라서).
- SCA 강제 재스캔 API는 **없다**(`/sca/{agent}`는 GET만). 지금 다시 스캔하려면 **에이전트 재시작**(`scan_on_start`) 또는 `interval` 값을 줄인다.

## 오탐/룰 튜닝이 왜 중요한가 (OKRA 연결)

`frequency=8`을 생각해보라:
- 3으로 낮추면 → 정상 사용자 3번 틀려도 "브루트포스" → **오탐**
- 50으로 올리면 → 느린 공격 놓침 → **미탐**

관제 실력 = 이 균형. 방법 3가지:
1. **조건 좁히기** — 특정 IP/계정/조건만
2. **정상 행위 억제** — 내부 점검 IP 실패는 레벨 0 (`local_rules.xml`)
3. **중요 이벤트 격상** — root SSH 성공은 레벨 12

이게 OKRA의 "성립검증으로 오탐 거르기"와 **완전히 같은 문제** — 도메인만 다르고 사고방식 동일.
