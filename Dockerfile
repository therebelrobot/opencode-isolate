FROM node:22-bookworm-slim

ARG OPENCODE_VERSION=latest
# Set to 1 to bake in strace for the isolation check in README.md. It can't
# be installed at container runtime - the isolated network only allows
# openrouter.ai, so `apt-get install` from inside a running container has
# nowhere to fetch packages from. Rebuild with this arg, run the check,
# then rebuild without it; don't ship strace in the default image.
ARG INSTALL_STRACE=0

# curl deliberately excluded: it's proxy-aware and opencode.json already
# denies `curl *`, so keeping the binary in the image would just be a
# redundant exfil client sitting inside the sandbox. Note the bash
# `curl */wget */nc *` denies in opencode.json are glob-fragile (they miss
# `/usr/bin/curl`, `env curl`, library calls) and are defense-in-depth
# only - the isolated network + gateway is what actually contains egress.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git ripgrep \
      $([ "$INSTALL_STRACE" = "1" ] && echo strace) \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g opencode-ai@${OPENCODE_VERSION} && opencode --version

RUN useradd -m agent \
    && mkdir -p /home/agent/.config/opencode \
    && chown -R agent:agent /home/agent/.config
USER agent
WORKDIR /workspace

ENV OPENCODE_DISABLE_AUTOUPDATE=1
ENV NO_PROXY=localhost,127.0.0.1

ENTRYPOINT []
CMD ["opencode"]
