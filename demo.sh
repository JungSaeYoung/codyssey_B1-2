#!/usr/bin/env bash
# demo.sh — macOS + OrbStack 에서 B1-2 미션 전체를 시연용으로 한 번에 돌린다.
#
# 사용법:
#   ./demo.sh              # 깨끗한 머신 + 시연 모드(섹션마다 엔터 대기) + 실험 전체(실측)
#   ./demo.sh --keep       # 기존 머신 재사용
#   ./demo.sh --shell      # 시연 끝나고 머신 안 셸로 자동 진입
#   ./demo.sh --fast       # 시연 모드 끄고 한 번에 자동 실행 (CI 처럼)
#   ./demo.sh --quick      # 장애 실험 대기시간 단축 (라이브 시연 권장)
#   ./demo.sh --no-exp     # setup + 부트 검증까지만, 장애 실험 생략
#
# 전제:
#   - macOS + OrbStack 설치/1회 이상 실행 (`brew install orbstack`)
#   - 이 디렉토리에 src/0N_*.sh, src/{monitor,report,archive_logs}.sh,
#     src/experiments/*.sh, 운영 측 제공 bin/agent-leak-app 존재

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ── OrbStack 업데이트 알림 억제 (verify_orbstack.sh 에서도 다시 설정함) ──────
export ORBSTACK_NO_UPDATE_CHECK=1
export ORB_NO_UPDATE_CHECK=1
export ORB_DISABLE_UPDATE_NOTIFY=1
export DO_NOT_TRACK=1

# ── 옵션 파싱 ────────────────────────────────────────────────────────────────
KEEP=0
ENTER_SHELL=0
NARRATE_MODE=1
QUICK_MODE=0
RUN_EXP=1
for arg in "$@"; do
    case "$arg" in
        --keep)   KEEP=1 ;;
        --shell)  ENTER_SHELL=1 ;;
        --fast)   NARRATE_MODE=0 ;;
        --quick)  QUICK_MODE=1 ;;
        --no-exp) RUN_EXP=0 ;;
        --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# ── 색상 ─────────────────────────────────────────────────────────────────────
B="$(printf '\033[1m')"; D="$(printf '\033[2m')"; R="$(printf '\033[0m')"
C="$(printf '\033[1;36m')"; G="$(printf '\033[1;32m')"; Y="$(printf '\033[1;33m')"

banner() {
    printf "\n${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}\n"
    printf "${C}%s${R}\n" "$1"
    printf "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}\n"
}

# ── 전제 점검 ────────────────────────────────────────────────────────────────
banner "Codyssey B1-2 — 자동 시연 (macOS + OrbStack)"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf "${Y}⚠ 이 스크립트는 macOS 전용이다. 현재 OS: $(uname -s)${R}\n"
    exit 1
fi
command -v orb >/dev/null 2>&1 || {
    printf "${Y}⚠ 'orb' CLI 가 PATH 에 없다. OrbStack 을 설치/실행했는지 확인:${R}\n"
    printf "    brew install orbstack && open -a OrbStack\n"
    exit 1
}
for f in src/00_run_all.sh src/monitor.sh src/report.sh src/archive_logs.sh \
         src/experiments/00_run_experiments.sh src/experiments/lib_experiment.sh \
         bin/agent-leak-app verify_orbstack.sh; do
    if [[ ! -f "$f" ]]; then
        printf "${Y}⚠ 필요한 파일이 없다: %s${R}\n" "$f"
        [[ "$f" == "bin/agent-leak-app" ]] && \
            printf "    (운영 측 제공 바이너리를 bin/agent-leak-app 에 배치)\n"
        exit 1
    fi
done

