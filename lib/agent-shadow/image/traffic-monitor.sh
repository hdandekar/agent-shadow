#!/bin/sh
# traffic-monitor.sh — records each new DNS lookup and outbound TCP connection to /root/.traffic.log
# (a record for review, not protection: root in the container can stop it or edit the log)
#   traffic-monitor.sh                 capture with tcpdump and record (started by entrypoint.sh)
#   traffic-monitor.sh --record-only   record `tcpdump -l -n` lines read from stdin (used by the tests)
LOGFILE="${TRAFFIC_LOG:-/root/.traffic.log}"
FILTER="${TRAFFIC_FILTER:-/usr/local/lib/agent-shadow/traffic-filter.awk}"

# mawk (Ubuntu's awk) reads a pipe in large blocks unless -W interactive: without it, the few
# lines of a short session wait in its buffer and are lost when the container stops.
# (</dev/null: an awk without -W, e.g. macOS's, takes "version" as a program and would read,
# and swallow, the tcpdump lines on stdin)
AWK=awk
awk -W version </dev/null 2>/dev/null | grep mawk >/dev/null && AWK="awk -W interactive"

record() { $AWK -v logfile="$LOGFILE" -f "$FILTER"; }
if [ "${1:-}" = --record-only ]; then record; exit; fi

touch "$LOGFILE"
while true; do
  tcpdump -l -n -i any 'udp port 53 or (tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0 and not src net 127.0.0.0/8)' 2>/dev/null | record
  sleep 2
done
