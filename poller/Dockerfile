FROM node:22-bookworm-slim

COPY poller.mjs /poller.mjs

ENV NO_PROXY=localhost,127.0.0.1

CMD ["node", "/poller.mjs"]
