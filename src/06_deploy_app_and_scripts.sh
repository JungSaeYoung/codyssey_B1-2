#!/usr/bin/env bash
# 06_deploy_app_and_scripts.sh   (B1-2 버전)
# -----------------------------------------------------------------------------
# 단계 6 / 7 — agent-leak-app 바이너리 + 자동화 스크립트 배포
#
# B1-1 과 차이점:
#   * 바이너리 이름이 agent-app → agent-leak-app 로 바뀜
#   * agent-leak-app 은 운영 측이 별도로 제공 — 이 저장소의 bin/ 에 미리 두지 않음
#   * 학습자는 bin/agent-leak-app 위치에 운영 제공 파일을 배치한 뒤 본 스크립트 실행
#
#   배포 대상:
#     bin/agent-leak-app      → /home/agent-admin/agent-app/agent-leak-app  (0750)
#     src/monitor.sh          → $AGENT_HOME/bin/monitor.sh                  (0750)
#     src/report.sh           → $AGENT_HOME/bin/report.sh                   (0750)
#     src/archive_logs.sh     → $AGENT_HOME/bin/archive_logs.sh             (0750)
#
#   소유/그룹:
#     agent-leak-app  → agent-admin:agent-common (실행자가 admin)
#     *.sh            → agent-dev:agent-core    (작성자=dev, 운영자=admin 그룹 권한으로 실행)
#
# 가정: 머신 안에 원본 파일들이 한 디렉토리에 모여 있다.
#       기본값: SOURCE_DIR=/tmp (orb push 의 기본 도착지)
#       다른 위치면 SOURCE_DIR 환경변수로 지정:
#         SOURCE_DIR=/home/me/codyssey_B1-2/src bash 06_deploy_app_and_scripts.sh
#       (이때 agent-leak-app 도 같은 디렉토리에 있어야 함)
#
# 실행 위치: 머신 안 (단계 4 이후)
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

SOURCE_DIR="${SOURCE_DIR:-/tmp}"
AGENT_HOME="/home/agent-admin/agent-app"
APP_BIN="agent-leak-app"

step "원본 위치(SOURCE_DIR) = ${SOURCE_DIR}"

step "원본 파일 존재 확인"
for f in monitor.sh report.sh archive_logs.sh "${APP_BIN}"; do
    if [[ ! -f "${SOURCE_DIR}/${f}" ]]; then
        echo "[ERROR] ${SOURCE_DIR}/${f} 가 없습니다." >&2
        if [[ "${f}" == "${APP_BIN}" ]]; then
            echo "       (운영 측 제공 바이너리를 ${SOURCE_DIR}/ 에 배치한 뒤 다시 실행)" >&2
        fi
        exit 1
    fi
    printf "      ✓ %s\n" "${SOURCE_DIR}/${f}"
done

step "CRLF → LF 정리 (Windows 작성 파일 대비)"
sudo apt-get install -y dos2unix
sudo dos2unix "${SOURCE_DIR}"/monitor.sh "${SOURCE_DIR}"/report.sh \
              "${SOURCE_DIR}"/archive_logs.sh 2>&1 | sed 's/^/      /' || true

step "monitor.sh → \$AGENT_HOME/bin/monitor.sh  (agent-dev:agent-core, 0750)"
sudo install -m 0750 -o agent-dev -g agent-core \
    "${SOURCE_DIR}/monitor.sh"      "${AGENT_HOME}/bin/monitor.sh"

step "report.sh → \$AGENT_HOME/bin/report.sh  (agent-dev:agent-core, 0750)"
sudo install -m 0750 -o agent-dev -g agent-core \
    "${SOURCE_DIR}/report.sh"       "${AGENT_HOME}/bin/report.sh"

step "archive_logs.sh → \$AGENT_HOME/bin/archive_logs.sh  (agent-dev:agent-core, 0750)"
sudo install -m 0750 -o agent-dev -g agent-core \
    "${SOURCE_DIR}/archive_logs.sh" "${AGENT_HOME}/bin/archive_logs.sh"

step "${APP_BIN} → \$AGENT_HOME/${APP_BIN}  (agent-admin:agent-common, 0750)"
sudo install -m 0750 -o agent-admin -g agent-common \
    "${SOURCE_DIR}/${APP_BIN}"      "${AGENT_HOME}/${APP_BIN}"

# 검증
echo
echo "─── 검증 ────────────────────────────"
sudo ls -l "${AGENT_HOME}/bin/" "${AGENT_HOME}/${APP_BIN}"
echo "─────────────────────────────────────"
echo "[06] Deployment 완료"
echo
echo "▶ 다음 단계:"
echo "    sudo -iu agent-admin"
echo "    cd \$AGENT_HOME && ./${APP_BIN}      # 부트 시퀀스 [OK] 확인"
