#!/usr/bin/env bash
# 00_run_all.sh
# -----------------------------------------------------------------------------
# 미션 setup 7 단계를 한 번에 실행하는 wrapper.
# 학습 목적이라면 각 01~07 스크립트를 직접 한 줄씩 실행하며 결과를 살펴 보길 권장.
#
# 사용:
#   bash 00_run_all.sh
#
#   # 다른 디렉토리에 src/ + bin/ 를 푸시했다면:
#   SOURCE_DIR=/some/path bash 00_run_all.sh
#
# 실행 위치: 머신 안 (모든 원본 파일이 SOURCE_DIR 에 모여 있어야 함)
# -----------------------------------------------------------------------------

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SOURCE_DIR="${SOURCE_DIR:-$HERE}"

STEPS=(
    "01_ssh_hardening.sh"
    "02_firewall_allowlist.sh"
    "03_users_and_groups.sh"
    "04_directories_and_acl.sh"
    "05_env_and_keyfile.sh"
    "06_deploy_app_and_scripts.sh"
    "07_cron_schedule.sh"
)

TOTAL="${#STEPS[@]}"
i=0
for step in "${STEPS[@]}"; do
    i=$((i + 1))
    echo
    echo "════════════════════════════════════════════════════════════════════"
    printf "▶ 단계 %d / %d :  %s\n" "$i" "$TOTAL" "$step"
    echo "════════════════════════════════════════════════════════════════════"
    bash "${HERE}/${step}"
done

echo
echo "════════════════════════════════════════════════════════════════════"
echo "✓ 모든 setup 단계 (01~07) 완료 — 총 $TOTAL 단계"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "다음 행동:"
echo "  1) agent-leak-app 실행 → 부트 시퀀스 [OK] 확인"
echo "       sudo -iu agent-admin"
echo "       cd \$AGENT_HOME && ./agent-leak-app"
echo "  2) monitor.sh 수동 실행 (다른 터미널에서)"
echo "       sudo -iu agent-admin /home/agent-admin/agent-app/bin/monitor.sh"
echo "  3) cron 누적 라이브 보기"
echo "       sudo tail -f /var/log/agent-app/monitor.log"
echo "  4) 장애 실험 절차서 따라 MEMORY_LIMIT / CPU_MAX_OCCUPY / MULTI_THREAD_ENABLE 조합 변경"
echo "       cat /path/to/codyssey_B1-2/실험_절차서.md"
