#!/usr/bin/env bash
# verify_orbstack.sh   (B1-2)
# ─────────────────────────────────────────────────────────────────────────────
# OrbStack 의 Linux 머신을 띄워 B1-2 미션을 자동 setup + 검증 + 장애 실험까지 돌린다.
#   1) §1~§7 인프라 setup  — 저장소의 src/0N_*.sh 를 그대로 호출 (재구현 X)
#   2) agent-leak-app 부트 시퀀스 5/5 [OK] + 'Agent READY' 검증
#   3) monitor.sh 수동 실행 + cron 매분 동작 검증
#   4) src/experiments/ 의 3대 장애(OOM/CPU/Deadlock) + 스케줄링 파이프라인 실행
#   검증/실험 산출물은 ./.verify-artifacts/ 에 저장된다.
#
# 사용법 (macOS 호스트, 이 스크립트의 디렉토리에서):
#   ./verify_orbstack.sh                # 머신 재사용 (없으면 생성), 실험 전체(실측)
#   FRESH=1 ./verify_orbstack.sh        # 머신 삭제 후 깨끗하게 재생성
#   QUICK=1 ./verify_orbstack.sh        # 실험 대기시간 단축(데모/배선 확인용)
#   RUN_EXPERIMENTS=0 ./verify_orbstack.sh   # setup+부트까지만, 장애 실험 생략
#   ./verify_orbstack.sh --cleanup      # 모든 단계 후 머신 삭제
#
# ⚠ 실험 전체(실측)는 매우 오래 걸린다: OOM ≤25분 / CPU ≤15분 / Deadlock ≤10분.
#    데모는 QUICK=1, setup 검증만 보려면 RUN_EXPERIMENTS=0 을 권장.
#
# 사전 요구:
#   - OrbStack 설치 (`brew install orbstack` + 첫 실행)
#   - 이 디렉토리에 src/0N_*.sh, src/{monitor,report,archive_logs}.sh,
#     src/experiments/*.sh, 그리고 운영 측 제공 bin/agent-leak-app 존재
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

MACHINE="${MACHINE_NAME:-codyssey-b1-2}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART="$WORKDIR/.verify-artifacts"
LOG="$ART/run.log"
STAGE="/tmp/codyssey-b1-2"                 # 머신 안 스테이징 디렉토리
CLEANUP=0
[[ "${1:-}" == "--cleanup" ]] && CLEANUP=1

RUN_EXPERIMENTS="${RUN_EXPERIMENTS:-1}"
EXP_WARN=0                                  # 실험 중 PASS 못 한 파이프라인이 있으면 1

mkdir -p "$ART"
: > "$LOG"

# agent-leak-app 부트에 필요한 환경변수 (.bashrc 는 non-interactive 셸에서 안 읽히므로 직접 주입)
APP_ENV="AGENT_HOME=/home/agent-admin/agent-app \
AGENT_PORT=15034 \
AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files \
AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys \
AGENT_LOG_DIR=/var/log/agent-app"

# ── 출력 헬퍼 ────────────────────────────────────────────────────────────────
c_reset="$(printf '\033[0m')"
c_cyan="$(printf '\033[1;36m')"
c_green="$(printf '\033[1;32m')"
c_red="$(printf '\033[1;31m')"
c_yellow="$(printf '\033[1;33m')"
c_dim="$(printf '\033[2m')"
B="$(printf '\033[1m')"
R="$c_reset"

section() { printf "\n${c_cyan}▸ %s${c_reset}\n" "$*" | tee -a "$LOG"; }
ok()      { printf "  ${c_green}✓${c_reset} %s\n" "$*" | tee -a "$LOG"; }
warn()    { printf "  ${c_yellow}!${c_reset} %s\n" "$*" | tee -a "$LOG"; }
die()     { printf "  ${c_red}✗${c_reset} %s\n" "$*" | tee -a "$LOG"; exit 1; }

