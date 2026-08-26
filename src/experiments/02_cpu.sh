#!/usr/bin/env bash
# 02_cpu.sh — CPU 과점유 장애 재현·검증
# -----------------------------------------------------------------------------
# 실험_절차서.md §2 에 대응.
#   Before  CPU_MAX_OCCUPY=80  → '[CpuWorker] CPU Threshold Violated!' (Watchdog 보호 조치) 관측
#   After   CPU_MAX_OCCUPY=10  → 종료 소멸(관측 구간 전체 생존) 검증  ← 상향이 아니라 '하향'
#   증거    cpu_monitor.log / cpu_app.log / cpu_top_ps.txt
#
# 자가종료형이라 공통 코어 _terminating_experiment (lib_experiment.sh §6) 를 그대로 쓴다.
#
# 단독 실행:  bash 02_cpu.sh            (사전점검 → CPU 실험 → 요약)
# 옵션 예:    QUICK=1 bash 02_cpu.sh    RUN_AFTER=0 bash 02_cpu.sh
# 일괄 실행:  bash 00_run_experiments.sh cpu
# -----------------------------------------------------------------------------

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_experiment.sh"

experiment_cpu() {
    # 종료 시그니처.
    # [고침] 실측한 바이너리는 'EMERGENCY ABORT' / 'SIGTERM' 문자열을 한 번도 찍지 않는다.
    #   실제 보호 조치 라인은  [CRITICAL] [CpuWorker] CPU Threshold Violated! (53.72%).
    #   그리고 이 라인 이후 프로세스가 곧바로 죽지 않고 조용해지기만 하므로,
    #   시그니처를 못 잡으면 관측 루프가 CPU_BEFORE_TIMEOUT(기본 15분)을 통째로 소진한다.
    #   → 실제 문구를 1순위로 넣고, 다른 빌드 대비 기존 토큰도 대안으로 남긴다.
    # 정상 동작 중의 INFO '[CpuWorker] Current Load: 46.47%' 에는 이 토큰이 없어 조기 오탐은 없다.
    #
    # ※ 조치 방향 — 임계점을 직접 측정해 After 를 "상향(95)" 에서 "하향(10)" 으로 바꿨다.
    #   CPU_MAX_OCCUPY 를 바꿔가며 실측한 결과(MEMORY_LIMIT=512, MULTI_THREAD_ENABLE=false 고정):
    #     CPU_MAX_OCCUPY=95 → 34초 사망. 트립 지점 Current Load 58.93%
    #     CPU_MAX_OCCUPY=80 → 30초 사망. 트립 지점 Current Load 53.72%
    #     CPU_MAX_OCCUPY=60 → 43초 사망. 트립 지점 Current Load 57.39%
    #     CPU_MAX_OCCUPY=50 → 122초 관측 종료까지 생존 ([Healthy System Monitoring])
    #     CPU_MAX_OCCUPY=10 → 180초 관측 종료까지 생존 (Peak reached → cooldown 18회 순환)
    #   즉 프로세스를 죽이는 트립 라인은 CPU_MAX_OCCUPY 가 아니라 부팅 배너가 경고하는
    #   고정 50%("[ WARNING: Recommend Under 50% ]") 다. 그래서 80→95 상향은 무의미하고
    #   (둘 다 50% 를 넘김) 임계점은 50 과 60 사이에 있다. 50 이하로 내리면 CPU 과점유
    #   시나리오 자체가 선택되지 않아 종료가 사라진다.
    #   → A6("조정하여 종료 여부 또는 생존 시간 변화를 확인")을 만족시키는 조정은 "하향" 이다.
    _terminating_experiment "CPU" "cpu threshold violated|emergency abort|sigterm" \
        cpu_monitor.log cpu_app.log cpu_top_ps.txt \
        "export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=80 MULTI_THREAD_ENABLE=false" \
        "export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false" \
        "$CPU_BEFORE_TIMEOUT"
}

# 직접 실행할 때만 단독 파이프라인을 돈다. (오케스트레이터가 source 로 함수만 가져갈 때는 통과)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == selftest ]] && { selftest; exit 0; }   # 단독 실행도 배선만 점검 가능
    preflight "run"
    experiment_cpu
    print_summary
fi
