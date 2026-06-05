#!/usr/bin/env bash
# 00_run_experiments.sh — B1-2 3대 장애 재현·검증 파이프라인 오케스트레이터
# =============================================================================
# 무엇을 하나?
#   실험_절차서.md 의 4개 "검증 파이프라인" 을 사람 손 없이 끝까지 돌린다.
#   각 파이프라인 본체는 같은 디렉토리의 번호 스크립트에 들어 있고, 이 파일은
#   사전 점검 → 선택한 파이프라인 실행 → PASS/FAIL 요약을 묶는 wrapper 다.
#
#     01_oom.sh        MEMORY_LIMIT=256 → SELF-TERMINATED 까지 관측 → 512 로 올려 생존 연장 검증
#     02_cpu.sh        CPU_MAX_OCCUPY=80 → WATCHDOG SIGTERM 관측 → 95 로 올려 연장 검증
#     03_deadlock.sh   MULTI_THREAD_ENABLE=true → 무응답(freeze) 관측 → false 로 회피 검증
#     04_scheduling.sh 정상 가동 구간 워커 로그 수집 (Round-Robin 추론 입력)
#     lib_experiment.sh  위 네 스크립트가 공유하는 설정·헬퍼·관측 루프·요약 (직접 실행 안 함)
#
# 산출물 (EVIDENCE_DIR, 기본 = 저장소 루트의 evidence_live/):
#     oom_monitor.log  oom_app.log  oom_ps_top.txt
#     cpu_monitor.log  cpu_app.log  cpu_top_ps.txt        # ← cpu 만 top_ps 순서
#     deadlock_monitor.log  deadlock_app.log  deadlock_ps_top.txt
#     scheduling_workers.log  scheduling_top_h.txt
#
#   ※ 저장소 evidence/ 안의 파일들은 "형식 예시"(실제 실행 로그 아님)이므로,
#     기본 출력은 evidence_live/ 로 분리해 예시를 덮어쓰지 않는다.
#
# 어디서 실행하나?
#   OrbStack Ubuntu 머신 안에서, agent-admin 같은 "일반 계정" 으로 실행한다 (root 금지).
#   먼저 src/00_run_all.sh (01~07 setup) 이 끝나 있어야 하고, $AGENT_HOME/agent-leak-app
#   바이너리가 배치돼 있어야 한다.
#
# 사용법:
#   bash 00_run_experiments.sh [all|oom|cpu|deadlock|scheduling|selftest]
#       (인자 없으면 all)
#   각 파이프라인은 단독 실행도 가능: bash 01_oom.sh  /  bash 03_deadlock.sh  …
#
#   selftest  : 앱을 실행하지 않고 환경/도구/권한만 점검 (배선 확인용)
#
# 자주 쓰는 옵션 (환경변수로 지정):
#   QUICK=1        모든 대기시간을 대폭 단축 (배선 점검·데모용; 실제 장애 재현엔 부적합)
#   RUN_AFTER=0    After(조치) 단계를 건너뛰고 Before(재현)만 수행
#   EVIDENCE_DIR=… 증거 저장 위치 변경
#   SAMPLE_INTERVAL=15  자원 샘플링 간격(초)
#   OOM_BEFORE_TIMEOUT / CPU_BEFORE_TIMEOUT / DEADLOCK_TIMEOUT … 개별 최대 대기(초)
#
# 예)
#   bash 00_run_experiments.sh oom              # OOM 한 개만 Before+After
#   RUN_AFTER=0 bash 00_run_experiments.sh cpu  # CPU 재현만
#   QUICK=1 bash 00_run_experiments.sh all      # 짧게 전체 배선 확인
#
# 제약(미션 규칙): Bash 전용, 일반 계정, 외부 관측 정보(로그/관제)만 사용.
# =============================================================================

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 공통 도구 + 4개 파이프라인의 함수 정의를 끌어온다.
# (01~04 는 BASH_SOURCE==$0 가드가 있어, source 될 때는 함수만 정의되고 실행되지 않는다)
source "${HERE}/lib_experiment.sh"
source "${HERE}/01_oom.sh"
source "${HERE}/02_cpu.sh"
source "${HERE}/03_deadlock.sh"
source "${HERE}/04_scheduling.sh"

usage() {
    # 맨 위 #! 다음부터 첫 비주석 줄 전까지의 헤더 주석 블록을 그대로 보여준다
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
}

main() {
    local cmd="${1:-all}"
    case "$cmd" in
        -h|--help|help) usage; exit 0;;
        selftest)       selftest; exit 0;;
    esac

    preflight "run"

    case "$cmd" in
        oom)              experiment_oom;;
        cpu)              experiment_cpu;;
        deadlock|dl)      experiment_deadlock;;
        scheduling|sched) experiment_scheduling;;
        all)
            experiment_oom
            experiment_cpu
            experiment_deadlock
            experiment_scheduling
            ;;
        *)
            fail "알 수 없는 명령: ${cmd}"
            echo "사용: bash ${0##*/} [all|oom|cpu|deadlock|scheduling|selftest]"
            exit 2
            ;;
    esac

    print_summary
}

main "$@"
