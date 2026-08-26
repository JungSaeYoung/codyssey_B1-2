#!/usr/bin/env bash
# lib_experiment.sh — B1-2 장애 재현·검증 공통 도구 (라이브러리)
# =============================================================================
# 이 파일은 직접 실행하지 않는다. 01~04 실험 스크립트와 00_run_experiments.sh 가
# `source` 로 가져다 쓰는 공통 함수·설정 모음이다.
#
# 담는 것:
#   0) 설정값               모두 환경변수로 덮어쓰기 가능 (QUICK/RUN_AFTER/EVIDENCE_DIR…)
#   1) 출력 헬퍼            banner/step/info/warn/pass/fail/fmt
#   2) 자원 지표            _metric_cpu/_metric_mem/_metric_disk/_sample_to
#   3) 앱 생명주기          launch_app/_confirm_pid/kill_app/_kill_leftovers/_curl_probe
#   4) 증거 스냅샷          _snapshot_terminating/_snapshot_gone/_snapshot_deadlock/_append_app_evidence
#   5) 관측 루프            _watch_terminating(자가종료형) / _watch_freeze(데드락형)
#   6) 자가종료형 공통 코어 _terminating_experiment   ← OOM(01)·CPU(02) 가 공유
#   7) 결과 기록/요약       _record / print_summary
#   8) 사전 점검            preflight / selftest
#   9) 중단 정리            cleanup + trap
#
# 제약(미션 규칙): Bash 전용, 일반 계정, 외부 관측 정보(로그/관제)만 사용.
# =============================================================================

# 중복 source 방지 — 오케스트레이터가 이 lib 와 01~04 를 모두 source 할 때
# RESULTS 배열이 다시 비워지지 않도록 한 번만 로드한다. (lib 은 항상 source 로만 쓰임)
[[ -n "${_LIB_EXPERIMENT_LOADED:-}" ]] && return 0
_LIB_EXPERIMENT_LOADED=1

set -u

# ─────────────────────────────────────────────────────────────────────────────
# 0) 설정 (모두 환경변수로 덮어쓸 수 있음)
# ─────────────────────────────────────────────────────────────────────────────
APP_BIN="${APP_BIN:-agent-leak-app}"
AGENT_HOME="${AGENT_HOME:-}"                       # 필수 — agent-admin 로그인 셸 env
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
# 앱이 스스로 쓰는 로그 파일명은 agent_app.log 다 (직접 실행해 확인).
#   $AGENT_LOG_DIR/agent_app.log  ← 앱 내부 logging(FileHandler) 이 append 모드로 기록
#   $AGENT_LOG_DIR/agent_app.out  ← nohup 리다이렉트(부트 시퀀스 [1/6]~[6/6] + READY 배너)
# 두 파일을 같은 경로로 두면 offset 이 다른 writer 2개가 한 파일을 덮어쓰므로 분리한다.
APP_LOG="${APP_LOG:-${AGENT_LOG_DIR}/agent_app.log}"
APP_STDOUT="${APP_STDOUT:-${AGENT_LOG_DIR}/agent_app.out}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib 은 src/experiments/ 에 있으므로 저장소 루트는 두 단계 위(../..).
# 기본 출력은 evidence_live/ (제출본 evidence/ 를 실수로 덮지 않도록). 갱신하려면 EVIDENCE_DIR 지정.
REPO_ROOT="$(cd "${LIB_DIR}/../.." 2>/dev/null && pwd)"
DEFAULT_EVIDENCE="${REPO_ROOT:-${LIB_DIR}/../..}/evidence_live"   # 폴백도 스크립트 위치 기준(CWD 비의존)
EVIDENCE_DIR="${EVIDENCE_DIR:-${DEFAULT_EVIDENCE}}"

