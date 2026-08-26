#!/usr/bin/env bash
# monitor.sh — 시스템 상태 수집 및 로깅 스크립트
# 위치: $AGENT_HOME/bin/monitor.sh
# 소유: agent-dev:agent-core, 권한 750
# 실행: agent-admin (cron, 매분)

set -u

# ────────────────────────────────────────────────────────────────────────────
# 0) 설정
# ────────────────────────────────────────────────────────────────────────────
APP_NAME="${APP_NAME:-agent-leak-app}"
APP_PORT="${AGENT_PORT:-15034}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="${LOG_DIR}/monitor.log"

# 임계값
# B1-2: agent-leak-app 은 메모리 누수/CPU 과점유를 의도적으로 발생시키므로
#       경고 라인이 자주 찍히도록 임계값을 보수적으로 잡는다.
CPU_THRESHOLD=20
MEM_THRESHOLD=10
DISK_THRESHOLD=80

# 로그 로테이션 정책
MAX_LOG_SIZE=$((10 * 1024 * 1024))   # 10MB
MAX_LOG_FILES=10

TS="$(date '+%Y-%m-%d %H:%M:%S')"

# ────────────────────────────────────────────────────────────────────────────
# 1) Health Check (실패 시 exit 1)
# ────────────────────────────────────────────────────────────────────────────
echo "====== SYSTEM MONITOR RESULT ======"
echo ""
echo "[HEALTH CHECK]"

# 1-1) 프로세스 확인
# pgrep -x : 프로세스 이름(comm)과 정확히 일치하는 것만. -f 는 cmdline 전체를 보므로
# "agent-app" 이 디렉토리 경로($AGENT_HOME=/home/agent-admin/agent-app/...)에도 등장해
# monitor.sh 자신을 매칭해버리는 자기참조 문제를 피한다.
APP_PID="$(pgrep -x "${APP_NAME}" | head -n1 || true)"
if [[ -z "${APP_PID}" ]]; then
    echo "Checking process '${APP_NAME}'... [FAIL]"
    echo "[ERROR] Application process not running."
    exit 1
fi
# PyInstaller onefile 바이너리는 "부트로더(부모)" 가 압축을 풀고 "실제 앱(자식)" 을 fork 한다.
# 부모는 2MB 안팎의 스텁이라 여기서 RSS/CPU 를 읽으면 워크로드가 전혀 보이지 않는다
# (실측: 부모 RSS 2.1MB 고정 / 자식 RSS 18MB→300MB). 같은 이름의 자식이 있으면
# 그쪽을 관측 대상 PID 로 삼는다 — 앱이 스스로 남기는 "Self-terminating process N" 의 N 과도 일치한다.
APP_CHILD="$(pgrep -P "${APP_PID}" -x "${APP_NAME}" 2>/dev/null | head -n1 || true)"
[[ -n "${APP_CHILD}" ]] && APP_PID="${APP_CHILD}"

echo "Checking process '${APP_NAME}'... [OK] (PID: ${APP_PID})"

# 1-2) 포트 LISTEN 확인 (ss 사용, 미존재 시 netstat 폴백)
if command -v ss >/dev/null 2>&1; then
    PORT_OK=$(ss -tlnH 2>/dev/null | awk -v p=":${APP_PORT}" '$4 ~ p {print "Y"; exit}')
else
    PORT_OK=$(netstat -tln 2>/dev/null | awk -v p=":${APP_PORT}" '$4 ~ p {print "Y"; exit}')
fi
if [[ "${PORT_OK}" != "Y" ]]; then
    echo "Checking port ${APP_PORT}... [FAIL]"
    echo "[ERROR] Port ${APP_PORT} is not in LISTEN state."
    exit 1
