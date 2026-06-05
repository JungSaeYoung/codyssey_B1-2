#!/usr/bin/env bash
# 03_deadlock.sh — Deadlock(무응답/freeze) 장애 재현·검증
# -----------------------------------------------------------------------------
# 실험_절차서.md §3 에 대응.
#   Before  MULTI_THREAD_ENABLE=true   → PID 는 살아있지만 로그/리소스 정지(freeze) 관측
#   After   MULTI_THREAD_ENABLE=false  → 정상 가동(freeze 없음 + curl 응답) 회피 검증
#   증거    deadlock_monitor.log / deadlock_app.log / deadlock_ps_top.txt
#           (절차서 3-2 의 6종 증거: ps -ef / ps stat / top -H / ps -L wchan / curl / app 로그)
#
# OOM·CPU 와 달리 "자가 종료" 가 아니라 "freeze" 형이라 _watch_freeze 로 판정한다.
#
# 단독 실행:  bash 03_deadlock.sh            (사전점검 → Deadlock 실험 → 요약)
# 옵션 예:    QUICK=1 bash 03_deadlock.sh    RUN_AFTER=0 bash 03_deadlock.sh
# 일괄 실행:  bash 00_run_experiments.sh deadlock
# -----------------------------------------------------------------------------

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_experiment.sh"

experiment_deadlock() {
    local MON="${EVIDENCE_DIR}/deadlock_monitor.log"
    local APPF="${EVIDENCE_DIR}/deadlock_app.log"
    local PSF="${EVIDENCE_DIR}/deadlock_ps_top.txt"
    : > "$MON"; : > "$APPF"; : > "$PSF"

    # ===== Before: MULTI_THREAD_ENABLE=true =====
    banner "Deadlock 실험 — Before (MULTI_THREAD_ENABLE=true)"
    step "환경: export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95 MULTI_THREAD_ENABLE=true"
    export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95 MULTI_THREAD_ENABLE=true
    _kill_leftovers
    printf '# ── Deadlock Before (MULTI_THREAD_ENABLE=true) start %s ──\n' "$(date '+%F %T')" >> "$MON"

    local pid; pid="$(launch_app "$APP_LOG")"; CURRENT_PID="$pid"
    pid="$(_confirm_pid "$pid")"; CURRENT_PID="$pid"
    step "PID=${pid} 무응답(freeze) 대기 (최대 $(fmt "$DEADLOCK_TIMEOUT"), $(fmt "$FREEZE_SECS") 무변화 시 freeze)"

    _watch_freeze "$pid" "$DEADLOCK_TIMEOUT" "$MON"
    local rc=$?
    local alive_before="no" before_curl="N/A" wchan_hit="no"
    if [[ "$rc" -eq 0 ]]; then
        app_alive "$pid" && alive_before="yes"
        info "freeze 감지 — PID 생존=${alive_before}, 증거 캡처"
        _snapshot_deadlock "$pid" "$PSF"
        before_curl="$(_curl_probe)"
        # 절차서 §3-2 의 futex_wait_queue_me 등 커널 버전별 wchan 명칭 차이를 흡수하려 futex* 계열을 포괄 매칭
        ps -L -p "$pid" -o wchan:30 2>/dev/null | grep -q futex && wchan_hit="yes"
        _append_app_evidence "Before  (MULTI_THREAD_ENABLE=true) — 마지막 라인에서 정지" "$APPF"
    elif [[ "$rc" -eq 1 ]]; then
        warn "Before: 프로세스가 예기치 않게 종료됨 (freeze 아님)"
        _append_app_evidence "Before (예기치 않은 종료)" "$APPF"
    else
        warn "Before: $(fmt "$DEADLOCK_TIMEOUT") 내 freeze 미발생"
        _snapshot_deadlock "$pid" "$PSF"
        _append_app_evidence "Before (freeze 미발생)" "$APPF"
    fi
    kill_app "$pid"; CURRENT_PID=""

    # ===== After: MULTI_THREAD_ENABLE=false → 정상 가동 검증 =====
    local after_frozen="N/A" after_curl="N/A" after_alive="no"
    if [[ "$RUN_AFTER" == "1" ]]; then
        banner "Deadlock 실험 — After (MULTI_THREAD_ENABLE=false)"
        step "정상 가동 검증 ($(fmt "$DEADLOCK_AFTER_VERIFY") 동안 freeze 없음 + curl 응답 확인)"
        export MULTI_THREAD_ENABLE=false MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95
        _kill_leftovers
        printf '# ── Deadlock After (MULTI_THREAD_ENABLE=false) start %s ──\n' "$(date '+%F %T')" >> "$MON"

        pid="$(launch_app "$APP_LOG")"; CURRENT_PID="$pid"
        pid="$(_confirm_pid "$pid")"; CURRENT_PID="$pid"
        _watch_freeze "$pid" "$DEADLOCK_AFTER_VERIFY" "$MON"
        local arc=$?       # 0=froze(나쁨) 1=died(나쁨) 2=freeze없음(좋음)
        app_alive "$pid" && after_alive="yes"
        case "$arc" in
            2) after_frozen="no";  info "검증 구간 동안 freeze 없음 (정상 가동)";;
            0) after_frozen="yes"; warn "After 에서도 freeze 발생";;
            1) after_frozen="died"; warn "After 에서 프로세스 조기 종료";;
        esac
        after_curl="$(_curl_probe)"
        _snapshot_deadlock "$pid" "$PSF"
        _append_app_evidence "After  (MULTI_THREAD_ENABLE=false) — 정상 가동" "$APPF"
        kill_app "$pid"; CURRENT_PID=""
    fi

    # ===== 검증 =====
    local verdict="FAIL" detail
    # Before 데드락 성립 조건: freeze + PID 생존 + (curl 미설치가 아니라면) TIMEOUT
    local before_ok="no"
    if [[ "$rc" -eq 0 && "$alive_before" == "yes" ]]; then
        if [[ "$before_curl" == "TIMEOUT" || "$before_curl" == "N/A" ]]; then before_ok="yes"; fi
    fi
    if [[ "$before_ok" == "yes" ]]; then
        if [[ "$RUN_AFTER" != "1" ]]; then
            verdict="PASS"; detail="freeze+PID생존+curl=${before_curl} (wchan futex=${wchan_hit}, After 생략)"
        elif [[ "$after_frozen" == "no" && ( "$after_curl" == "OK" || "$after_curl" == "N/A" ) ]]; then
            verdict="PASS"; detail="Before 데드락 / After 정상(curl=${after_curl}), wchan futex=${wchan_hit}"
        else
            verdict="FAIL"; detail="After 회피 미확인 (frozen=${after_frozen}, curl=${after_curl})"
        fi
    else
        detail="Before 데드락 시그니처 불충분 (rc=${rc}, alive=${alive_before}, curl=${before_curl})"
    fi
    _record "Deadlock" "$verdict" "$detail"
    [[ "$verdict" == "PASS" ]] && pass "Deadlock 파이프라인 — ${detail}" || fail "Deadlock 파이프라인 — ${detail}"
}

# 직접 실행할 때만 단독 파이프라인을 돈다. (오케스트레이터가 source 로 함수만 가져갈 때는 통과)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == selftest ]] && { selftest; exit 0; }   # 단독 실행도 배선만 점검 가능
    preflight "run"
    experiment_deadlock
    print_summary
fi