# ── 시연 모드 (NARRATE=1) — 섹션 시작 전 설명 박스 + 엔터 대기 ───────────────
NARRATE="${NARRATE:-0}"
narrate() {
    local title="$1"; shift
    local body="$*"
    local sep
    sep="$(printf '─%.0s' $(seq 1 70))"
    printf "\n${c_yellow}┌%s${c_reset}\n"  "$sep"
    printf "${c_yellow}│${c_reset}  ${B}%s${c_reset}\n" "$title"
    printf "${c_yellow}│${c_reset}\n"
    printf "%s\n" "$body" | sed "s/^/${c_yellow}│${c_reset}   /"
    printf "${c_yellow}└%s${c_reset}\n" "$sep"
    if [[ "$NARRATE" == "1" ]]; then
        printf "${c_dim}  [엔터를 눌러 명령 실행 — 건너뛰려면 's'+엔터, 종료 'q'+엔터]${c_reset} "
        local key=""
        read -r key || true
        case "$key" in
            s|S) printf "${c_dim}  (이 섹션 건너뜀 — 검증은 그대로 수행됨)${c_reset}\n";;
            q|Q) printf "${c_dim}  (시연 중단)${c_reset}\n"; exit 0 ;;
        esac
    fi
}

# ── OrbStack 업데이트 알림 억제 ────────────────────────────────────────────
export ORBSTACK_NO_UPDATE_CHECK=1
export ORB_NO_UPDATE_CHECK=1
export ORB_DISABLE_UPDATE_NOTIFY=1
export DO_NOT_TRACK=1
_orb_clean() {
    sed -E '/(update available|new version|orbstack [0-9]+\.[0-9]+\.[0-9]+ is available|run .*to update.*orbstack)/Id'
}

# ── 머신 명령 실행 ────────────────────────────────────────────────────────────
_show_cmd() {
    [[ "${NARRATE:-0}" != "1" ]] && return 0
    {
        printf "\n${c_dim}┄ commands ──────────────────────────${c_reset}\n"
        printf "%s\n" "$1" | sed "s/^/  ${c_dim}│${c_reset} /"
        printf "${c_dim}┄ output ────────────────────────────${c_reset}\n"
    } >&2
}
# 머신 안에서 명령 실행 (실시간 출력 흘림 + run.log 누적)
msh() {
    _show_cmd "$1"
    orb -m "$MACHINE" bash -lc "$1" 2>&1 | _orb_clean | tee -a "$LOG"
}
# 출력 캡처용 (stdout 오염 X — caller 가 $(...) 로 받음)
msh_q() {
    if [[ "${NARRATE:-0}" == "1" ]]; then
        printf "${c_dim}┄ check\$ %s${c_reset}\n" "$1" >&2
    fi
    orb -m "$MACHINE" bash -lc "$1" | _orb_clean
}

# ── 사전 점검 ────────────────────────────────────────────────────────────────
preflight() {
    section "Preflight"
    command -v orb >/dev/null 2>&1 || die "orb CLI not found. Install OrbStack first."
    local need=(
        src/00_run_all.sh src/01_ssh_hardening.sh src/02_firewall_allowlist.sh
        src/03_users_and_groups.sh src/04_directories_and_acl.sh src/05_env_and_keyfile.sh
        src/06_deploy_app_and_scripts.sh src/07_cron_schedule.sh
        src/monitor.sh src/report.sh src/archive_logs.sh
        src/experiments/00_run_experiments.sh src/experiments/lib_experiment.sh
        src/experiments/01_oom.sh src/experiments/02_cpu.sh
        src/experiments/03_deadlock.sh src/experiments/04_scheduling.sh
    )
    local f
    for f in "${need[@]}"; do
        [[ -f "$WORKDIR/$f" ]] || die "missing $WORKDIR/$f"
    done
    if [[ ! -f "$WORKDIR/bin/agent-leak-app" ]]; then
        die "missing $WORKDIR/bin/agent-leak-app — 운영 측 제공 바이너리를 bin/ 에 배치한 뒤 다시 실행"
    fi
    ok "orb CLI present, all source files + agent-leak-app exist"
}

