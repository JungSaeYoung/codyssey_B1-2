#!/usr/bin/env bash
# 07_cron_schedule.sh
# -----------------------------------------------------------------------------
# 단계 7 / 7 — cron 스케줄 등록 (agent-admin 의 crontab)
#
#   매분  : monitor.sh 실행 → /var/log/agent-app/monitor.log 누적
#   매일 03:10 : archive_logs.sh 실행 → 7일 경과 압축 / 30일 경과 삭제
#
#   cron 은 .bashrc 를 읽지 않으므로 환경변수를 명령줄 앞에 직접 명시.
#
# 실행 위치: 머신 안 (단계 6 이후)
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

step "cron 데몬 패키지 설치 + 기동"
sudo apt-get install -y cron
# 환경(systemd/sysvinit)에 따라 되는 쪽으로 기동. enable --now 가 무력한 VM 도 있어 service 폴백.
sudo systemctl enable --now cron 2>/dev/null || sudo service cron start 2>/dev/null || true

step "agent-admin 의 crontab 에 2개 항목 등록 (기존 동일 항목은 제거 후 재등록)"
sudo -u agent-admin bash -c '
( crontab -l 2>/dev/null | grep -v "monitor.sh" | grep -v "archive_logs.sh" ;
  echo "* * * * * AGENT_HOME=/home/agent-admin/agent-app AGENT_PORT=15034 AGENT_LOG_DIR=/var/log/agent-app /home/agent-admin/agent-app/bin/monitor.sh >> /home/agent-admin/monitor.cron.log 2>&1"
  echo "10 3 * * * /home/agent-admin/agent-app/bin/archive_logs.sh >> /home/agent-admin/archive.cron.log 2>&1"
) | crontab -
'
# 새 crontab 을 확실히 반영하도록 데몬 재기동(되는 쪽으로). 실패해도 계속.
sudo systemctl restart cron 2>/dev/null || sudo service cron restart 2>/dev/null || true

# 검증
echo
echo "─── 검증 ────────────────────────────"
echo "--- crontab -u agent-admin -l ---"
sudo -u agent-admin crontab -l
echo
echo "--- cron 데몬 상태 ---"
systemctl is-active cron && echo "cron.service: active"
echo "─────────────────────────────────────"
echo "[07] Cron schedule 완료"
echo
echo "▶ 1~2분 뒤 라이브 확인:"
echo "    sudo tail -f /var/log/agent-app/monitor.log"