# Windows/zip 경유로 옮긴 경우 실행 비트(x)가 빠져 있을 수 있다.
chmod +x verify_orbstack.sh \
         src/*.sh src/experiments/*.sh \
         bin/agent-leak-app 2>/dev/null || true

printf "${G}✓ macOS + orb CLI + 소스 파일 + agent-leak-app 모두 준비됨${R}\n"

# ── 시연 안내 ────────────────────────────────────────────────────────────────
cat <<EOF

${B}시연 흐름${R}
  ${D}1.${R} ${C}codyssey-demo${R} Ubuntu 24.04 머신을 띄운다 (없으면 자동 생성)
  ${D}2.${R} §1~§7 setup + 검증: SSH(20022)·UFW·계정·ACL·env·배포·cron
  ${D}3.${R} agent-leak-app 부트 5/5 [OK] + 'Agent READY' + monitor.sh·cron 동작
  ${D}4.${R} $([[ "$RUN_EXP" == "1" ]] && echo "3대 장애 실험(OOM/CPU/Deadlock) + 스케줄링 재현·검증" || echo "(장애 실험은 --no-exp 로 생략)")
  ${D}5.${R} 결과 산출물(.verify-artifacts/) 을 Finder 로 자동 오픈
  ${D}6.${R} (옵션) --shell 이면 머신 셸로 진입

${B}시연 모드${R} (NARRATE_MODE=$NARRATE_MODE)
EOF

if [[ "$NARRATE_MODE" == "1" ]]; then
    cat <<EOF
  ${G}● 켜짐${R} — 각 섹션 시작 전 ${Y}노란 박스${R} 설명 + ${B}엔터 대기${R}.
            엔터→실행, ${B}s${R}→건너뛰기, ${B}q${R}→종료. 발표용.
EOF
else
    cat <<EOF
  ${C}● 꺼짐${R} — 일시정지 없이 한 번에 끝까지 실행 (--fast).
EOF
fi

if [[ "$RUN_EXP" == "1" && "$QUICK_MODE" == "0" ]]; then
    cat <<EOF

${Y}⚠ 장애 실험 '전체(실측)' 모드 — 매우 오래 걸린다 (OOM ≤25분 / CPU ≤15분 / Deadlock ≤10분).
   라이브 시연이라면 ${B}--quick${R}${Y}(대기 단축) 또는 ${B}--no-exp${R}${Y}(실험 생략)를 권장.${R}
EOF
fi

cat <<EOF

${D}예상 소요: setup+부트 ~3분 / 실험 전체 +40분~1시간 / --quick 이면 +수 분${R}

EOF

read -p "엔터로 시작 (Ctrl+C 로 취소): " _

# ── 본 실행 ──────────────────────────────────────────────────────────────────
export MACHINE_NAME="codyssey-demo"
if [[ "$KEEP" == "0" ]]; then
    export FRESH=1
fi
export NARRATE="$NARRATE_MODE"
export QUICK="$QUICK_MODE"
export RUN_EXPERIMENTS="$RUN_EXP"

banner "▶ verify_orbstack.sh 실행 (MACHINE=$MACHINE_NAME, FRESH=${FRESH:-0}, NARRATE=$NARRATE, QUICK=$QUICK, RUN_EXPERIMENTS=$RUN_EXPERIMENTS)"
./verify_orbstack.sh

# ── 결과 안내 + Finder 열기 ──────────────────────────────────────────────────
ART_DIR="$(pwd)/.verify-artifacts"
banner "✅ 시연 완료 — 산출물 안내"
printf "  📁  %s\n" "$ART_DIR"
printf "\n${D}파일 목록:${R}\n"
ls -lh "$ART_DIR" 2>/dev/null | sed 's/^/    /'

cat <<EOF

${B}산출물 설명${R}

  ${C}📄 evidence.txt${R}        ${D}— 채점·제출용 종합 증거${R}
      ss / ufw / id 3계정 / ls+getfacl x3 / secret.key / crontab / monitor.log tail

  ${C}📄 agent.out${R}           ${D}— agent-leak-app Boot Sequence 5/5 [OK] + Agent READY${R}

  ${C}📄 monitor.out${R}         ${D}— monitor.sh 수동 실행 결과 (HEALTH/RESOURCE/INFO)${R}

  ${C}📄 experiments.out${R}     ${D}— 3대 장애 + 스케줄링 PASS/FAIL 요약${R}
      ${D}(RUN_EXPERIMENTS=1 일 때만)${R}

  ${C}📁 evidence_live/${R}      ${D}— 실험 원본 증거${R}
      oom_*.{log,txt} / cpu_*.{log,txt} / deadlock_*.{log,txt} / scheduling_*
      → reports/0{1,2,3,4}_*.md 의 Evidence 섹션에 인용
      ${D}(실행 중 맥의 ./evidence_live/ 로도 실시간 누적됨 — 큐레이션된 evidence/ 는 보존)${R}

  ${C}📄 run.log${R}             ${D}— 전체 실행 로그 (less -R 권장)${R}

${B}빠르게 다시 보기${R}
  cat $ART_DIR/evidence.txt
  cat $ART_DIR/experiments.out
  less -R $ART_DIR/run.log

EOF

# Finder 자동 오픈
if command -v open >/dev/null 2>&1; then
    open "$ART_DIR" 2>/dev/null || true
fi

# ── 다음 단계 안내 ──────────────────────────────────────────────────────────
cat <<EOF

${B}이제 할 수 있는 것들${R}

  ${C}# 머신 안에 들어가 직접 확인${R}
  orb shell -m $MACHINE_NAME

  ${C}# 장애 실험을 하나만 다시 (agent-admin 권한)${R}
  orb -m $MACHINE_NAME sudo -u agent-admin env \\
      AGENT_HOME=/home/agent-admin/agent-app AGENT_PORT=15034 \\
      AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files \\
      AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys \\
      AGENT_LOG_DIR=/var/log/agent-app EVIDENCE_DIR=/home/agent-admin/evidence_live \\
      bash /tmp/codyssey-b1-2/experiments/01_oom.sh

  ${C}# cron 로그 실시간 추적${R}
  orb -m $MACHINE_NAME sudo tail -f /var/log/agent-app/monitor.log

  ${C}# 시연 끝나면 머신 정리${R}
  orb delete -f $MACHINE_NAME

EOF

# ── 옵션: 셸 진입 ────────────────────────────────────────────────────────────
if [[ "$ENTER_SHELL" == "1" ]]; then
    banner "▶ 머신 셸로 진입 (exit 으로 빠져나오기)"
    orb shell -m "$MACHINE_NAME"
fi
