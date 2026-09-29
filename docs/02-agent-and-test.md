# 에이전트 설치 + 공격 → 탐지 테스트 절차

스택이 뜬 뒤(대시보드 로그인 됨) 진행. 표적은 에이전트를 심은 호스트 자체(논리적 피해자 역할).

## A. 에이전트 설치 (Debian/Kali 기준)

매니저가 1514/1515를 호스트에 노출하므로 에이전트는 `127.0.0.1`로 붙는다.

```bash
cd /tmp
curl -so wazuh-agent.deb https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.9.2-1_amd64.deb
sudo WAZUH_MANAGER="127.0.0.1" WAZUH_AGENT_NAME="kali-victim" dpkg -i ./wazuh-agent.deb
sudo systemctl daemon-reload
sudo systemctl enable --now wazuh-agent
```
- `WAZUH_MANAGER` = 매니저 주소(1514 보고 / 1515 등록)
- `WAZUH_AGENT_NAME` = 대시보드 표시 이름
- 기동 시 authd(1515, 무암호)로 자동 등록 → 1514로 로그 전송

**확인** (매니저 쪽, sudo 불필요):
```bash
docker exec single-node-wazuh.manager-1 /var/ossec/bin/agent_control -l
```
→ `ID: 001, Name: kali-victim ... Active` 나오면 성공. 대시보드 좌측 **Agents**에서도 초록색 Active.

> 참고: Kali는 `/var/log/auth.log`가 없어(rsyslog off) 에이전트가 **journald를 직접** 읽는다. 파일 안 보인다고 당황 말 것 — 탐지는 정상.

## B. 공격 → 탐지 (SSH 브루트포스, 자기 자신 대상)

sshd가 떠 있어야 한다: `systemctl status ssh` / `ss -ltn | grep :22`.

**표적을 자기 자신(127.0.0.1)으로 두는 방어 훈련.** kali에서:
```bash
hydra -l testuser -P /usr/share/wordlists/metasploit/unix_passwords.txt -t 4 -f ssh://127.0.0.1
```
- `-l testuser` = 존재하지 않는 계정(실패 유도 — 실제 침투 아님)
- `-t 4` = 동시 4스레드(짧은 시간 다수 실패 → 빈도 룰 발동 조건)
- 몇 초면 끝. 없는 워드리스트면 `/usr/share/wordlists/`에서 작은 리스트로 대체.

**탐지 확인:**
1. 대시보드 **Security events** 새로고침 → rule 5710(개별) → 2502(브루트포스, level 10, T1110)
2. 알림 클릭 → 봐야 할 3가지: **Rule ID/Level**, **MITRE technique**, **원본 로그(full_log)**
3. 매니저에서 직접(선택):
   ```bash
   docker exec single-node-wazuh.manager-1 bash -lc 'grep -i sshd /var/ossec/logs/alerts/alerts.json | tail -3'
   ```

## C. 룰 튜닝 (오탐 억제) → 재시험

1. 커스텀 룰 적용 (이 패키지의 `custom-rules/local_rules.xml`):
   ```bash
   docker cp custom-rules/local_rules.xml single-node-wazuh.manager-1:/var/ossec/etc/rules/local_rules.xml
   ```
   (수동 편집: `docker exec -it single-node-wazuh.manager-1 vi /var/ossec/etc/rules/local_rules.xml`, `<group ...sshd,">` 안쪽에 룰 추가)

2. 문법 검증 (컨테이너 안):
   ```bash
   docker exec single-node-wazuh.manager-1 /var/ossec/bin/wazuh-logtest -t
   ```
   에러 없이 로딩되면 OK. **검증 없이 재시작하면 문법 오류 시 매니저가 안 뜰 수 있다.**

3. 반영:
   ```bash
   docker restart single-node-wazuh.manager-1   # 데몬 완전 기동 1~2분
   ```

4. **재시험** — B의 hydra를 1회 더 → 이번엔 127.0.0.1 실패가 rule 100010(level 0)으로 **억제**돼 Security events에서 사라지는지 확인. (다른 IP였다면 그대로 탐지됨)

**관측 포인트:** 5710을 억제하면 그를 기반으로 격상되던 상관룰(2502 등)이 어떻게 반응하는지도 본다. 안 죽으면 상관룰도 추가 튜닝 → 이 tune→test→refine 반복이 현실적 탐지 엔지니어링.

## D. (다음 단계) 웹 공격 탐지 — OKRA 연계

- 표적 컨테이너 start: `docker start juiceshop` (또는 crapi 스택)
- 문제: 웹 access log는 컨테이너 안, 에이전트는 호스트 → 자동으로 안 감. **로그를 에이전트에 물려야** 한다:
  - 방법1: 컨테이너 로그를 호스트 경로로 볼륨 마운트 후 에이전트 `<localfile>` 등록
  - 방법2: `docker logs`를 파일로 흘려 에이전트가 tail
- 웹 룰셋(web, attack, web_appsec 그룹)으로 OKRA의 SQLi/XSS/경로탐색 시도를 탐지 → 대시보드 확인
- 이게 "진단도구(OKRA)가 쏜 공격을 SIEM이 잡는다"는 면접 핵심 데모.
