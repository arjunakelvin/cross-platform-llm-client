const https = require('https');
const http = require('http');
const { URL } = require('url');

// Batas waktu dan ukuran respons supaya proxy tidak jadi抓手 gratis.
const REQUEST_TIMEOUT_MS = 120000;
const MAX_RESPONSE_BYTES = 32 * 1024 * 1024;

/**
 * Host yang tidak boleh jadi target proxy (SSRF): jaringan internal,
 * link-local, metadata cloud, dan loopback.
 */
function isBlockedHost(hostname) {
  const host = String(hostname || '').toLowerCase().replace(/^\[|\]$/g, '');
  if (!host) return true;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host === 'metadata.google.internal' || host.endsWith('.internal')) {
    return true;
  }
  if (host === '::1' || host === '0.0.0.0') return true;
  const v4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const a = Number(v4[1]);
    const b = Number(v4[2]);
    if (a === 10 || a === 127 || a === 0) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 169 && b === 254) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;
  }
  return false;
}

module.exports = async (req, res) => {
  // CORS Headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS, HEAD');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Expose-Headers', '*');

  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.end();
    return;
  }

  // Get target URL from query param
  const targetUrl = req.query.url;
  if (!targetUrl) {
    res.statusCode = 400;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ error: 'Missing target URL in query parameter "url"' }));
    return;
  }

  let parsed;
  try {
    parsed = new URL(targetUrl);
  } catch (err) {
    res.statusCode = 400;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ error: 'Invalid target URL' }));
    return;
  }

  // Hanya http(s). Target http://127.0.0.1 tetap boleh untuk AI server
  // lokal saat dev, tapi jaringan internal lain ditolak.
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    res.statusCode = 400;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ error: 'Only http/https targets are allowed' }));
    return;
  }
  if (isBlockedHost(parsed.hostname)) {
    res.statusCode = 400;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ error: 'Target host is not allowed' }));
    return;
  }

  const transport = parsed.protocol === 'https:' ? https : http;

  // Filter incoming headers to forward to target.
  // Cookie dan kunci internal situs (admin/bot) TIDAK boleh ikut forwarded.
  // Authorization + X-Secret-Key tetap diteruskan karena dipakai app untuk
  // memanggil provider OpenAI-compatible / AI server milik user.
  const forwardHeaders = {};
  for (const [key, value] of Object.entries(req.headers)) {
    const lk = key.toLowerCase();
    if (lk === 'host' || lk === 'origin' || lk === 'referer'
        || lk === 'content-length' || lk === 'cookie'
        || lk === 'x-admin-key' || lk === 'x-bot-key') {
      continue;
    }
    forwardHeaders[key] = value;
  }
  forwardHeaders['host'] = parsed.host;

  // Read request body if present
  let bodyBuffer = null;
  if (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') {
    bodyBuffer = await new Promise((resolve) => {
      const chunks = [];
      req.on('data', (chunk) => chunks.push(chunk));
      req.on('end', () => resolve(Buffer.concat(chunks)));
    });
    if (bodyBuffer && bodyBuffer.length > 0) {
      forwardHeaders['content-length'] = bodyBuffer.length;
    }
  }

  const options = {
    method: req.method,
    hostname: parsed.hostname,
    port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
    path: parsed.pathname + parsed.search,
    headers: forwardHeaders,
    timeout: REQUEST_TIMEOUT_MS,
  };

  const proxyReq = transport.request(options, (proxyRes) => {
    // Cegah redirect ke jaringan internal.
    const location = proxyRes.headers.location;
    if (location && proxyRes.statusCode >= 300 && proxyRes.statusCode < 400) {
      try {
        const next = new URL(location, parsed);
        if (isBlockedHost(next.hostname)) {
          res.statusCode = 400;
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ error: 'Redirect target is not allowed' }));
          proxyRes.destroy();
          return;
        }
      } catch (err) {
        // Lolos saja kalau URL redirect tidak bisa diparse.
      }
    }

    res.statusCode = proxyRes.statusCode;

    // Copy headers from target response except those that conflict
    for (const [key, value] of Object.entries(proxyRes.headers)) {
      const lk = key.toLowerCase();
      if (lk !== 'access-control-allow-origin' &&
        lk !== 'access-control-allow-methods' &&
        lk !== 'access-control-allow-headers' &&
        lk !== 'content-encoding' &&
        lk !== 'content-length') {
        res.setHeader(key, value);
      }
    }
    // Re-assert CORS
    res.setHeader('Access-Control-Allow-Origin', '*');

    // Batasi ukuran respons supaya tidak jadi tempat simpan file besar.
    let received = 0;
    proxyRes.on('data', (chunk) => {
      received += chunk.length;
      if (received > MAX_RESPONSE_BYTES) {
        res.statusCode = 502;
        res.end();
        proxyRes.destroy();
        return;
      }
    });

    // Pipe response directly (handles streaming SSE seamlessly)
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (err) => {
    if (!res.headersSent) {
      res.statusCode = 502;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ error: 'Proxy request failed: ' + err.message }));
    }
  });

  proxyReq.setTimeout(REQUEST_TIMEOUT_MS, () => {
    proxyReq.destroy(new Error('timeout'));
  });

  if (bodyBuffer && bodyBuffer.length > 0) {
    proxyReq.write(bodyBuffer);
  }
  proxyReq.end();
};