# 대기/샘플링 정책 (초)
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-15}"           # 자원 1회 샘플 간격
SNAPSHOT_EVERY="${SNAPSHOT_EVERY:-4}"              # 몇 샘플마다 ps/top 스냅샷
OOM_BEFORE_TIMEOUT="${OOM_BEFORE_TIMEOUT:-1500}"   # 25분
CPU_BEFORE_TIMEOUT="${CPU_BEFORE_TIMEOUT:-900}"    # 15분
DEADLOCK_TIMEOUT="${DEADLOCK_TIMEOUT:-600}"        # 10분
DEADLOCK_AFTER_VERIFY="${DEADLOCK_AFTER_VERIFY:-120}"
FREEZE_SECS="${FREEZE_SECS:-60}"                   # 로그 N초 무변화 → freeze 판정
SCHED_DURATION="${SCHED_DURATION:-60}"
AFTER_FACTOR="${AFTER_FACTOR:-15}"                 # After 가 Before×1.5 넘기면 PASS (정수/10)
CURL_TIMEOUT="${CURL_TIMEOUT:-3}"
RUN_AFTER="${RUN_AFTER:-1}"

if [[ "${QUICK:-0}" == "1" ]]; then
    SAMPLE_INTERVAL=5;  SNAPSHOT_EVERY=3
    OOM_BEFORE_TIMEOUT=180; CPU_BEFORE_TIMEOUT=180; DEADLOCK_TIMEOUT=180
    DEADLOCK_AFTER_VERIFY=40; FREEZE_SECS=20; SCHED_DURATION=20
fi

# 0/빈값으로 덮어쓰면 (( tick % SNAPSHOT_EVERY )) 0 나눗셈 / sleep 0 무한루프 → 최소 1 보장
(( SNAPSHOT_EVERY < 1 )) && SNAPSHOT_EVERY=1
(( SAMPLE_INTERVAL < 1 )) && SAMPLE_INTERVAL=1

# 실행 중 상태/결과 (실험 스크립트들이 공유)
RESULTS=()
CURRENT_PID=""

# ─────────────────────────────────────────────────────────────────────────────
# 1) 출력 헬퍼 (00_run_all.sh / monitor.sh 스타일 유지)
# ─────────────────────────────────────────────────────────────────────────────
banner() {
    echo
    echo "════════════════════════════════════════════════════════════════════"
    echo "▶ $*"
    echo "════════════════════════════════════════════════════════════════════"
}
step() { printf "  ▶ %s\n" "$*"; }
info() { printf "  [INFO] %s\n" "$*"; }
warn() { printf "  [WARN] %s\n" "$*"; }
pass() { printf "  [PASS] %s\n" "$*"; }
fail() { printf "  [FAIL] %s\n" "$*"; }

# 초 → "12m34s"
fmt() { local s="${1:-0}"; printf '%dm%02ds' $(( s / 60 )) $(( s % 60 )); }

# ─────────────────────────────────────────────────────────────────────────────
# 2) 자원 지표 — monitor.sh §3 의 계산식을 그대로 미러링
#    (cron monitor.log 이 1분 해상도라, 짧은 실험 구간을 더 촘촘히 남기기 위함)
# ─────────────────────────────────────────────────────────────────────────────
_metric_cpu() {                                    # 시스템 CPU 사용률(%) = 100 - idle
    local c
    c="$(top -bn1 2>/dev/null | awk -F'[ ,]+' '/Cpu\(s\)/ {for(i=1;i<=NF;i++) if ($i ~ /id$/){print 100-$(i-1); exit}}')"
    [[ -z "$c" ]] && c="0.0"
    printf '%.1f' "$c"
}
_metric_mem() {                                    # 시스템 메모리 사용률(%)
    local m
    m="$(free | awk '/^Mem:/ {printf "%.1f", $3/$2*100}')"
    [[ -z "$m" ]] && m="0.0"
    printf '%s' "$m"
}
_metric_disk() {                                   # root 파티션 사용률(%)
    local d
    d="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    [[ -z "$d" ]] && d="0"
    printf '%s' "$d"
}

# ── 대상 프로세스 지표 (monitor.sh §3-(b) 와 같은 계산식) ────────────────────
# 시스템 전체(_metric_cpu/_metric_mem)로는 B1-2-A1(프로세스 메모리 증가)·A4(특정 프로세스
# CPU 급상승)를 관측할 수 없다. RSS/%CPU 는 반드시 PID 를 지정해 읽는다.
_metric_proc_rss() {                               # 대상 프로세스 RSS(MB)
    local pid="$1" kb
    kb="$(ps -o rss= -p "$pid" 2>/dev/null | awk 'NR==1 {gsub(/[^0-9]/,""); print}')"
    [[ -z "$kb" ]] && kb="0"                       # 방금 죽었으면 0.0 (컬럼 유지)
    awk -v k="$kb" 'BEGIN {printf "%.1f", k/1024}'
}
_metric_proc_cpu() {                               # 대상 프로세스 %CPU (시작 이후 누적 평균)
    local pid="$1" c
    c="$(ps -o pcpu= -p "$pid" 2>/dev/null | awk 'NR==1 {gsub(/[^0-9.]/,""); print}')"
    [[ -z "$c" ]] && c="0.0"
    printf '%.1f' "$c"
}

