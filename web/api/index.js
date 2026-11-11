const https = require('https');
const http = require('http');
const { URL } = require('url');

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

  const transport = parsed.protocol === 'https:' ? https : http;

  // Filter incoming headers to forward to target
  const forwardHeaders = {};
  for (const [key, value] of Object.entries(req.headers)) {
    const lk = key.toLowerCase();
    if (lk !== 'host' && lk !== 'origin' && lk !== 'referer' && lk !== 'content-length') {
      forwardHeaders[key] = value;
    }
  }
  forwardHeaders['host'] = parsed.host;

  // Read request body if present
  let bodyBuffer = null;
  if (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') {
    bodyBuffer = await new Promise((resolve) => {
      const chunks = [];
      req.on('data', chunk => chunks.push(chunk));
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
  };

  const proxyReq = transport.request(options, (proxyRes) => {
    res.statusCode = proxyRes.statusCode;
    
    // Copy headers from target response except those that conflict
    for (const [key, value] of Object.entries(proxyRes.headers)) {
      const lk = key.toLowerCase();
      if (lk !== 'access-control-allow-origin' &&
          lk !== 'access-control-allow-methods' &&
          lk !== 'access-control-allow-headers' &&
          lk !== 'content-encoding') {
        res.setHeader(key, value);
      }
    }
    // Re-assert CORS
    res.setHeader('Access-Control-Allow-Origin', '*');

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

  if (bodyBuffer && bodyBuffer.length > 0) {
    proxyReq.write(bodyBuffer);
  }
  proxyReq.end();
};
