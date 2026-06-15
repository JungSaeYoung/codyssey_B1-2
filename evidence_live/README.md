# evidence_live/ — 재실행(실측) 산출물 전용 폴더

이 폴더는 **장애 실험을 재실행했을 때 생성되는 실측 증거**가 쌓이는 곳이다.
실험 스크립트의 기본 출력 경로(`EVIDENCE_DIR`)가 이 폴더로 지정돼 있다
([src/experiments/lib_experiment.sh](../src/experiments/lib_experiment.sh) 의 `DEFAULT_EVIDENCE`).

## 왜 `evidence/` 와 분리돼 있나
- [`../evidence/`](../evidence) : 리포트([reports/*.md](../reports))가 1:1로 인용하는 **큐레이션된 제출본**.
  PID·타임스탬프·수치가 리포트 본문·`docs/html` 과 일치해야 하므로 **덮어쓰지 않는다.**
- `evidence_live/` : 재실행 결과가 쌓이는 곳. 매 실행마다 값(PID·시각·%)이 달라지는 게 정상이며,
  `evidence/` 와 **패턴·비율을 비교(검증)** 하는 용도로 쓴다.

## 생성되는 파일 (실험 완주 시)
```
oom_monitor.log       oom_app.log       oom_ps_top.txt
cpu_monitor.log       cpu_app.log       cpu_top_ps.txt
deadlock_monitor.log  deadlock_app.log  deadlock_ps_top.txt
scheduling_workers.log                  scheduling_top_h.txt
```

## 사용
```bash
# 기본 출력 경로가 이 폴더이므로 EVIDENCE_DIR 지정 없이 그대로 실행하면 여기에 쌓인다.
bash src/experiments/00_run_experiments.sh

# 경로를 명시하고 싶다면
EVIDENCE_DIR="$(git rev-parse --show-toplevel)/evidence_live" \
  bash src/experiments/00_run_experiments.sh
```

> - 실험 실행에는 `agent-leak-app`(Linux ELF)이 도는 환경(OrbStack Ubuntu VM 등)이 필요하다.
> - `demo.sh` / `verify_orbstack.sh` 로 돌리면 결과는 호스트의 `.verify-artifacts/evidence_live/` 에도 모인다.
> - 이 폴더의 산출물은 `.gitignore` 로 git 추적에서 제외된다 (이 `README.md` 만 추적).
