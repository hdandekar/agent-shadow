#!/bin/sh
# entrypoint.sh — runs once when the container starts (container exec does not run it)
touch /root/.traffic.log 2>/dev/null || true
chattr +a /root/.traffic.log 2>/dev/null || true   # append-only: a hint, root can undo it
if command -v tcpdump >/dev/null 2>&1; then
  (/usr/local/bin/traffic-monitor.sh >/dev/null 2>&1 &)
fi
exec "$@"
