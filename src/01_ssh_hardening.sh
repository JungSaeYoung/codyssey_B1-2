#!/usr/bin/env bash
# 01_ssh_hardening.sh
# -----------------------------------------------------------------------------
# 단계 1 / 7 — SSH 보안 강화
#   • Port 22 → 20022 (자동 봇 스캔 회피)
#   • PermitRootLogin no (root 직접 로그인 차단 → 일반계정 + sudo 2단계 강제)
#   • ssh.socket 비활성화 (Ubuntu 24.04 의 socket-activation 우회)
#   • ssh.service enable + restart
#
# 실행 위치: 머신 안 (OrbStack Ubuntu 24.04 권장)
# 권한:      sudo 가능한 계정 (예: ashofrondol9475)
# -----------------------------------------------------------------------------

set -eu

# 진행 표시 헬퍼 (침묵 명령 앞에 무엇을 하는지 알림)
step() { printf "  ▶ %s\n" "$*"; }

# OrbStack 미니멀 이미지엔 openssh-server 가 빠져 있을 수 있다.
if [[ ! -f /etc/ssh/sshd_config ]]; then
    step "openssh-server 가 없어 설치 중..."
    sudo apt-get update -qq
    sudo apt-get install -y openssh-server
else
    step "openssh-server 이미 설치돼 있음"
fi

step "/etc/ssh/sshd_config 백업 → sshd_config.bak.$(date +%Y%m%d)"
sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)

step "Port → 20022, PermitRootLogin → no 로 in-place 수정"
sudo sed -i -E \
    -e 's/^#?Port .*/Port 20022/' \
    -e 's/^#?PermitRootLogin .*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

step "ssh.socket 비활성화 (Ubuntu 24.04 의 socket-activation 우회)"
sudo systemctl disable --now ssh.socket 2>/dev/null || true

step "ssh.service enable + restart"
sudo systemctl enable ssh
sudo systemctl restart ssh

# 검증
echo
echo "─── 검증 ────────────────────────────"
sudo grep -E '^(Port|PermitRootLogin)\b' /etc/ssh/sshd_config
sudo ss -tulnp | grep -E ':20022\b' || true
echo "─────────────────────────────────────"
echo "[01] SSH hardening 완료"