fi
echo "Checking port ${APP_PORT}... [OK]"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 2) 상태 점검 (경고만)
# ────────────────────────────────────────────────────────────────────────────
FIREWALL_OK="N"
# 방화벽 활성 여부 판단 — 일반 사용자(agent-admin/cron) 에서도 sudo 없이 동작해야 함.
#   1) systemd unit 활성: 정석적 방법
#   2) /etc/ufw/ufw.conf 의 ENABLED=yes: OrbStack 등 일부 환경에서 ufw 룰은
#      적용됐지만 systemd unit 이 inactive 로 잡히는 케이스를 위한 fallback
#      (이 파일은 기본 644 라 일반 사용자도 read 가능)
#   3) firewalld 도 같은 식으로 확인
if systemctl is-active --quiet ufw 2>/dev/null; then
    FIREWALL_OK="Y"
elif [ -r /etc/ufw/ufw.conf ] && grep -qE '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    FIREWALL_OK="Y"
elif systemctl is-active --quiet firewalld 2>/dev/null; then
    FIREWALL_OK="Y"
fi
if [[ "${FIREWALL_OK}" != "Y" ]]; then
    echo "[WARNING] Firewall is not active."
fi

# ────────────────────────────────────────────────────────────────────────────
# 3) 자원 수집
# ────────────────────────────────────────────────────────────────────────────
# ── (a) 시스템 전체 지표 (SYS_*) ───────────────────────────────────────────
# CPU 사용률 (%) — top 1회 샘플링
SYS_CPU="$(top -bn1 | awk -F'[ ,]+' '/Cpu\(s\)/ {for(i=1;i<=NF;i++) if ($i ~ /id$/) {print 100 - $(i-1); exit}}')"
[[ -z "${SYS_CPU}" ]] && SYS_CPU="0.0"
SYS_CPU="$(printf "%.1f" "${SYS_CPU}")"

# 메모리 사용률 (%) — free 는 "호스트 전체" 값이다. 대상 프로세스의 heap 증가는
# 여기 거의 반영되지 않으므로(실측: 앱 heap 0→300MB 동안 35.5%→35.6%) 아래 PROC_* 와 반드시 함께 본다.
SYS_MEM="$(free | awk '/^Mem:/ {printf "%.1f", $3/$2*100}')"
[[ -z "${SYS_MEM}" ]] && SYS_MEM="0.0"

# ── (b) 대상 프로세스 지표 (PROC_*) — B1-2-A1 / B1-2-A4 가 요구하는 "특정 프로세스" ──
# PROC_RSS : 물리 메모리(Resident Set Size). ps 는 KB 로 주므로 MB 로 환산한다.
# PROC_CPU : ps 의 %CPU 는 "프로세스 시작 이후 누적 평균" 이다. 1회성 cron 관제에서는
#            순간값을 얻을 수단이 없어(top -bn1 도 첫 샘플은 동일하게 누적값) 누적 평균을 기록한다.
# pgrep 직후 프로세스가 죽어 ps 가 빈 값을 주더라도 컬럼이 깨지지 않도록 기본값을 둔다.
PROC_RSS_KB="$(ps -o rss= -p "${APP_PID}" 2>/dev/null | awk 'NR==1 {gsub(/[^0-9]/,""); print}')"
[[ -z "${PROC_RSS_KB}" ]] && PROC_RSS_KB="0"
PROC_RSS="$(awk -v k="${PROC_RSS_KB}" 'BEGIN {printf "%.1f", k/1024}')"

PROC_CPU="$(ps -o pcpu= -p "${APP_PID}" 2>/dev/null | awk 'NR==1 {gsub(/[^0-9.]/,""); print}')"
[[ -z "${PROC_CPU}" ]] && PROC_CPU="0.0"
PROC_CPU="$(printf "%.1f" "${PROC_CPU}")"

# 디스크 사용률 (root 파티션)
DISK_USED="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
[[ -z "${DISK_USED}" ]] && DISK_USED="0"

