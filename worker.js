/**
 * worker.js — GateWatch Proxy Worker
 *
 * Identifica al usuario (KV / JWT / API key), enriquece la request con
 * cf-aig-metadata y la reenvía a CF AI Gateway. El routing de modelos se
 * gestiona visualmente desde Dynamic Routes en la UI de Cloudflare AI Gateway
 * — el worker no toma ninguna decisión de modelo.
 *
 * Rutas propias:
 *   GET    /gatewatch/health       → health check público
 *   POST   /gatewatch/token        → emite un API key personal para un usuario
 *   GET    /gatewatch/tokens       → lista todos los tokens activos (admin)
 *   DELETE /gatewatch/token/:key   → revoca un token (admin)
 *
 * Todas las demás rutas → proxy hacia CF AI Gateway con cf-aig-metadata.
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // ── Rutas internas de GateWatch ──────────────────────────────────────────
    if (url.pathname.startsWith('/gatewatch/')) {
      return handleGatewatchRoute(request, url, env);
    }

    // ── Proxy con enriquecimiento y routing ──────────────────────────────────
    if (!env.GATEWAY_BASE_URL) {
      return jsonResponse({ error: 'GATEWAY_BASE_URL not configured' }, 500);
    }

    const requestId   = crypto.randomUUID();
    const hostnameMap = parseJSON(env.WORKERS_HOSTNAME_MAP, {});
    const defaultEnv  = env.DEFAULT_ENV || 'production';

    // 1. Detectar streaming
    const { isStreaming } = await analyzeRequest(request);

    // 2. Resolver identidad del usuario
    const { metadata, inferenceMethod } = await buildEnrichedMetadata(
      request, env, requestId, hostnameMap, defaultEnv,
    );

    console.log(JSON.stringify({
      worker:           'gatewatch-proxy',
      request_id:       metadata.id,
      usuario:          metadata.usuario,
      departamento:     metadata.departamento,
      project:          metadata.project,
      inference_method: inferenceMethod,
      streaming:        isStreaming,
      ts:               new Date().toISOString(),
    }));

    // 3. Construir headers de salida
    const outboundHeaders = new Headers(request.headers);

    // CF AI Gateway limita cf-aig-metadata a 5 campos (strings/numbers/booleans).
    // El routing de modelos lo gestiona CF AI Gateway Dynamic Routes desde la UI
    // — el worker solo aporta la identidad para que el gateway pueda decidir.
    const gatewayMetadata = {
      usuario:      metadata.usuario,
      departamento: metadata.departamento,
      project:      metadata.project,
      env:          metadata.env,
      request_id:   metadata.id,
    };
    outboundHeaders.set('cf-aig-metadata', JSON.stringify(gatewayMetadata));

    // cf-aig-authorization autentica el acceso al AI Gateway.
    // Authorization se elimina siempre — es el token GateWatch del cliente
    // y no debe llegar al proveedor downstream.
    if (env.GATEWAY_AUTH_HEADER) {
      outboundHeaders.set('cf-aig-authorization', env.GATEWAY_AUTH_HEADER);
    }
    outboundHeaders.delete('Authorization');

    // 4. Enviar al gateway — el body se pasa tal cual, sin reescribir el model
    const proxyBody = ['GET', 'HEAD'].includes(request.method) ? null : request.body;

    let upstreamResponse;
    try {
      upstreamResponse = await fetch(
        new Request(buildGatewayUrl(request, env.GATEWAY_BASE_URL), {
          method:  request.method,
          headers: outboundHeaders,
          body:    proxyBody,
        }),
      );
    } catch (err) {
      console.error(JSON.stringify({ worker: 'gatewatch-proxy', error: String(err), request_id: metadata.id, ts: new Date().toISOString() }));
      return jsonResponse({ error: 'Gateway unreachable' }, 502);
    }

    const responseHeaders = new Headers(upstreamResponse.headers);
    responseHeaders.set('x-gatewatch-enriched', 'true');
    responseHeaders.set('x-gatewatch-request-id', metadata.id);

    return new Response(upstreamResponse.body, {
      status:     upstreamResponse.status,
      statusText: upstreamResponse.statusText,
      headers:    responseHeaders,
    });
  },
};

// ─── Rutas internas /gatewatch/* ─────────────────────────────────────────────

async function handleGatewatchRoute(request, url, env) {
  const path   = url.pathname;
  const method = request.method;

  if (path === '/gatewatch/health' && method === 'GET') {
    return jsonResponse({ status: 'ok', worker: 'gatewatch-proxy', ts: new Date().toISOString() });
  }

  if (path === '/gatewatch/token' && method === 'POST') {
    if (!isAdmin(request, env)) return jsonResponse({ error: 'Unauthorized' }, 401);
    return issueToken(request, env);
  }

  if (path === '/gatewatch/tokens' && method === 'GET') {
    if (!isAdmin(request, env)) return jsonResponse({ error: 'Unauthorized' }, 401);
    return listTokens(env);
  }

  const revokeMatch = path.match(/^\/gatewatch\/token\/(.+)$/);
  if (revokeMatch && method === 'DELETE') {
    if (!isAdmin(request, env)) return jsonResponse({ error: 'Unauthorized' }, 401);
    return revokeToken(revokeMatch[1], env);
  }

  return jsonResponse({ error: 'Not found' }, 404);
}

// ─── Gestión de identidades ───────────────────────────────────────────────────

async function issueToken(request, env) {
  let body;
  try { body = await request.json(); }
  catch { return jsonResponse({ error: 'Invalid JSON body' }, 400); }

  const { usuario, departamento, project, client, env: userEnv, expires_in } = body;
  if (!usuario) return jsonResponse({ error: 'usuario is required' }, 400);

  // Si el usuario ya existe en KV, reutiliza sus datos — no hace falta repetirlos
  const existingKeys = parseJSON(await env.IDENTITIES.get(`idx:${usuario}`), []);
  let existingIdentity = null;
  for (const key of existingKeys) {
    const raw = await env.IDENTITIES.get(`key:${key}`);
    if (raw) { existingIdentity = parseJSON(raw, null); break; }
  }

  const apiKey    = `gw-${crypto.randomUUID()}`;
  const now       = Date.now();
  const ttlSecs   = parseTTL(expires_in) ?? 86400;
  const expiresAt = new Date(now + ttlSecs * 1000).toISOString();

  const identity = {
    usuario:      usuario,
    departamento: departamento || existingIdentity?.departamento || 'unknown',
    project:      project      || existingIdentity?.project      || 'unknown',
    client:       client       || existingIdentity?.client       || 'unknown',
    env:          userEnv      || existingIdentity?.env          || env.DEFAULT_ENV || 'production',
    created_at:   new Date(now).toISOString(),
    expires_at:   expiresAt,
  };

  await env.IDENTITIES.put(`key:${apiKey}`, JSON.stringify(identity), { expirationTtl: ttlSecs });

  const indexKey = `idx:${usuario}`;
  const existing = parseJSON(await env.IDENTITIES.get(indexKey), []);
  existing.push(apiKey);
  await env.IDENTITIES.put(indexKey, JSON.stringify(existing), { expirationTtl: ttlSecs + 3600 });

  console.log(JSON.stringify({ worker: 'gatewatch-proxy', event: 'token_issued', usuario, departamento: identity.departamento, expires_at: expiresAt, ts: new Date().toISOString() }));

  return jsonResponse({ api_key: apiKey, expires_at: expiresAt, identity });
}

async function listTokens(env) {
  const { keys } = await env.IDENTITIES.list({ prefix: 'key:' });
  const tokens = await Promise.all(
    keys.map(async ({ name, expiration }) => {
      const identity = parseJSON(await env.IDENTITIES.get(name), {});
      // Las API keys nunca se exponen después de su creación
      return {
        key_hint:    name.replace('key:', '').slice(0, 10) + '…',
        expires_at:  expiration ? new Date(expiration * 1000).toISOString() : null,
        usuario:     identity.usuario,
        departamento:identity.departamento,
        project:     identity.project,
        client:      identity.client,
        env:         identity.env,
        created_at:  identity.created_at,
      };
    }),
  );
  return jsonResponse({ count: tokens.length, tokens });
}

async function revokeToken(apiKey, env) {
  const clean = apiKey.startsWith('gw-') ? apiKey : `gw-${apiKey}`;
  const raw = await env.IDENTITIES.get(`key:${clean}`);
  const identity = parseJSON(raw, null);
  await env.IDENTITIES.delete(`key:${clean}`);

  if (identity?.usuario) {
    const indexKey = `idx:${identity.usuario}`;
    const keys = parseJSON(await env.IDENTITIES.get(indexKey), []);
    const updated = keys.filter((k) => k !== clean);
    if (updated.length > 0) {
      await env.IDENTITIES.put(indexKey, JSON.stringify(updated));
    } else {
      await env.IDENTITIES.delete(indexKey);
    }
  }

  return jsonResponse({ revoked: clean });
}

async function lookupIdentity(token, env) {
  if (!token.startsWith('gw-')) return null;
  try {
    const raw = await env.IDENTITIES.get(`key:${token}`);
    return parseJSON(raw, null);
  } catch (err) {
    console.error(JSON.stringify({ worker: 'gatewatch-proxy', event: 'kv_error', error: String(err) }));
    return null;
  }
}

// ─── Análisis de la request ───────────────────────────────────────────────────

async function analyzeRequest(request) {
  const streamFromHeaders = detectStreamingFromHeaders(request);

  const contentType = request.headers.get('Content-Type') || '';
  if (!request.body || !contentType.includes('application/json') || request.method === 'GET') {
    return { isStreaming: streamFromHeaders };
  }

  try {
    const cloned   = request.clone();
    const bodyText = await Promise.race([
      cloned.text(),
      new Promise((resolve) => setTimeout(() => resolve(null), 500)),
    ]);
    if (!bodyText) return { isStreaming: streamFromHeaders };
    const parsed = JSON.parse(bodyText);
    return { isStreaming: streamFromHeaders || parsed.stream === true };
  } catch {
    return { isStreaming: streamFromHeaders };
  }
}

function detectStreamingFromHeaders(request) {
  if (request.headers.get('Accept') === 'text/event-stream') return true;
  return new URL(request.url).pathname.includes('/stream');
}

// ─── Enriquecimiento de metadatos ─────────────────────────────────────────────

async function buildEnrichedMetadata(request, env, requestId, hostnameMap, defaultEnv) {
  const url           = new URL(request.url);
  const sourceCountry = request.cf?.country ?? 'unknown';
  const sessionId     = request.headers.get('cf-aig-session-id') || requestId;

  const meta = {
    client:            'unknown',
    project:           'unknown',
    usuario:           'unknown',
    departamento:      'unknown',
    id:                sessionId,
    env:               defaultEnv,
    source_ip_country: sourceCountry,
    timestamp:         new Date().toISOString(),
  };
  let inferenceMethod = 'fallback';

  const rawAuth = request.headers.get('Authorization') || '';
  const token   = rawAuth.startsWith('Bearer ') ? rawAuth.slice(7) : rawAuth;

  // KV lookup — identidad emitida por este worker
  if (token.startsWith('gw-') && env.IDENTITIES) {
    const identity = await lookupIdentity(token, env);
    if (identity) {
      meta.usuario      = identity.usuario      || 'unknown';
      meta.departamento = identity.departamento || 'unknown';
      meta.project      = identity.project      || 'unknown';
      meta.client       = identity.client       || 'unknown';
      meta.env          = identity.env          || defaultEnv;
      inferenceMethod   = 'kv_identity';
    }
  }

  // JWT Bearer
  if (inferenceMethod === 'fallback' && token && looksLikeJWT(token)) {
    const payload = decodeJWTPayload(token);
    if (payload) {
      if (payload.sub)                        meta.usuario      = String(payload.sub);
      if (payload.dept || payload.department) meta.departamento = String(payload.dept ?? payload.department);
      if (payload.project)                    meta.project      = String(payload.project);
      if (payload.client)                     meta.client       = String(payload.client);
      if (payload.env)                        meta.env          = String(payload.env);
      inferenceMethod = 'jwt';
    }
  }

  // Formato CLIENT-ENV-RANDOM
  if (inferenceMethod === 'fallback' && token && !looksLikeJWT(token)) {
    const parts = token.split('-');
    if (parts.length >= 3) {
      meta.client = parts[0];
      meta.env    = normalizeEnv(parts[1]);
      inferenceMethod = 'apikey';
    }
  }

  // Hostname map
  const hostData = hostnameMap[url.hostname];
  if (hostData) {
    if (meta.client       === 'unknown' && hostData.client)       meta.client       = hostData.client;
    if (meta.departamento === 'unknown' && hostData.departamento) meta.departamento = hostData.departamento;
    if (meta.project      === 'unknown' && hostData.project)      meta.project      = hostData.project;
    if (inferenceMethod   === 'fallback') inferenceMethod = 'hostname';
  } else if (meta.client === 'unknown') {
    const subdomain = url.hostname.split('.')[0];
    if (subdomain) {
      meta.client = subdomain;
      if (inferenceMethod === 'fallback') inferenceMethod = 'hostname';
    }
  }

  return { metadata: meta, inferenceMethod };
}

// ─── Gateway URL ──────────────────────────────────────────────────────────────

function buildGatewayUrl(request, baseUrl) {
  const url  = new URL(request.url);
  const base = new URL(baseUrl);
  base.pathname = base.pathname.replace(/\/$/, '') + url.pathname;
  base.search   = url.search;
  return base.toString();
}

// ─── Admin auth ───────────────────────────────────────────────────────────────

function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const aBytes = enc.encode(a);
  const bBytes = enc.encode(b);
  if (aBytes.byteLength !== bBytes.byteLength) return false;
  return crypto.subtle.timingSafeEqual(aBytes, bBytes);
}

function isAdmin(request, env) {
  if (!env.ADMIN_SECRET) return false;
  const header = request.headers.get('x-admin-secret') || request.headers.get('Authorization') || '';
  return timingSafeEqual(header, env.ADMIN_SECRET) || timingSafeEqual(header, `Bearer ${env.ADMIN_SECRET}`);
}

// ─── JWT helpers ──────────────────────────────────────────────────────────────

function looksLikeJWT(token) {
  const parts = token.split('.');
  return parts.length === 3 && parts.every((p) => p.length > 0);
}

function decodeJWTPayload(token) {
  try {
    let b64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    while (b64.length % 4) b64 += '=';
    return JSON.parse(atob(b64));
  } catch {
    return null;
  }
}

// ─── Utilidades ───────────────────────────────────────────────────────────────

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function parseJSON(str, fallback) {
  if (!str) return fallback;
  try { return JSON.parse(str); } catch { return fallback; }
}

function normalizeEnv(str) {
  const map = { prod: 'production', production: 'production', dev: 'development', development: 'development', stg: 'staging', staging: 'staging' };
  return map[str?.trim().toLowerCase()] ?? str ?? 'unknown';
}

const MAX_TTL_SECS = 7_776_000; // 90 days

function parseTTL(expires_in) {
  if (!expires_in) return null;
  if (typeof expires_in === 'number') return Math.min(expires_in, MAX_TTL_SECS);
  const match = String(expires_in).trim().match(/^(\d+)(h|d|m)?$/);
  if (!match) return null;
  const n = parseInt(match[1], 10);
  const unit = match[2] || 'h';
  const secs = unit === 'd' ? n * 86400 : unit === 'm' ? n * 60 : n * 3600;
  return Math.min(secs, MAX_TTL_SECS);
}
