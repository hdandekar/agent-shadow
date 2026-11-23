# Egress approval proxy for --isolated workspaces. Its config is not baked in: agent-shadow mounts
# ~/.config/agent-shadow/egress/<slug>/ read-only at /cfg and reloads it with SIGUSR1.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tinyproxy && \
    rm -rf /var/lib/apt/lists/*
# PID 1 is tinyproxy itself, so `kill -USR1 1` reloads the allowlist
ENTRYPOINT ["tinyproxy", "-d", "-c", "/cfg/tinyproxy.conf"]
