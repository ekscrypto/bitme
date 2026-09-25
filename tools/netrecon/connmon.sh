#!/bin/zsh
# connmon.sh — lightweight connection monitor for macOS.
# Polls lsof for TCP/UDP sockets and logs every connection that appears or
# disappears, with a timestamp and the raw lsof line (process, pid, endpoint,
# connection state). Short-lived connections are the login/bootstrap traffic we
# care about, so the poll interval is a fraction of a second by default.
#
# Usage: connmon.sh <output-log> [poll-interval-seconds]

set -u

OUT=${1:?usage: connmon.sh <output-log> [poll-interval-seconds]}
INTERVAL=${2:-0.25}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

snapshot() {
  # Key on pid + NAME (NAME includes the TCP state suffix), keep the whole
  # line so the log stays human-readable even when COMMAND contains spaces.
  lsof +c0 -nP -i 2>/dev/null | awk 'NR>1 {print $2"|"$NF"|"$0}' | sort -t'|' -k1,1 -k2,2
}

snapshot > "$TMP/prev"
date '+%F %T' >> "$OUT"
echo "connmon started (interval ${INTERVAL}s); baseline connections follow" >> "$OUT"
sed 's/^/BASELINE|/' "$TMP/prev" >> "$OUT"

while true; do
  snapshot > "$TMP/cur"
  comm -13 "$TMP/prev" "$TMP/cur" | while IFS= read -r line; do
    echo "$(date '+%F %T')|NEW|$line" >> "$OUT"
  done
  comm -23 "$TMP/prev" "$TMP/cur" | while IFS= read -r line; do
    echo "$(date '+%F %T')|GONE|$line" >> "$OUT"
  done
  mv "$TMP/cur" "$TMP/prev"
  sleep "$INTERVAL"
done
