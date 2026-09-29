#!/usr/bin/env bash
# Wazuh SIEM 랩 부트스트랩 — 다른 로컬에서 재현용
# 사용법:
#   bash setup.sh            # 온라인: 공식 repo 클론 + 이미지 pull
#   bash setup.sh --offline  # 폐쇄망: 이미지는 미리 docker load 해둔 상태 가정
#
# 하는 일: wazuh-docker(v4.9.2) 준비 → 인증서 생성 → up -d → 커스텀 룰 적용 → 상태 출력
set -euo pipefail

WAZUH_TAG="v4.9.2"
WORKDIR="${WAZUH_WORKDIR:-$HOME/wazuh-docker}"
SINGLE="$WORKDIR/single-node"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31m[에러] %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. 사전 점검 ---
say "사전 점검"
command -v docker >/dev/null || die "docker 없음. 먼저 설치."
docker compose version >/dev/null 2>&1 || die "docker compose(v2) 없음."
if [ -r /proc/sys/vm/max_map_count ]; then
  mmc=$(cat /proc/sys/vm/max_map_count)
  if [ "$mmc" -lt 262144 ]; then
    echo "vm.max_map_count=$mmc (< 262144). 인덱서용으로 올리는 중..."
    sudo sysctl -w vm.max_map_count=262144 || echo "  (권한 없으면 수동: sudo sysctl -w vm.max_map_count=262144)"
  fi
fi

# --- 1. wazuh-docker 준비 ---
if [ ! -d "$SINGLE" ]; then
  if [ "$OFFLINE" -eq 1 ]; then
    die "오프라인인데 $SINGLE 가 없다. 공식 repo(single-node 포함)를 미리 복사해두거나, compose/ 폴더를 수동 배치하라."
  fi
  say "wazuh-docker $WAZUH_TAG 클론"
  git clone https://github.com/wazuh/wazuh-docker.git -b "$WAZUH_TAG" --depth=1 "$WORKDIR"
else
  echo "$SINGLE 이미 존재 — 재사용"
fi

# 이 패키지의 compose 원본으로 덮어쓰기(로컬 수정본 반영). 없으면 공식 것 사용.
if [ -f "$SCRIPT_DIR/compose/docker-compose.yml" ]; then
  cp "$SCRIPT_DIR/compose/docker-compose.yml" "$SINGLE/docker-compose.yml"
  echo "패키지 compose 적용됨"
fi

cd "$SINGLE"

# --- 2. 인증서 생성 (첫 기동 전 필수! 안 하면 인덱서 크래시 루프) ---
if [ ! -f "$SINGLE/config/wazuh_indexer_ssl_certs/root-ca.pem" ]; then
  say "인증서 생성"
  docker compose -f generate-indexer-certs.yml run --rm generator
else
  echo "인증서 이미 존재 — 생성 생략"
fi

# --- 3. 기동 ---
say "스택 기동 (docker compose up -d)"
docker compose up -d

# --- 4. 커스텀 룰 적용 (오탐 억제 튜닝) ---
if [ -f "$SCRIPT_DIR/custom-rules/local_rules.xml" ]; then
  say "커스텀 룰 적용 대기 (매니저 기동까지 ~90초)"
  sleep 90
  if docker cp "$SCRIPT_DIR/custom-rules/local_rules.xml" \
       single-node-wazuh.manager-1:/var/ossec/etc/rules/local_rules.xml 2>/dev/null; then
    echo "local_rules.xml 주입 완료 → 매니저 재시작"
    docker restart single-node-wazuh.manager-1
  else
    echo "  (매니저 컨테이너명이 다르면 수동 적용: docker cp ... <manager>:/var/ossec/etc/rules/local_rules.xml)"
  fi
fi

# --- 5. 상태 출력 ---
say "정착 대기 (~120초)"
sleep 120
say "결과"
docker compose ps
IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
echo
echo "대시보드 : https://${IP:-<호스트IP>}:443   (admin / SecretPassword)"
echo "매니저 API: https://${IP:-<호스트IP>}:55000 (wazuh-wui / MyS3cr37P450r.*-)"
echo
echo "인덱서 헬스 확인:"
docker exec single-node-wazuh.indexer-1 \
  curl -sk -u admin:SecretPassword https://localhost:9200/_cluster/health 2>/dev/null | head -c 120 || true
echo
echo "다음: docs/02-agent-and-test.md 로 에이전트 붙이고 공격→탐지 테스트"
