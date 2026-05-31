#!/usr/bin/env bash
# 02_firewall_allowlist.sh
# -----------------------------------------------------------------------------
# 단계 2 / 7 — UFW 방화벽 화이트리스트
#   • 들어오는 통신: 기본 거부 (default deny incoming)
#   • 나가는 통신:   기본 허용 (default allow outgoing)
#   • 예외만 허용:   20022/tcp (SSH), 15034/tcp (AGENT APP)
#   • systemd unit 도 명시적으로 enable + start
#     (OrbStack 같은 환경에선 `ufw enable` 만으론 unit 이 활성화되지 않을 수 있음)
#
# 실행 위치: 머신 안
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

if ! command -v ufw >/dev/null 2>&1; then
    step "ufw 패키지 설치 중..."
    sudo apt-get update -qq
    sudo apt-get install -y ufw
else
    step "ufw 이미 설치돼 있음"
fi

step "기본 정책: incoming = deny, outgoing = allow"
sudo ufw default deny incoming
sudo ufw default allow outgoing

step "예외 허용: 20022/tcp (SSH)"
sudo ufw allow 20022/tcp comment 'SSH'
step "예외 허용: 15034/tcp (AGENT APP)"
sudo ufw allow 15034/tcp comment 'AGENT APP'

step "ufw 활성화 (룰 적용)"
sudo ufw --force enable

step "ufw.service systemd unit enable + start"
sudo systemctl enable --now ufw

# 검증
echo
echo "─── 검증 ────────────────────────────"
sudo ufw status verbose
echo "─────────────────────────────────────"
echo "[02] Firewall allowlist 완료"
