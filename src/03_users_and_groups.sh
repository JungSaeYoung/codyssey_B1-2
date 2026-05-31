#!/usr/bin/env bash
# 03_users_and_groups.sh
# -----------------------------------------------------------------------------
# 단계 3 / 7 — 계정·그룹 구성 (역할 기반)
#
#   계정:
#     agent-admin  : 운영자 — 앱 실행 + cron 운영
#     agent-dev    : 개발자 — monitor.sh 등 자동화 스크립트 작성
#     agent-test   : QA     — 업로드/테스트만, 운영 비밀 접근 불가
#
#   그룹:
#     agent-common (admin/dev/test) → 공용 자료 (upload_files)
#     agent-core   (admin/dev)      → 민감 자원 (api_keys, /var/log/agent-app)
#                                     ↑ agent-test 는 일부러 제외 = Need-to-Know
#
# 실행 위치: 머신 안
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

step "그룹 생성: agent-common, agent-core (-f: 이미 있어도 OK)"
sudo groupadd -f agent-common
sudo groupadd -f agent-core

for u in agent-admin agent-dev agent-test; do
    if ! id "$u" >/dev/null 2>&1; then
        step "계정 생성: $u (홈 디렉토리 + /bin/bash)"
        sudo useradd -m -s /bin/bash "$u"
    else
        step "계정 이미 존재: $u (skip)"
    fi
done

step "agent-common 그룹 멤버 추가: admin, dev, test"
sudo usermod -aG agent-common agent-admin
sudo usermod -aG agent-common agent-dev
sudo usermod -aG agent-common agent-test

step "agent-core 그룹 멤버 추가: admin, dev  (test 제외 = Need-to-Know)"
sudo usermod -aG agent-core   agent-admin
sudo usermod -aG agent-core   agent-dev

# 검증
echo
echo "─── 검증 ────────────────────────────"
id agent-admin
id agent-dev
id agent-test
echo "─────────────────────────────────────"
echo "[03] Users & groups 완료"