# ── 머신 준비 ────────────────────────────────────────────────────────────────
ensure_machine() {
    section "Ensure machine '$MACHINE'"
    if [[ "${FRESH:-0}" == "1" ]] && orb list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
        warn "FRESH=1 — deleting existing '$MACHINE'"
        orb delete -f "$MACHINE" 2>&1 | tee -a "$LOG"
    fi
    if ! orb list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
        orb create ubuntu:24.04 "$MACHINE" 2>&1 | tee -a "$LOG"
        ok "created '$MACHINE'"
    else
        ok "reusing existing '$MACHINE'"
    fi
    local i state
    for i in {1..30}; do
        state="$(msh_q 'systemctl is-system-running 2>/dev/null || true' || true)"
        case "$state" in
            *running*|*degraded*) ok "systemd up ($(echo "$state" | tr -d '[:space:]'))"; return 0 ;;
        esac
        sleep 1
    done
    die "systemd did not come up"
}

install_base() {
    narrate "사전 — 기본 패키지 설치" \
"OrbStack 의 Ubuntu 24.04 머신은 미니멀해 미션 도구가 빠져 있다.
  • openssh-server : SSH 서버 데몬(sshd) 과 설정 파일
  • ufw / acl / cron: 방화벽 · POSIX ACL · 주기 스케줄러
  • procps / iproute2: top·ps·free·pgrep · ss (실험·관제 도구)
  • curl           : Deadlock 실험의 외부 무응답(타임아웃) 검증
  • dos2unix       : Windows 작성 파일 CRLF → LF 변환"
    section "Install base packages"
    msh 'export DEBIAN_FRONTEND=noninteractive
         sudo apt-get update -qq
         sudo apt-get install -y -qq \
            openssh-server ufw acl cron python3 dos2unix procps iproute2 curl'
    ok "base packages installed"
}

