#!/usr/bin/env node
// Zero-dependency OpenRouter usage poller. Polls GET /api/v1/key on the
// same OPENROUTER_API_KEY the opencode container uses and appends one JSON
// line per poll to LOG_PATH. This is account/key-level cumulative usage,
// not a per-request cost breakdown - good enough for a spend meter and
// trend line, not per-call attribution (see README "Where logs live").

import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';
import fs from 'node:fs';

const API_KEY = process.env.OPENROUTER_API_KEY;
const PROXY_URL = process.env.HTTPS_PROXY || process.env.https_proxy;
const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL || 60) * 1000;
const LOG_PATH = process.env.LOG_PATH || '/logs/openrouter-usage.log';

if (!API_KEY) {
  console.error('[poller] OPENROUTER_API_KEY is not set; exiting');
  process.exit(1);
}

// Minimal CONNECT-tunneling https.Agent so requests route through the
// gateway proxy without adding an npm dependency (e.g. https-proxy-agent).
// Node's own http/https module still does all the request/response
// parsing (headers, chunked encoding, etc.) once the tunnel is up.
class HttpsProxyAgent extends https.Agent {
  constructor(proxyUrl, options) {
    super(options);
    this.proxy = new URL(proxyUrl);
  }

  createConnection(options, callback) {
    const proxySocket = net.connect(Number(this.proxy.port) || 80, this.proxy.hostname);

    proxySocket.once('connect', () => {
      proxySocket.write(
        `CONNECT ${options.host}:${options.port} HTTP/1.1\r\n` +
          `Host: ${options.host}:${options.port}\r\n` +
          `Connection: close\r\n\r\n`
      );
    });

    proxySocket.once('data', (chunk) => {
      const statusLine = chunk.toString('utf8').split('\r\n')[0];
      if (!/^HTTP\/1\.[01] 200/.test(statusLine)) {
        proxySocket.destroy();
        callback(new Error(`proxy CONNECT failed: ${statusLine}`));
        return;
      }
      const tlsSocket = tls.connect(
        { socket: proxySocket, servername: options.servername || options.host },
        () => callback(null, tlsSocket)
      );
      tlsSocket.once('error', callback);
    });

    proxySocket.once('error', callback);
  }
}

const agent = PROXY_URL ? new HttpsProxyAgent(PROXY_URL) : undefined;

function fetchKeyInfo() {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'openrouter.ai',
        path: '/api/v1/key',
        method: 'GET',
        agent,
        headers: { Authorization: `Bearer ${API_KEY}` },
      },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => (raw += chunk));
        res.on('end', () => {
          if (res.statusCode !== 200) {
            reject(new Error(`HTTP ${res.statusCode}: ${raw.slice(0, 200)}`));
            return;
          }
          try {
            resolve(JSON.parse(raw));
          } catch (err) {
            reject(new Error(`bad JSON response: ${err.message}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.end();
  });
}

async function poll() {
  try {
    const body = await fetchKeyInfo();
    const data = body.data ?? body;
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      usage: data.usage,
      limit: data.limit,
      limit_remaining: data.limit_remaining,
      is_free_tier: data.is_free_tier,
    });
    fs.appendFileSync(LOG_PATH, line + '\n');
    console.log(`[poller] ${line}`);
  } catch (err) {
    console.error(`[poller] poll failed: ${err.message}`);
  }
}

poll();
setInterval(poll, POLL_INTERVAL_MS);
