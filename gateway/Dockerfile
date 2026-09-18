FROM ubuntu/squid:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends iptables \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Overriding ENTRYPOINT resets the base image's CMD, so restore it here.
# Our script does the iptables setup, then hands off to the base image's
# own entrypoint.sh (still on PATH) with these same args.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["-f", "/etc/squid/squid.conf", "-NYC"]