echo "[RESOURCE MONITORING]"
printf "SYS  CPU Usage : %s%%\n" "${SYS_CPU}"
printf "SYS  MEM Usage : %s%%\n" "${SYS_MEM}"
printf "PROC CPU (avg) : %s%%   (PID %s)\n" "${PROC_CPU}" "${APP_PID}"
printf "PROC RSS       : %s MB (PID %s)\n" "${PROC_RSS}" "${APP_PID}"
printf "DISK Used      : %s%%\n" "${DISK_USED}"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 4) 임계값 경고
# ────────────────────────────────────────────────────────────────────────────
awk -v v="${SYS_CPU}" -v t="${CPU_THRESHOLD}" 'BEGIN {exit !(v+0 > t+0)}' \
    && echo "[WARNING] SYS CPU threshold exceeded (${SYS_CPU}% > ${CPU_THRESHOLD}%)"
awk -v v="${SYS_MEM}" -v t="${MEM_THRESHOLD}" 'BEGIN {exit !(v+0 > t+0)}' \
    && echo "[WARNING] SYS MEM threshold exceeded (${SYS_MEM}% > ${MEM_THRESHOLD}%)"
awk -v v="${PROC_CPU}" -v t="${CPU_THRESHOLD}" 'BEGIN {exit !(v+0 > t+0)}' \
    && echo "[WARNING] PROC CPU threshold exceeded (${PROC_CPU}% > ${CPU_THRESHOLD}%, PID ${APP_PID})"
awk -v v="${DISK_USED}"  -v t="${DISK_THRESHOLD}" 'BEGIN {exit !(v+0 > t+0)}' \
    && echo "[WARNING] DISK threshold exceeded (${DISK_USED}% > ${DISK_THRESHOLD}%)"

# ────────────────────────────────────────────────────────────────────────────
# 5) 로그 기록
# ────────────────────────────────────────────────────────────────────────────
if [[ ! -d "${LOG_DIR}" ]]; then
    echo "[ERROR] Log directory not found: ${LOG_DIR}" >&2
    exit 1
fi
if [[ ! -w "${LOG_DIR}" ]]; then
    echo "[ERROR] Log directory not writable: ${LOG_DIR}" >&2
    exit 1
fi

# 컬럼 이름으로 시스템(SYS_*) / 대상 프로세스(PROC_*) 를 구분한다.
#   예) [2026-08-26 08:20:01] PID:2673158 SYS_CPU:6.2% SYS_MEM:35.6% PROC_CPU:2.0% PROC_RSS:18.1MB DISK_USED:9%
# (파서: src/report.sh, verify_orbstack.sh v_monitor, src/experiments/lib_experiment.sh _sample_to)
LOG_LINE="[${TS}] PID:${APP_PID} SYS_CPU:${SYS_CPU}% SYS_MEM:${SYS_MEM}% PROC_CPU:${PROC_CPU}% PROC_RSS:${PROC_RSS}MB DISK_USED:${DISK_USED}%"
echo "${LOG_LINE}" >> "${LOG_FILE}"
echo ""
echo "[INFO] Log appended: ${LOG_FILE}"

# ────────────────────────────────────────────────────────────────────────────
# 6) 로그 로테이션 (size-based, 자체 구현)
#    monitor.log > 10MB → monitor.log.1 ... monitor.log.10 까지 보관
# ────────────────────────────────────────────────────────────────────────────
if [[ -f "${LOG_FILE}" ]]; then
    SIZE="$(stat -c %s "${LOG_FILE}" 2>/dev/null || wc -c < "${LOG_FILE}")"
    if [[ "${SIZE}" -ge "${MAX_LOG_SIZE}" ]]; then
        # 가장 오래된 것부터 제거 후 한 칸씩 밀기
        rm -f "${LOG_FILE}.${MAX_LOG_FILES}"
        for ((i=MAX_LOG_FILES-1; i>=1; i--)); do
            [[ -f "${LOG_FILE}.${i}" ]] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
        done
        mv "${LOG_FILE}" "${LOG_FILE}.1"
        : > "${LOG_FILE}"
    fi
fi

exit 0
