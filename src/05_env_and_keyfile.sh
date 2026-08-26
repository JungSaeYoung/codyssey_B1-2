#!/usr/bin/env bash
# 05_env_and_keyfile.sh   (B1-2 버전)
# -----------------------------------------------------------------------------
# 단계 5 / 7 — 환경변수 + API 키 파일
#
# B1-1 과 차이점 (agent-leak-app 의 부트 시퀀스 조건 반영):
#   1) AGENT_KEY_PATH 가 "파일" 이 아니라 "디렉토리" 경로
#        before:  AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key
#        after :  AGENT_KEY_PATH=$AGENT_HOME/api_keys
#
#   2) 키 파일명이 secret.key (B1-1 의 t_secret.key 가 아님)
#        $AGENT_HOME/api_keys/secret.key   내용: agent_api_key_test
#
#   3) 장애 재현용 환경변수 3종 추가
#        MEMORY_LIMIT          정수, 50~512 (MB)         예: 256
#        CPU_MAX_OCCUPY        정수, 10~100 (%)          예: 80
#        MULTI_THREAD_ENABLE   true/false/1/0/yes/no    예: false
#
# 실행 위치: 머신 안 (단계 4 이후)
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

AGENT_BASHRC="/home/agent-admin/.bashrc"
KEY_PATH="/home/agent-admin/agent-app/api_keys/secret.key"

if ! sudo grep -q '^export AGENT_HOME=' "${AGENT_BASHRC}" 2>/dev/null; then
    step "$AGENT_BASHRC 에 AGENT_* / MEMORY_LIMIT / CPU_MAX_OCCUPY / MULTI_THREAD_ENABLE 추가"
    sudo -u agent-admin tee -a "${AGENT_BASHRC}" >/dev/null <<'EOF'

# ----- Agent Leak App ENV (B1-2) -----
export AGENT_HOME="/home/agent-admin/agent-app"
export AGENT_PORT="15034"
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="/var/log/agent-app"

# 장애 재현용 — 기본은 정상 가동 조합
# OOM/CPU/Deadlock 실험 시 실험_절차서.md 의 조합표대로 export 후 재실행
#   CPU_MAX_OCCUPY=10 이어야 [Healthy System Monitoring] 이 선택된다(실측).
#   95 는 정상 가동이 아니라 CPU 과점유 시나리오라 34초 만에 종료된다.
export MEMORY_LIMIT="512"
export CPU_MAX_OCCUPY="10"
export MULTI_THREAD_ENABLE="false"
EOF
else
    step "$AGENT_BASHRC 에 AGENT_* 이미 등록돼 있음 (skip)"
fi

step "키 파일 생성: $KEY_PATH (내용 = 'agent_api_key_test')"
echo "agent_api_key_test" | sudo -u agent-admin tee "${KEY_PATH}" >/dev/null

step "키 파일 소유/권한: agent-admin:agent-core, 640"
sudo chown agent-admin:agent-core "${KEY_PATH}"
sudo chmod 640 "${KEY_PATH}"

# 검증
echo
echo "─── 검증 ────────────────────────────"
echo "--- AGENT_* / 실험용 ENV (agent-admin login shell) ---"
# 주의: Ubuntu 기본 .bashrc 는 맨 위 가드("비대화형이면 return") 때문에
#   bash -lc(비대화형) 로는 .bashrc 끝에 추가한 export 가 안 보인다 → grep 0건 → set -e 사망.
#   실제 로그인처럼 대화형(-i)으로 .bashrc 를 로드해 확인하고, 그래도 비면
#   .bashrc 에 등록된 export 를 그대로 보여준다. (어느 쪽도 못 찾으면 || true 로 데모는 계속)
sudo -u agent-admin bash -lic \
    'env | grep -E "^(AGENT_|MEMORY_LIMIT|CPU_MAX_OCCUPY|MULTI_THREAD_ENABLE)"' 2>/dev/null \
  || sudo grep -E '^export (AGENT_|MEMORY_LIMIT|CPU_MAX_OCCUPY|MULTI_THREAD_ENABLE)' "${AGENT_BASHRC}" \
  || true
echo
echo "--- 키 파일 ---"
sudo ls -l "${KEY_PATH}"
sudo cat "${KEY_PATH}"
echo "─────────────────────────────────────"
echo "[05] Env vars & key file 완료"
