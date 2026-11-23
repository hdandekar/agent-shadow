# traffic-filter.awk — turns `tcpdump -l -n` lines into one log entry per new destination:
#   <date time>\tDNS\t<name>        for "A? name." / "AAAA? name." queries
#   <date time>\tTCP\t<ip>:<port>   for outbound SYNs ("Flags [S]")
# Only loopback (127.0.0.0/8) and 0.0.0.0 are skipped. The network gateway (the Mac) is
# recorded like any other address: connections to Mac services are what matters most.
# Usage: awk -v logfile=FILE -f traffic-filter.awk   (existing entries in FILE are not repeated)
BEGIN {
  while ((getline line < logfile) > 0) { if (split(line, f, "\t") >= 3) seen[f[3]] = 1 }
  close(logfile)
}
function record(type, target,   ts, cmd) {
  if (target in seen) return
  seen[target] = 1
  cmd = "date +\"%Y-%m-%d %H:%M:%S\""; cmd | getline ts; close(cmd)
  print ts "\t" type "\t" target >> logfile
  fflush(logfile)
}
/ A\? | AAAA\? / {
  for (i = 1; i < NF; i++) {
    if ($i == "A?" || $i == "AAAA?") {
      name = $(i + 1); sub(/\.$/, "", name)
      if (name != "localhost" && name !~ /\.(internal|local)$/) record("DNS", name)
    }
  }
  next
}
/ > / && /Flags \[S\]/ {
  for (i = 1; i < NF; i++) {
    if ($i == ">") {
      dst = $(i + 1); sub(/:$/, "", dst)
      if (split(dst, p, ".") >= 5) {
        ip = p[1] "." p[2] "." p[3] "." p[4]
        if (ip !~ /^127\./ && ip != "0.0.0.0") record("TCP", ip ":" p[5])
      }
    }
  }
}