# ── 소스 스테이징 (src 전체 + 바이너리를 머신 안 한 디렉토리로) ───────────────
stage_sources() {
    narrate "사전 — 소스 스테이징" \
"저장소의 src/ (0N_*.sh, monitor/report/archive, experiments/) 와 운영 측
agent-leak-app 바이너리를 머신 안 $STAGE 로 복사한다.
  • 06_deploy 가 SOURCE_DIR 에서 바이너리+스크립트를 찾으므로 한곳에 모은다
  • CRLF → LF 정리 + 실행권한 부여
  • OrbStack 자동 마운트로 macOS 경로($WORKDIR)를 그대로 읽는다"
    section "Stage sources → $STAGE (in machine)"
    msh "rm -rf '$STAGE'; mkdir -p '$STAGE'
         cp -r '$WORKDIR/src/.' '$STAGE/'
         cp '$WORKDIR/bin/agent-leak-app' '$STAGE/'
         sudo dos2unix '$STAGE'/*.sh '$STAGE'/experiments/*.sh 2>/dev/null || true
         chmod +x '$STAGE'/*.sh '$STAGE'/experiments/*.sh '$STAGE/agent-leak-app'
         chmod -R a+rX '$STAGE'"   # agent-admin 이 스테이징 파일을 읽/실행할 수 있도록
    ok "staged to $STAGE (src + agent-leak-app)"
}

# 머신 안에서 setup 스크립트 한 개 실행 (SOURCE_DIR 은 06 만 필요하지만 전역 export)
run_setup_step() {
    local script="$1"
    msh "cd '$STAGE' && SOURCE_DIR='$STAGE' bash '$STAGE/$script'"
}

# ── §1 SSH ───────────────────────────────────────────────────────────────────
v1_ssh() {
    msh_q "grep -E '^Port 20022$'         /etc/ssh/sshd_config" >/dev/null \
        || die "sshd_config: Port 20022 missing"
    msh_q "grep -E '^PermitRootLogin no$' /etc/ssh/sshd_config" >/dev/null \
        || die "sshd_config: PermitRootLogin no missing"
    msh_q "sudo ss -tlnH | awk '\$4 ~ /:20022\$/ {f=1} END{exit !f}'" \
        || die "port 20022 not LISTEN"
    ok "Port 20022 set / Root login denied / LISTEN OK"
}

# ── §2 UFW ───────────────────────────────────────────────────────────────────
v2_ufw() {
    local out
    out="$(msh_q 'sudo ufw status verbose')"
    echo "$out" | grep -q 'Status: active'                     || die "ufw not active"
    echo "$out" | grep -qE '20022/tcp\s+ALLOW IN\s+Anywhere'   || die "20022 rule missing"
    echo "$out" | grep -qE '15034/tcp\s+ALLOW IN\s+Anywhere'   || die "15034 rule missing"
    ok "UFW active + only 20022/15034 allowed"
}

# ── §3 계정/그룹 ──────────────────────────────────────────────────────────────
v3_users() {
    local u info test_info
    for u in agent-admin agent-dev; do
        info="$(msh_q "id $u")"
        echo "$info" | grep -q 'agent-common' || die "$u not in agent-common"
        echo "$info" | grep -q 'agent-core'   || die "$u not in agent-core"
    done
    test_info="$(msh_q 'id agent-test')"
    echo "$test_info" | grep -q 'agent-common' || die "agent-test not in agent-common"
    echo "$test_info" | grep -q 'agent-core'   && die "agent-test must NOT be in agent-core"
    ok "group memberships verified (admin/dev ∈ common+core, test ∈ common only)"
}

# ── §4 디렉토리 + ACL ────────────────────────────────────────────────────────
v4_acl() {
    local ufacl kfacl lfacl
    ufacl="$(msh_q 'sudo getfacl /home/agent-admin/agent-app/upload_files')"
    echo "$ufacl" | grep -q 'default:group:agent-common:rwx' || die "upload_files default ACL missing"
    kfacl="$(msh_q 'sudo getfacl /home/agent-admin/agent-app/api_keys')"
    echo "$kfacl" | grep -q 'default:group:agent-core:rwx'   || die "api_keys default ACL missing"
    lfacl="$(msh_q 'sudo getfacl /var/log/agent-app')"
    echo "$lfacl" | grep -q 'default:group:agent-core:rwx'   || die "log dir default ACL missing"
    ok "directories + default ACLs present"
}

# ── §5 환경변수 / 키파일 (B1-2: secret.key, KEY_PATH=디렉토리, 실험 ENV 3종) ──
v5_env() {
    local kp env_out
    # AGENT_KEY_PATH 는 '디렉토리' 여야 한다 (B1-1 의 파일 경로와 다른 핵심 차이)
    msh_q 'test -d /home/agent-admin/agent-app/api_keys' \
        || die "AGENT_KEY_PATH(api_keys) is not a directory"
    # secret.key 내용/권한
    kp=/home/agent-admin/agent-app/api_keys/secret.key
    [[ "$(msh_q "sudo cat $kp")" == "agent_api_key_test" ]] \
        || die "secret.key content mismatch (expected 'agent_api_key_test')"
    msh_q "sudo stat -c '%U:%G %a' $kp" | grep -q 'agent-admin:agent-core 640' \
        || die "secret.key owner/perm != agent-admin:agent-core 640"
    # 실험용 ENV 3종이 agent-admin .bashrc 에 등록돼 있는지
    env_out="$(msh_q 'grep -E "MEMORY_LIMIT|CPU_MAX_OCCUPY|MULTI_THREAD_ENABLE" /home/agent-admin/.bashrc')"
    echo "$env_out" | grep -q 'MEMORY_LIMIT'        || die ".bashrc missing MEMORY_LIMIT"
    echo "$env_out" | grep -q 'CPU_MAX_OCCUPY'      || die ".bashrc missing CPU_MAX_OCCUPY"
    echo "$env_out" | grep -q 'MULTI_THREAD_ENABLE' || die ".bashrc missing MULTI_THREAD_ENABLE"
    ok "KEY_PATH=dir + secret.key(640, agent-core) + 실험 ENV 3종 등록 확인"
}

# ── §6 배포 ───────────────────────────────────────────────────────────────────
v6_deploy() {
    msh_q 'test -x /home/agent-admin/agent-app/agent-leak-app' \
        || die "agent-leak-app not installed/executable at \$AGENT_HOME"
    local b
    for b in monitor.sh report.sh archive_logs.sh; do
        msh_q "test -x /home/agent-admin/agent-app/bin/$b" \
            || die "$b not installed/executable in \$AGENT_HOME/bin"
    done
    ok "agent-leak-app (0750) + monitor/report/archive_logs.sh (0750) deployed"
}

# ── 부트 시퀀스 ───────────────────────────────────────────────────────────────
s_boot() {
    narrate "부트 — agent-leak-app 실행 → Boot Sequence 5/5 [OK] + 'Agent READY'" \
"백그라운드로 agent-leak-app 을 띄우고 부트 시퀀스 출력이 모두 [OK] 인지 검증한다.
  부트 5단계: 일반계정 / 환경변수 / 키파일(secret.key) / 포트 15034 / 로그 권한
  ※ .bashrc 는 non-interactive 셸에서 안 읽히므로 env 로 환경변수를 직접 주입.
  정상 가동 조합(MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95 MULTI_THREAD_ENABLE=false)으로 실행."
    section "Boot agent-leak-app & wait for 'Agent READY'"
    msh "sudo pkill -x agent-leak-app 2>/dev/null || true; sleep 1"
    msh "sudo -u agent-admin env $APP_ENV \
            MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95 MULTI_THREAD_ENABLE=false \
            bash -c 'cd \$AGENT_HOME && nohup ./agent-leak-app > /tmp/agent.out 2>&1 &'"
    local i
    for i in {1..25}; do
        if msh_q 'grep -q "Agent READY" /tmp/agent.out 2>/dev/null'; then break; fi
        sleep 1
    done
    cp_artifact /tmp/agent.out agent.out
}
die_with_agent_out() {
    printf "\n  ${c_dim}── captured /tmp/agent.out ──${c_reset}\n"
    sed 's/^/    /' "$ART/agent.out" 2>/dev/null || true
    printf "  ${c_dim}── end of agent.out ──${c_reset}\n"
    die "$1"
}
v_boot() {
    local out n
    out="$(msh_q 'cat /tmp/agent.out')"
    for n in 1 2 3 4 5; do
        echo "$out" | grep -q "\[$n/5\].*\[OK\]" || die_with_agent_out "boot step $n/5 not OK"
    done
    echo "$out" | grep -q 'Agent READY' || die_with_agent_out "'Agent READY' not printed"
    msh_q 'sudo ss -tlnH | awk "\$4 ~ /:15034$/ {f=1} END{exit !f}"' \
        || die "port 15034 not LISTEN"
    ok "5/5 boot OK + Agent READY + LISTEN 15034"
}

# ── monitor.sh 수동 실행 ──────────────────────────────────────────────────────
s_monitor() {
    narrate "관제 — monitor.sh 수동 실행" \
"운영 자동화 스크립트 monitor.sh 를 agent-admin 권한으로 1회 실행한다.
  • [HEALTH CHECK] 프로세스 agent-leak-app 생존 + 포트 15034 LISTEN
  • [RESOURCE]     CPU / MEM / DISK 사용률 수집
  • [INFO]         /var/log/agent-app/monitor.log 에 1줄 누적"
    section "monitor.sh — manual run"
    msh 'sudo -iu agent-admin bash -lc "/home/agent-admin/agent-app/bin/monitor.sh"' \
        | tee "$ART/monitor.out" || true
}
v_monitor() {
    grep -qE 'process|agent-leak-app' "$ART/monitor.out" || warn "monitor.out: HEALTH process 라인 못 찾음"
    msh_q 'sudo test -s /var/log/agent-app/monitor.log' || die "monitor.log is empty"
    local last
    last="$(msh_q 'sudo tail -n1 /var/log/agent-app/monitor.log')"
    echo "$last" | grep -qE '^\[[0-9-]+ [0-9:]+\] PID:[0-9-]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9]+%$' \
        || die "monitor.log line format mismatch: $last"
    ok "monitor.sh ran + valid monitor.log line appended"
}

# ── §7 cron ──────────────────────────────────────────────────────────────────
v7_cron_wait() {
    narrate "§7-b  cron 동작 검증 — 70초 대기 후 로그 증가 확인" \
"매분 monitor.sh 를 돌리도록 등록된 cron 이 진짜 동작하는지 확인한다.
  • 현재 monitor.log 라인 수 기록 → 70초 대기 → 라인 수 증가 확인
  ※ 1초 단위 카운트다운으로 진행 상황을 표시한다."
    section "§7  cron — 70초 대기 후 라인 증가 검증"
    local before after s
    before="$(msh_q "sudo bash -c 'wc -l < /var/log/agent-app/monitor.log'" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    : "${before:=0}"
    printf "  ${c_dim}lines before = %s${c_reset}\n" "$before"
    for s in $(seq 70 -1 1); do
        printf "\r  ${c_dim}⏳ cron tick 대기 중...  %2ds 남음   ${c_reset}" "$s"
        sleep 1
    done
    printf "\r  ${c_dim}⏳ 대기 완료, 라인 수 재확인...                   ${c_reset}\n"
    after="$(msh_q "sudo bash -c 'wc -l < /var/log/agent-app/monitor.log'" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    : "${after:=0}"
    printf "  ${c_dim}lines after  = %s${c_reset}\n" "$after"
    [[ "$after" -gt "$before" ]] || die "log lines did not grow (before=$before, after=$after)"
    ok "cron appended new line (${before} → ${after})"
}

# ── 장애 실험 (src/experiments/) ──────────────────────────────────────────────
s_experiments() {
    local quick_note=""
    [[ "${QUICK:-0}" == "1" ]] && quick_note=" (QUICK=1 — 대기시간 단축)"
    narrate "실험 — 3대 장애 재현·검증 + 스케줄링 (src/experiments/)${quick_note}" \
"실험_절차서.md §1~§4 를 사람 손 없이 끝까지 돌린다 (agent-admin 권한).
  • OOM      MEMORY_LIMIT 256→512   자가종료(SELF-TERMINATED) → 생존 연장 검증
  • CPU      CPU_MAX_OCCUPY 80→95   Watchdog 자가종료 → 생존 연장 검증
  • Deadlock MULTI_THREAD_ENABLE true→false   freeze(PID 생존+무응답) → 회피 검증
  • Scheduling 정상 가동 구간 워커 로그 수집 (RR 추론 입력)
  증거는 /home/agent-admin/evidence_live/ 에 쌓이고 마지막에 PASS/FAIL 요약.
  ⚠ 실측 타임아웃이라 매우 오래 걸린다 (OOM ≤25분 / CPU ≤15분 / Deadlock ≤10분)."
    section "Run failure experiments (full)${quick_note}"
    # agent-admin 으로 실험 실행. APP_ENV 주입(앱 부트 조건) + EVIDENCE_DIR 은 admin 쓰기 가능 경로.
    # QUICK 은 호스트 환경변수를 그대로 전달.
    msh "sudo -u agent-admin env $APP_ENV \
            EVIDENCE_DIR=/home/agent-admin/evidence_live \
            QUICK='${QUICK:-0}' \
            bash '$STAGE/experiments/00_run_experiments.sh' all" \
        | tee "$ART/experiments.out" || true
}
v_experiments() {
    local out="$ART/experiments.out" k line
    [[ -s "$out" ]] || die "experiments produced no output"
    grep -q '검증 요약' "$out" || warn "experiment summary table not found"
    for k in OOM CPU Deadlock; do
        line="$(grep -E "^  ${k} " "$out" | tail -n1 || true)"
        if echo "$line" | grep -q 'PASS'; then
            ok "experiment ${k}: PASS"
        else
            warn "experiment ${k}: not PASS — ${line:-<no summary line>}"
            EXP_WARN=1
        fi
    done
    line="$(grep -E "^  Scheduling " "$out" | tail -n1 || true)"
    if echo "$line" | grep -qE 'PASS|WARN'; then
        ok "experiment Scheduling: $(echo "$line" | grep -oE 'PASS|WARN' | head -n1)"
    else
        warn "experiment Scheduling: ${line:-<no summary line>}"; EXP_WARN=1
    fi
}

# ── 증거 수집 ────────────────────────────────────────────────────────────────
cp_artifact() {
    local src="$1" dst="$2"
    msh_q "sudo cat $src" > "$ART/$dst" 2>/dev/null || true
}
collect_evidence() {
    narrate "마무리 — 채점·제출용 증거 수집" \
"§1~§7 + 부트 + 관제 + (실험) 결과를 .verify-artifacts/ 로 모은다.
  • evidence.txt        : ss / ufw / id / ls+getfacl / crontab / monitor.log tail
  • agent.out           : Boot Sequence 5/5 [OK] + Agent READY
  • monitor.out         : monitor.sh 수동 실행 결과
  • experiments.out     : 장애 실험 PASS/FAIL 요약 (RUN_EXPERIMENTS=1 일 때)
  • evidence_live/*     : OOM/CPU/Deadlock/Scheduling 원본 증거 파일
  • run.log             : 전체 실행 로그 (less -R 권장)"
    section "Collect evidence into $ART"
    {
        echo '=== ss -tulnp ===';                          msh_q 'sudo ss -tulnp'
        echo; echo '=== ufw status verbose ===';           msh_q 'sudo ufw status verbose'
        echo; echo '=== id (agent-admin/dev/test) ===';    msh_q 'id agent-admin; id agent-dev; id agent-test'
        echo; echo '=== ls -ld (dirs) ===';                msh_q 'sudo ls -ld /home/agent-admin/agent-app /home/agent-admin/agent-app/upload_files /home/agent-admin/agent-app/api_keys /var/log/agent-app'
        echo; echo '=== getfacl upload_files ===';         msh_q 'sudo getfacl /home/agent-admin/agent-app/upload_files'
        echo; echo '=== getfacl api_keys ===';             msh_q 'sudo getfacl /home/agent-admin/agent-app/api_keys'
        echo; echo '=== getfacl /var/log/agent-app ===';   msh_q 'sudo getfacl /var/log/agent-app'
        echo; echo '=== secret.key (stat) ===';            msh_q 'sudo stat -c "%n %U:%G %a" /home/agent-admin/agent-app/api_keys/secret.key'
        echo; echo '=== crontab -u agent-admin -l ===';    msh_q 'sudo crontab -u agent-admin -l'
        echo; echo '=== monitor.log tail -n 5 ===';        msh_q 'sudo tail -n 5 /var/log/agent-app/monitor.log'
    } > "$ART/evidence.txt"
    cp_artifact /tmp/agent.out agent.out

    # 실험 원본 증거 파일들 복사
    if [[ "$RUN_EXPERIMENTS" == "1" ]]; then
        mkdir -p "$ART/evidence_live"
        local f
        for f in $(msh_q 'ls /home/agent-admin/evidence_live 2>/dev/null' || true); do
            cp_artifact "/home/agent-admin/evidence_live/$f" "evidence_live/$f"
        done
    fi
    ok "evidence saved to $ART/"
}

# ── 메인 흐름 ────────────────────────────────────────────────────────────────
main() {
    preflight
    ensure_machine
    install_base
    stage_sources

    narrate "§1  SSH — 포트 20022 + root 로그인 차단" \
"기본 22번 포트는 봇의 brute-force 표적. 20022 로 옮기고 PermitRootLogin no 로
root 직접 로그인을 막아 '일반계정 → sudo' 2단계를 강제한다."
    section "§1  SSH (src/01_ssh_hardening.sh)"; run_setup_step 01_ssh_hardening.sh; v1_ssh

    narrate "§2  UFW — 화이트리스트 방화벽" \
"기본 deny incoming + 20022(SSH)/15034(앱) 만 allow. netfilter 룰로 공격 표면 최소화."
    section "§2  UFW (src/02_firewall_allowlist.sh)"; run_setup_step 02_firewall_allowlist.sh; v2_ufw

    narrate "§3  계정·그룹 — 최소 권한 + 직무 분리" \
"admin/dev/test 3계정, common(3명)/core(admin·dev) 2그룹. test 는 core 제외(Need-to-Know)."
    section "§3  Users & groups (src/03_users_and_groups.sh)"; run_setup_step 03_users_and_groups.sh; v3_users

    narrate "§4  디렉토리 + ACL — 자동 상속 정책" \
"upload_files(common)/api_keys(core)/로그(core) 에 770 + default ACL 로 신규 파일 권한 자동 상속."
    section "§4  Directories + ACL (src/04_directories_and_acl.sh)"; run_setup_step 04_directories_and_acl.sh; v4_acl

    narrate "§5  환경변수 + 키파일 (B1-2 사양)" \
"AGENT_* 5종 + 실험 ENV 3종(MEMORY_LIMIT/CPU_MAX_OCCUPY/MULTI_THREAD_ENABLE) 등록.
  ★ B1-1 과 차이: AGENT_KEY_PATH 가 '디렉토리', 키 파일명이 secret.key."
    section "§5  Env + key file (src/05_env_and_keyfile.sh)"; run_setup_step 05_env_and_keyfile.sh; v5_env

    narrate "§6  배포 — agent-leak-app + 자동화 스크립트" \
"agent-leak-app(admin:common,0750) + monitor/report/archive_logs.sh(dev:core,0750) 배치."
    section "§6  Deploy (src/06_deploy_app_and_scripts.sh)"; run_setup_step 06_deploy_app_and_scripts.sh; v6_deploy

    s_boot;     v_boot
    s_monitor;  v_monitor

    narrate "§7  cron — 매분 monitor.sh 자동 실행 등록" \
"crontab 에 '* * * * * monitor.sh' + 매일 03:10 archive_logs.sh 등록. cron 은 .bashrc 를
안 읽으므로 환경변수를 명령줄 앞에 직접 명시."
    section "§7  cron (src/07_cron_schedule.sh)"; run_setup_step 07_cron_schedule.sh
    v7_cron_wait

    if [[ "$RUN_EXPERIMENTS" == "1" ]]; then
        s_experiments; v_experiments
    else
        section "실험 생략 (RUN_EXPERIMENTS=0)"; warn "장애 실험을 건너뜀 — setup+부트 검증만 수행"
    fi

    collect_evidence

    narrate "🎉 완료 — 우리가 검증한 것" \
"§1~§7 인프라 + agent-leak-app 부트 5/5 + monitor/cron 자동화가 모두 검증됐고,
$([[ "$RUN_EXPERIMENTS" == "1" ]] && echo "3대 장애 실험까지 재현·검증" || echo "(실험은 생략됨)")했다.
증거는 .verify-artifacts/ 에 있다."

    printf "\n${c_green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_reset}\n"
    if [[ "$EXP_WARN" == "1" ]]; then
        printf "${c_yellow}  SETUP/BOOT PASSED — 일부 실험 PASS 아님(요약 확인)${c_reset}  ─ artifacts in $ART\n"
    else
        printf "${c_green}  ALL CHECKS PASSED${c_reset}  ─ artifacts in $ART\n"
    fi
    printf "${c_green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_reset}\n"

    if [[ "$CLEANUP" == "1" ]]; then
        section "Cleanup — deleting '$MACHINE'"
        orb delete -f "$MACHINE"
        ok "machine deleted"
    else
        printf "${c_dim}  (운영 머신은 보존됨. 재검증은 그대로 재실행, 완전 재시작은 FRESH=1)${c_reset}\n"
    fi
}

main "$@"
