#!/usr/bin/env bash
# report.sh — monitor.log 분석 리포트 (보너스 1)
# 사용법:
#   ./report.sh                       # 전체 로그 분석
#   ./report.sh "2026-02-25 13:00:00" "2026-02-25 14:00:00"   # 구간 분석

set -u

LOG_FILE="${AGENT_LOG_DIR:-/var/log/agent-app}/monitor.log"

START_TS="${1:-}"
END_TS="${2:-}"

if [[ ! -f "${LOG_FILE}" ]]; then
    echo "[ERROR] Log file not found: ${LOG_FILE}" >&2
    exit 1
fi

# 로그 라인 포맷:
# [YYYY-MM-DD HH:MM:SS] PID:1234 CPU:25.3% MEM:5.2% DISK_USED:23%
# AWK로 시작/종료 시각 필터 + 통계 계산
# ※ 변수명에 'END' / 'START' 를 쓰면 일부 awk(예: mawk) 가 BEGIN/END 키워드와 충돌해
#   "cannot command line assign to END" 에러가 난다. 그래서 ts_start / ts_end 로 사용.
awk -v ts_start="${START_TS}" -v ts_end="${END_TS}" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

{
    # 시각 추출: [YYYY-MM-DD HH:MM:SS]
    if (match($0, /\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/)) {
        ts = substr($0, RSTART+1, RLENGTH-2)
    } else { next }

    # 구간 필터
    if (ts_start != "" && ts < ts_start) next
    if (ts_end   != "" && ts > ts_end)   next

    # 값 추출
    cpu = ""; mem = ""; disk = ""
    if (match($0, /CPU:[0-9.]+%/))       cpu  = substr($0, RSTART+4, RLENGTH-5)
    if (match($0, /MEM:[0-9.]+%/))       mem  = substr($0, RSTART+4, RLENGTH-5)
    if (match($0, /DISK_USED:[0-9.]+%/)) disk = substr($0, RSTART+10, RLENGTH-11)
    if (cpu == "" || mem == "" || disk == "") next

    n++
    cpu_sum += cpu; mem_sum += mem; disk_sum += disk
    if (n == 1 || cpu+0  > cpu_max+0)  { cpu_max  = cpu;  cpu_max_ts  = ts }
    if (n == 1 || cpu+0  < cpu_min+0)  { cpu_min  = cpu;  cpu_min_ts  = ts }
    if (n == 1 || mem+0  > mem_max+0)  { mem_max  = mem;  mem_max_ts  = ts }
    if (n == 1 || mem+0  < mem_min+0)  { mem_min  = mem;  mem_min_ts  = ts }
    if (n == 1 || disk+0 > disk_max+0) { disk_max = disk; disk_max_ts = ts }
    if (n == 1 || disk+0 < disk_min+0) { disk_min = disk; disk_min_ts = ts }
}
END {
    print "====== STATISTICS REPORT ======"
    if (n == 0) {
        print "[INFO] No samples in the given range."
        exit 0
    }
    printf "  [CPU]\n"
    printf "    Average : %.1f%%\n", cpu_sum/n
    printf "    Maximum : %s%% at %s\n", cpu_max, cpu_max_ts
    printf "    Minimum : %s%% at %s\n", cpu_min, cpu_min_ts
    printf "  [Memory]\n"
    printf "    Average : %.1f%%\n", mem_sum/n
    printf "    Maximum : %s%% at %s\n", mem_max, mem_max_ts
    printf "    Minimum : %s%% at %s\n", mem_min, mem_min_ts
    printf "  [Disk]\n"
    printf "    Average : %.1f%%\n", disk_sum/n
    printf "    Maximum : %s%% at %s\n", disk_max, disk_max_ts
    printf "    Minimum : %s%% at %s\n", disk_min, disk_min_ts
    printf "  [Samples]\n"
    printf "    Data Points: %d samples\n", n
}
' "${LOG_FILE}"
