#!/usr/bin/env bash
# archive_logs.sh — 시간 기반 로그 보존 정책 (보너스 2)
#   - 7일 경과 *.log → gzip 압축 후 archive 디렉토리로 이동
#   - archive/*.gz 중 30일 경과 → 삭제
# 권장 cron: 매일 03:10  (agent-admin)
#   10 3 * * * /home/agent-admin/agent-app/bin/archive_logs.sh

set -u

SRC_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="/var/log/monitor/agent-app/archive"

# ── 사전 점검
if [[ ! -d "${SRC_DIR}" ]]; then
    echo "[WARNING] Source log directory not found: ${SRC_DIR}" >&2
    exit 0
fi
if ! mkdir -p "${ARCHIVE_DIR}" 2>/dev/null; then
    echo "[ERROR] Cannot create archive directory: ${ARCHIVE_DIR}" >&2
    exit 1
fi
if [[ ! -w "${ARCHIVE_DIR}" ]]; then
    echo "[ERROR] Archive directory not writable: ${ARCHIVE_DIR}" >&2
    exit 1
fi

# ── 1) 7일 이상 경과 *.log 압축 + 이동
COMPRESSED=0
while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    ts="$(date '+%Y%m%d_%H%M%S')"
    target="${ARCHIVE_DIR}/${base}.${ts}.gz"
    if gzip -c "${f}" > "${target}" 2>/dev/null; then
        rm -f "${f}"
        COMPRESSED=$((COMPRESSED + 1))
    else
        echo "[WARNING] Failed to compress: ${f}" >&2
    fi
done < <(find "${SRC_DIR}" -maxdepth 1 -type f -name '*.log' -mtime +7 -print0 2>/dev/null)

# ── 2) 30일 이상 경과 *.gz 삭제
DELETED=0
while IFS= read -r -d '' f; do
    rm -f "${f}" && DELETED=$((DELETED + 1))
done < <(find "${ARCHIVE_DIR}" -maxdepth 1 -type f -name '*.gz' -mtime +30 -print0 2>/dev/null)

echo "[INFO] archive_logs.sh done. compressed=${COMPRESSED}, deleted=${DELETED}"
exit 0
