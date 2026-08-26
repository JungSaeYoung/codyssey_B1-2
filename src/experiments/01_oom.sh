#!/usr/bin/env bash
# 01_oom.sh — OOM(메모리 한계 초과) 장애 재현·검증
# -----------------------------------------------------------------------------
# 실험_절차서.md §1 에 대응.
#   Before  MEMORY_LIMIT=256 (CPU_MAX_OCCUPY=10 고정) → 'Memory limit exceeded' + 'Self-terminating process' 자가종료 관측
#   After   MEMORY_LIMIT=512 (CPU_MAX_OCCUPY=10 고정) → 생존시간 연장 검증
#   증거    oom_monitor.log / oom_app.log / oom_ps_top.txt
#
# 자가종료형이라 공통 코어 _terminating_experiment (lib_experiment.sh §6) 를 그대로 쓴다.
#
# 단독 실행:  bash 01_oom.sh            (사전점검 → OOM 실험 → 요약)
# 옵션 예:    QUICK=1 bash 01_oom.sh    RUN_AFTER=0 bash 01_oom.sh
# 일괄 실행:  bash 00_run_experiments.sh oom
# -----------------------------------------------------------------------------

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_experiment.sh"

experiment_oom() {
    # 종료 시그니처: 'Memory limit exceeded' / 'Self-terminating process'
    # (실측 문구: [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB)
    #             [CRITICAL] [MemoryGuard] Self-terminating process 2721162 …)
    # PDF 예시의 'SELF-TERMINATED' 배너는 이 바이너리가 출력하지 않는다.
    #
    # [고침] CPU_MAX_OCCUPY 를 95 → 10 으로 내렸다. 이유(실측):
    #   앱은 부팅 시 Resource Check 결과로 "시나리오" 하나를 고른다.
    #     MEMORY_LIMIT <= 256           → 메모리 누수 시나리오 (MemoryWorker 단독)
    #     MEMORY_LIMIT > 256 & CPU > 50 → CPU 과점유 시나리오 (CpuWorker 단독)
    #     둘 다 안전                     → [Healthy System Monitoring]
    #   따라서 예전 조합(After: MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95)은 After 가 "OOM 이 늦게 온다"가
    #   아니라 "CpuWorker 가 대신 죽인다"가 돼 34초에 exit 143 으로 끝났다(= 개선 0). 실측 확인:
    #     MEM=256 CPU=95 → 34s exit 137 (MemoryGuard)
    #     MEM=512 CPU=95 → 34s exit 143 (CpuWorker! 메모리와 무관)
    #     MEM=512 CPU=10 → 180s 관측 종료까지 생존
    #   CPU 를 안전값(10)으로 고정해 MEMORY_LIMIT 만 단일 변수로 비교한다.
    _terminating_experiment "OOM" "self-terminat|limit exceeded" \
        oom_monitor.log oom_app.log oom_ps_top.txt \
        "export MEMORY_LIMIT=256 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false" \
        "export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false" \
        "$OOM_BEFORE_TIMEOUT"
}

# 직접 실행할 때만 단독 파이프라인을 돈다. (오케스트레이터가 source 로 함수만 가져갈 때는 통과)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == selftest ]] && { selftest; exit 0; }   # 단독 실행도 배선만 점검 가능
    preflight "run"
    experiment_oom
    print_summary
fi