# monitor.log 와 동일한 한 줄 포맷으로 샘플 1개를 파일+화면에 남긴다
# 포맷: [TS] PID:n SYS_CPU:x% SYS_MEM:y% PROC_CPU:z% PROC_RSS:wMB DISK_USED:d%
_sample_to() {
    local pid="$1" file="$2"
    printf '[%s] PID:%s SYS_CPU:%s%% SYS_MEM:%s%% PROC_CPU:%s%% PROC_RSS:%sMB DISK_USED:%s%%\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" \
        "$(_metric_cpu)" "$(_metric_mem)" \
        "$(_metric_proc_cpu "$pid")" "$(_metric_proc_rss "$pid")" \
        "$(_metric_disk)" \
        | tee -a "$file"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3) 앱 생명주기 헬퍼
# ─────────────────────────────────────────────────────────────────────────────
app_alive() { kill -0 "$1" 2>/dev/null; }

# 실험_절차서대로: nohup ./agent-leak-app > log 2>&1 &
#
# [고침] 이전 구현은  ( cd "$AGENT_HOME" && nohup ... & echo "$!" )  였다.
#   `cd … && nohup …` 이 AND-리스트 전체로 하나의 백그라운드 잡이 되어 $! 가 "서브셸 PID" 였고,
#   그 서브셸이 잠깐 살아 있으면 _confirm_pid 의 pgrep 보정도 지나쳐 엉뚱한 PID 가 반환됐다
#   (→ 생존시간 0m00s, After 판정 FAIL).
# 이제 cd 는 서브셸 안에서 동기적으로 실행하고 & 는 앱 한 줄에만 붙인다.
#   → $! 는 앱의 실제 PID, cd 는 서브셸 안에만 머물러 호출부 cwd 를 오염시키지 않는다.
launch_app() {
    local out="$1"
    # 앱은 $APP_LOG 를 append 모드로 연다(직접 확인: 이전 내용이 그대로 남았다).
    # 이전 실행의 종료 시그니처가 남아 있으면 다음 Before/After 관측이 즉시 오탐하므로 비운다.
    : > "$APP_LOG" 2>/dev/null || true
    (
        cd "$AGENT_HOME" || exit 1
        nohup "./${APP_BIN}" > "$out" 2>&1 &
        echo "$!"
    )
}

# PyInstaller onefile 은 부트로더(부모)가 실제 앱(자식)을 fork 한다.
# heap 증가(RSS)·스레드(ps -L)·wchan 은 전부 자식 쪽에서만 보이고 부모는 2MB 스텁이다.
# 앱이 남기는 "Self-terminating process N" 의 N 도 자식 PID 다 → 관측 대상을 자식으로 보정한다.
# 자식이 아직 안 떴을 수 있어 최대 5초 기다리고, 끝내 없으면 원래 PID 를 그대로 쓴다.
_worker_pid() {
    local pid="$1" child i
    for i in 1 2 3 4 5; do
        child="$(pgrep -P "$pid" -x "$APP_BIN" 2>/dev/null | head -n1 || true)"
        [[ -n "$child" ]] && { echo "$child"; return; }
        app_alive "$pid" || break
        sleep 1
    done
    echo "$pid"
}

# $! 가 바로 죽었으면 pgrep 으로 실제 PID 보정 (인터프리터/데몬화 대비) 후 워커 PID 로 내려간다
_confirm_pid() {
    local pid="$1" i alt
    for i in 1 2 3; do
        app_alive "$pid" && break
        sleep 1
    done
    if ! app_alive "$pid"; then
        alt="$(pgrep -x "$APP_BIN" 2>/dev/null | head -n1 || true)"
        [[ -n "$alt" ]] && pid="$alt"
    fi
    _worker_pid "$pid"
}

kill_app() {
    local pid="${1:-}"
    [[ -z "$pid" ]] && return 0
    if app_alive "$pid"; then
        kill "$pid" 2>/dev/null || true
        local i
        for i in 1 2 3 4 5; do app_alive "$pid" || return 0; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true          # 최후의 수단 (SIGKILL)
    fi
    return 0
}

# 직전 실험의 잔존 프로세스 정리
# [고침] pgrep -f 는 cmdline 전체를 보므로 "agent-leak-app" 문자열을 인자/경로에 달고 있는
#   셸·툴링 프로세스까지 매칭해 실험 스크립트가 자기 자신(또는 감싼 셸)을 죽이는 사고가 난다
#   (검증 중 실제로 재현: 검증 셸이 SIGTERM 으로 죽어 앱이 5초 만에 사라졌다).
#   monitor.sh §1-1 과 동일하게 프로세스 이름(comm) 정확 일치(-x)만 잡는다.
_kill_leftovers() {
    local p
    for p in $(pgrep -x "$APP_BIN" 2>/dev/null || true); do
        [[ "$p" == "$$" ]] && continue
        kill_app "$p"
    done
}

_curl_probe() {                                    # OK / TIMEOUT
    command -v curl >/dev/null 2>&1 || { echo "N/A"; return; }
    if curl --max-time "$CURL_TIMEOUT" -s "http://127.0.0.1:${AGENT_PORT}" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "TIMEOUT"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 4) 증거 스냅샷
# ─────────────────────────────────────────────────────────────────────────────
# OOM/CPU 용: 프로세스 메모리/CPU 점유 캡처
_snapshot_terminating() {
    local pid="$1" file="$2"
    {
        echo "##### $(date '+%H:%M:%S')  ps -o pid,ppid,rss,vsz,pcpu,stat,etime,cmd -p $pid #####"
        ps -o pid,ppid,rss,vsz,pcpu,stat,etime,cmd -p "$pid" 2>/dev/null || echo "# (no such process)"
        echo
        echo "##### $(date '+%H:%M:%S')  top -bn1 -p $pid #####"
        top -bn1 -p "$pid" 2>/dev/null | sed -n '1,12p' || true
        echo
    } >> "$file"
}

# 프로세스 종료 직후 흔적
_snapshot_gone() {
    local pid="$1" file="$2"
    {
        echo "##### $(date '+%H:%M:%S')  ps -p $pid  (종료 직후) #####"
        ps -p "$pid" -o pid,tty,time,cmd 2>/dev/null || true
        echo "# (헤더만 보이면 프로세스 종료됨)"
        echo
    } >> "$file"
}

# Deadlock 용: 절차서 3-2 의 6종 증거를 한 번에
_snapshot_deadlock() {
    local pid="$1" file="$2"
    {
        echo "##### $(date '+%H:%M:%S')  ps -ef | grep -v grep | grep agent #####"
        ps -ef | grep -v grep | grep -E "agent|(^|[^0-9])${pid}([^0-9]|$)" || echo "# (매칭 없음)"
        echo
        echo "##### ps -p $pid -o pid,stat,etime,cmd #####"
        ps -p "$pid" -o pid,stat,etime,cmd 2>/dev/null || true
        echo
        echo "##### top -H -bn1 -p $pid #####"
        top -H -bn1 -p "$pid" 2>/dev/null | sed -n '1,14p' || true
        echo
        echo "##### ps -L -p $pid -o lwp,pcpu,stat,wchan:25,cmd #####"
        ps -L -p "$pid" -o lwp,pcpu,stat,wchan:25,cmd 2>/dev/null || true
        echo
        echo "##### curl --max-time $CURL_TIMEOUT http://127.0.0.1:$AGENT_PORT #####"
        if command -v curl >/dev/null 2>&1; then
            curl --max-time "$CURL_TIMEOUT" -v "http://127.0.0.1:${AGENT_PORT}" 2>&1 | sed -n '1,8p' || true
        else
            echo "# curl 미설치 — 외부 무응답 검증 생략"
        fi
        echo
    } >> "$file"
}

# 현재 실행의 앱 출력을 증거 app 로그에 Before/After 섹션으로 누적한다.
#   - $APP_STDOUT : 부트 시퀀스([1/6]~[6/6] + Agent READY + Resource Check) — B1-2-P1~P11 증거
#   - $APP_LOG    : 앱이 직접 쓰는 타임스탬프 로그 — 종료 직전/직후 라인(B1-2-E-OOM2 등) 증거
_append_app_evidence() {
    local label="$1" file="$2"
    {
        echo "### ===== ${label} ====="
        echo "--- nohup stdout (${APP_STDOUT}) — 부트 시퀀스 ---"
        cat "$APP_STDOUT" 2>/dev/null || true
        echo "--- app log (${APP_LOG}) ---"
        cat "$APP_LOG" 2>/dev/null || true
        echo
    } >> "$file"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5) 관측 루프
# ─────────────────────────────────────────────────────────────────────────────
# OOM/CPU: 자가 종료(시그니처) 또는 프로세스 소멸까지 대기.
#   반환  0 = 종료 감지 / 2 = stop_after 까지 생존(조치 효과 입증) / 1 = timeout
#   생존시간은 전역 SECONDS 로 읽는다.
_watch_terminating() {
    local pid="$1" timeout="$2" signature="$3" mon="$4" psf="$5" stop_after="$6"
    local tick=0
    SECONDS=0
    while :; do
        app_alive "$pid" || return 0
        if grep -qiE "$signature" "$APP_LOG" 2>/dev/null; then
            sleep 2; return 0
        fi
        _sample_to "$pid" "$mon"
        (( tick % SNAPSHOT_EVERY == 0 )) && _snapshot_terminating "$pid" "$psf"
        tick=$(( tick + 1 ))
        (( stop_after > 0 && SECONDS >= stop_after )) && return 2
        (( SECONDS >= timeout )) && return 1
        sleep "$SAMPLE_INTERVAL"
    done
}

# Deadlock: 로그가 FREEZE_SECS 동안 무변화(크기+mtime) 이면서 PID 생존 → freeze.
#   반환  0 = freeze 감지 / 1 = 예기치 않은 종료 / 2 = timeout 동안 freeze 없음(정상)
_watch_freeze() {
    local pid="$1" timeout="$2" mon="$3"
    local prev="" cur stable=0
    SECONDS=0
    while :; do
        app_alive "$pid" || return 1
        _sample_to "$pid" "$mon"
        cur="$(stat -c '%s:%Y' "$APP_LOG" 2>/dev/null || echo "x")"
        if [[ "$cur" == "$prev" ]]; then
            stable=$(( stable + SAMPLE_INTERVAL ))
        else
            stable=0; prev="$cur"
        fi
        (( stable >= FREEZE_SECS )) && return 0
        (( SECONDS >= timeout )) && return 2
        sleep "$SAMPLE_INTERVAL"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 6) 자가종료형 공통 코어 — OOM(01_oom.sh) / CPU(02_cpu.sh) 가 공유
#    (둘 다 "환경변수를 조이면 앱이 스스로 종료" 하는 같은 형태라 코어를 공유한다)
# ─────────────────────────────────────────────────────────────────────────────
_terminating_experiment() {
    local kind="$1" signature="$2" mon_name="$3" app_name="$4" ps_name="$5"
    local before_env="$6" after_env="$7" before_timeout="$8"

    local MON="${EVIDENCE_DIR}/${mon_name}"
    local APPF="${EVIDENCE_DIR}/${app_name}"
    local PSF="${EVIDENCE_DIR}/${ps_name}"
    : > "$MON"; : > "$APPF"; : > "$PSF"             # 실험마다 증거 초기화

    # ===== Before (장애 재현) =====
    banner "${kind} 실험 — Before (장애 재현)"
    step "환경: ${before_env}"
    eval "$before_env"
    _kill_leftovers
    printf '# ── %s Before  (%s)  start %s ──\n' "$kind" "$before_env" "$(date '+%F %T')" >> "$MON"

    local pid; pid="$(launch_app "$APP_STDOUT")"; CURRENT_PID="$pid"
    pid="$(_confirm_pid "$pid")"; CURRENT_PID="$pid"
    step "PID=${pid} → '${signature}' 시그니처 대기 (최대 $(fmt "$before_timeout"))"

    _watch_terminating "$pid" "$before_timeout" "$signature" "$MON" "$PSF" 0
    local rc=$? before_surv=$SECONDS
    if app_alive "$pid"; then _snapshot_terminating "$pid" "$PSF"; kill_app "$pid"; fi
    printf '[%s] [ERROR] Application process not running. (PID %s 종료)\n' "$(date '+%F %T')" "$pid" >> "$MON"
    _snapshot_gone "$pid" "$PSF"
    _append_app_evidence "Before  (${before_env})" "$APPF"
    CURRENT_PID=""

    local before_seen="no"
    grep -qiE "$signature" "$APPF" 2>/dev/null && before_seen="yes"
    if [[ "$rc" -eq 0 ]]; then
        info "Before 종료 감지 — 생존 $(fmt "$before_surv"), 시그니처=${before_seen}"
    else
        warn "Before: $(fmt "$before_timeout") 내 종료 미감지 (timeout) — TIMEOUT 값/재현 조건 확인"
    fi

    # ===== After (조치 검증) =====
    local after_surv=0 after_rc=9 stop_after=0
    if [[ "$RUN_AFTER" == "1" ]]; then
        banner "${kind} 실험 — After (조치 검증)"
        step "환경: ${after_env}"
        eval "$after_env"
        _kill_leftovers
        printf '# ── %s After  (%s)  start %s ──\n' "$kind" "$after_env" "$(date '+%F %T')" >> "$MON"

        pid="$(launch_app "$APP_STDOUT")"; CURRENT_PID="$pid"
        pid="$(_confirm_pid "$pid")"; CURRENT_PID="$pid"

        local after_cap
        if (( before_surv > 0 )); then
            stop_after=$(( before_surv * AFTER_FACTOR / 10 ))   # Before×1.5
            after_cap=$(( before_surv * 2 + 300 ))
        else
            stop_after=0; after_cap="$before_timeout"
        fi
        step "PID=${pid} → Before×1.5 = $(fmt "$stop_after") 생존 시 PASS (cap $(fmt "$after_cap"))"

        _watch_terminating "$pid" "$after_cap" "$signature" "$MON" "$PSF" "$stop_after"
        after_rc=$?; after_surv=$SECONDS
        if app_alive "$pid"; then _snapshot_terminating "$pid" "$PSF"; kill_app "$pid"; fi
        printf '[%s] [INFO] After phase ended (PID %s, rc=%s, %s)\n' \
            "$(date '+%F %T')" "$pid" "$after_rc" "$(fmt "$after_surv")" >> "$MON"
        _append_app_evidence "After  (${after_env})" "$APPF"
        CURRENT_PID=""

        if [[ "$after_rc" -eq 2 ]]; then
            info "After: $(fmt "$stop_after") 경과까지 생존 → 임계치 상향 효과 확인"
        elif [[ "$after_rc" -eq 0 ]]; then
            info "After 종료 감지 — 생존 $(fmt "$after_surv")"
        else
            warn "After: cap 내 판정 보류"
        fi
    fi

    # ===== 검증 =====
    # 1차 근거 = "Before 가 스스로 종료했는가"(rc==0; 우리가 kill 한 게 아님).
    # 시그니처는 메커니즘 확증용 보조 신호(예시 로그 문구에 과의존하지 않음).
    local verdict="FAIL" detail sig_note
    if [[ "$before_seen" == "yes" ]]; then sig_note="시그니처 확인"; else sig_note="시그니처 미검출(자가종료로 판정)"; fi
    if [[ "$rc" -eq 0 ]]; then
        if [[ "$RUN_AFTER" != "1" ]]; then
            verdict="PASS"; detail="Before 자가종료 $(fmt "$before_surv") [${sig_note}] (After 생략)"
        elif [[ "$after_rc" -eq 2 ]]; then
            verdict="PASS"; detail="Before $(fmt "$before_surv") → After >$(fmt "$stop_after") 생존 [${sig_note}]"
        elif (( after_surv > before_surv )); then
            verdict="PASS"; detail="Before $(fmt "$before_surv") → After $(fmt "$after_surv") [${sig_note}]"
        else
            verdict="FAIL"; detail="After 생존($(fmt "$after_surv"))이 Before($(fmt "$before_surv"))보다 길지 않음"
        fi
    else
        detail="Before 가 $(fmt "$before_timeout") 내 자가종료하지 않음 (장애 미재현 — TIMEOUT/조건 확인)"
    fi
    _record "$kind" "$verdict" "$detail"
    [[ "$verdict" == "PASS" ]] && pass "${kind} 파이프라인 — ${detail}" || fail "${kind} 파이프라인 — ${detail}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7) 결과 기록 / 요약
# ─────────────────────────────────────────────────────────────────────────────
_record() { RESULTS+=("$1|$2|$3"); }

print_summary() {
    banner "검증 요약 (Verification Summary)"
    if (( ${#RESULTS[@]} == 0 )); then
        warn "실행된 파이프라인 없음"
        return 0
    fi
    printf '  %-11s %-6s %s\n' "PIPELINE" "RESULT" "DETAIL"
    printf '  %-11s %-6s %s\n' "--------" "------" "------------------------------------"
    local any_fail=0 r k v d
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r k v d <<< "$r"
        printf '  %-11s %-6s %s\n' "$k" "$v" "$d"
        [[ "$v" == "FAIL" ]] && any_fail=1
    done
    echo
    echo "  증거 디렉토리: ${EVIDENCE_DIR}/"
    ls -1 "$EVIDENCE_DIR" 2>/dev/null | sed 's/^/    - /' || true
    echo
    if [[ "${EVIDENCE_DIR}" == */evidence ]]; then
        echo "  (제출용 evidence/ 를 직접 갱신했습니다. 각 파일 맨 위의 재현 헤더 주석은 이 스크립트가"
        echo "   자동으로 붙이지 않으므로, 재수집 후에는 헤더의 시각·환경변수를 갱신하세요.)"
    else
        echo "  (여기는 재실행 산출물 폴더입니다. 제출용 evidence/ 를 갱신하려면"
        echo "   EVIDENCE_DIR=\"\$REPO/evidence\" 로 다시 실행하세요.)"
    fi
    echo
    echo "  다음 단계: 위 증거를 근거로 reports/0{1,2,3,4}_*.md 의 4단 구조(Description /"
    echo "             Evidence / Root Cause / Workaround) 를 채워 GitHub Issue 로 제출."
    echo
    if (( any_fail )); then
        warn "일부 파이프라인 FAIL — DETAIL 과 evidence/ 를 확인하세요"
        return 1
    fi
    pass "모든 파이프라인 검증 완료"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 8) 사전 점검 / Self-test
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    local mode="${1:-run}" ok=1
    banner "사전 점검 (Preflight)"

    if [[ "$(id -u)" -eq 0 ]]; then
        fail "root 로 실행 금지 — agent-admin 등 일반 계정으로 실행 (예: sudo -iu agent-admin)"
        exit 1
    fi
    pass "비-root 계정: $(id -un)"

    if [[ -z "$AGENT_HOME" ]]; then
        fail "AGENT_HOME 미설정 — agent-admin 로그인 셸에서 실행하거나 AGENT_HOME=… 로 지정"
        exit 1
    fi
    [[ -d "$AGENT_HOME" ]] && pass "AGENT_HOME: $AGENT_HOME" || { fail "AGENT_HOME 디렉토리 없음: $AGENT_HOME"; ok=0; }

    if [[ ! -d "$AGENT_LOG_DIR" ]]; then
        warn "AGENT_LOG_DIR 없음: $AGENT_LOG_DIR (생성 시도)"
        mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true
    fi
    [[ -w "$AGENT_LOG_DIR" ]] && pass "AGENT_LOG_DIR 쓰기 가능: $AGENT_LOG_DIR" \
        || { fail "AGENT_LOG_DIR 쓰기 불가: $AGENT_LOG_DIR (06_deploy / 권한 확인)"; ok=0; }

    if [[ -x "${AGENT_HOME}/${APP_BIN}" ]]; then
        pass "앱 바이너리: ${AGENT_HOME}/${APP_BIN}"
    elif [[ "$mode" == "selftest" ]]; then
        warn "앱 바이너리 없음/실행불가: ${AGENT_HOME}/${APP_BIN} (selftest 계속)"
    else
        fail "앱 바이너리 없음/실행불가: ${AGENT_HOME}/${APP_BIN} — 06_deploy_app_and_scripts.sh 로 배치"
        ok=0
    fi

    local t
    for t in top ps free df awk grep sed pgrep date stat; do
        command -v "$t" >/dev/null 2>&1 || { fail "필수 도구 없음: $t"; ok=0; }
    done
    command -v curl >/dev/null 2>&1 && pass "curl 사용 가능 (외부 무응답 검증 ON)" \
        || warn "curl 없음 — Deadlock 의 curl 타임아웃 검증은 생략됨"

    mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true
    [[ -w "$EVIDENCE_DIR" ]] && pass "EVIDENCE_DIR: $EVIDENCE_DIR" \
        || { fail "EVIDENCE_DIR 쓰기 불가: $EVIDENCE_DIR (EVIDENCE_DIR=… 로 변경 가능)"; ok=0; }

    if (( ! ok )); then
        fail "사전 점검 실패 — 위 항목 해결 후 다시 실행"
        exit 1
    fi
    info "사전 점검 통과"
}

selftest() {
    preflight "selftest"
    banner "Self-test — 실행 계획 (앱은 띄우지 않음)"
    cat <<EOF
  설정값:
    SAMPLE_INTERVAL    = ${SAMPLE_INTERVAL}s        (QUICK=${QUICK:-0})
    OOM_BEFORE_TIMEOUT = $(fmt "$OOM_BEFORE_TIMEOUT")
    CPU_BEFORE_TIMEOUT = $(fmt "$CPU_BEFORE_TIMEOUT")
    DEADLOCK_TIMEOUT   = $(fmt "$DEADLOCK_TIMEOUT")  (FREEZE_SECS=$(fmt "$FREEZE_SECS"))
    RUN_AFTER          = ${RUN_AFTER}
    EVIDENCE_DIR       = ${EVIDENCE_DIR}
    APP_LOG            = ${APP_LOG}      (앱이 직접 쓰는 로그)
    APP_STDOUT         = ${APP_STDOUT}      (nohup 리다이렉트 = 부트 시퀀스)

  파이프라인별 환경변수 / 종료 시그니처 / 산출 증거:
    OOM (01)       MEMORY_LIMIT 256→512        자가종료 + 'self-terminat|limit exceeded'
                   (CPU_MAX_OCCUPY=10 고정 — CpuWorker 가 대신 죽이는 교란 제거)
                   → oom_monitor.log, oom_app.log, oom_ps_top.txt
    CPU (02)       CPU_MAX_OCCUPY 80→10        'cpu threshold violated|emergency abort|sigterm'
                   (상향이 아니라 하향. 트립 라인은 고정 50% 라 80→95 는 효과 0 — 실측)
                   → cpu_monitor.log, cpu_app.log, cpu_top_ps.txt
    Deadlock (03)  MULTI_THREAD_ENABLE true→false   freeze(PID 생존+로그 정지+전 스레드 futex)
                   (CPU_MAX_OCCUPY=10 고정. curl 은 정상 모드에서도 무응답이라 판별에 쓰지 않음)
                   → deadlock_monitor.log, deadlock_app.log, deadlock_ps_top.txt
    Schedule (04)  MULTI_THREAD_ENABLE=false CPU=10 (Healthy)  [Scheduler]/[Thread-A|B|C] 태그 로그
                   → scheduling_workers.log, scheduling_top_h.txt

  관제 샘플 1줄 포맷 (monitor.sh 와 동일):
    [TS] PID:n SYS_CPU:x% SYS_MEM:y% PROC_CPU:z% PROC_RSS:wMB DISK_USED:d%
      SYS_*  = 호스트 전체   PROC_* = 대상 프로세스(B1-2-A1/A4 가 요구하는 지표)

  실제 실행:  bash 00_run_experiments.sh all
EOF
    pass "Self-test 완료 — 위 계획대로 실행 준비됨"
}

# ─────────────────────────────────────────────────────────────────────────────
# 9) 중단 정리 — 실험 스크립트가 source 하는 순간 trap 이 걸린다
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "${CURRENT_PID:-}" ]]; then
        echo; warn "중단 신호 수신 — 실행 중인 앱(PID ${CURRENT_PID}) 정리"
        kill_app "$CURRENT_PID"
    fi
}
trap 'cleanup; exit 130' INT TERM
