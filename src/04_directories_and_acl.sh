#!/usr/bin/env bash
# 04_directories_and_acl.sh
# -----------------------------------------------------------------------------
# 단계 4 / 7 — 디렉토리 구조 + 권한 + ACL
#
#   $AGENT_HOME = /home/agent-admin/agent-app
#   ├── upload_files/   (group=agent-common, 770, default ACL)
#   ├── api_keys/       (group=agent-core,   770, default ACL)
#   └── bin/            (실행 스크립트 보관소, 750)
#   /var/log/agent-app/ (group=agent-core,   770, default ACL)
#
#   default ACL 의 이유: 신규 파일이 생겨도 그룹 권한이 풀리지 않도록 자동 상속.
#   monitor.sh 가 매분 로그를 쓰는 환경에서 정책 무결성 유지에 필수.
#
# 실행 위치: 머신 안 (단계 3 이후)
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

AGENT_HOME="/home/agent-admin/agent-app"
LOG_DIR="/var/log/agent-app"

step "acl 패키지 설치 (setfacl/getfacl 제공)"
sudo apt-get install -y acl

step "디렉토리 생성: $AGENT_HOME/{upload_files,api_keys,bin}"
sudo -u agent-admin mkdir -p "${AGENT_HOME}/upload_files" \
                             "${AGENT_HOME}/api_keys" \
                             "${AGENT_HOME}/bin"
step "디렉토리 생성: $LOG_DIR"
sudo mkdir -p "${LOG_DIR}"

step "소유자/그룹 설정"
sudo chown -R agent-admin:agent-common "${AGENT_HOME}"
sudo chgrp -R agent-core "${AGENT_HOME}/api_keys"
sudo chown root:agent-core "${LOG_DIR}"

step "POSIX 모드 비트 설정 (chmod)"
sudo chmod 750 "${AGENT_HOME}"
sudo chmod 770 "${AGENT_HOME}/upload_files"
sudo chmod 770 "${AGENT_HOME}/api_keys"
sudo chmod 770 "${LOG_DIR}"
sudo chmod 750 "${AGENT_HOME}/bin"

step "ACL 부여: upload_files → agent-common (rwx + default 상속)"
sudo setfacl -m  g:agent-common:rwx "${AGENT_HOME}/upload_files"
sudo setfacl -dm g:agent-common:rwx "${AGENT_HOME}/upload_files"

step "ACL 부여: api_keys → agent-core (rwx + default 상속)"
sudo setfacl -m  g:agent-core:rwx "${AGENT_HOME}/api_keys"
sudo setfacl -dm g:agent-core:rwx "${AGENT_HOME}/api_keys"

step "ACL 부여: $LOG_DIR → agent-core (rwx + default 상속)"
sudo setfacl -m  g:agent-core:rwx "${LOG_DIR}"
sudo setfacl -dm g:agent-core:rwx "${LOG_DIR}"

# 검증
echo
echo "─── 검증 ────────────────────────────"
sudo ls -ld "${AGENT_HOME}" "${AGENT_HOME}/upload_files" \
            "${AGENT_HOME}/api_keys" "${LOG_DIR}"
echo
echo "--- getfacl: upload_files ---"
sudo getfacl "${AGENT_HOME}/upload_files"
echo
echo "--- getfacl: api_keys ---"
sudo getfacl "${AGENT_HOME}/api_keys"
echo
echo "--- getfacl: $LOG_DIR ---"
sudo getfacl "${LOG_DIR}"
echo "─────────────────────────────────────"
echo "[04] Directories & ACL 완료"
