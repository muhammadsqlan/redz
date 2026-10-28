const RELEASE = 'https://github.com/muhammadsqlan/redz/releases/download/v0.3.2';
const REDIRECTS = new Map([
  ['/download', `${RELEASE}/ReDZ-0.3.2-arm64.dmg`],
  ['/source', 'https://github.com/muhammadsqlan/redz/tree/v0.3.2'],
  ['/checksums', `${RELEASE}/SHA256SUMS.txt`],
  ['/dependency-sources', `${RELEASE}/ReDZ-0.3.2-dependency-sources.tar.gz`],
]);
const ASSETS = new Map([
  ['', '/index.html'],
  ['/', '/index.html'],
  ['/styles.css', '/styles.css'],
  ['/favicon.svg', '/favicon.svg'],
  ['/install', '/install.html'],
  ['/install/', '/install.html'],
  ['/licenses', '/licenses.html'],
  ['/licenses/', '/licenses.html'],
  ['/release.json', '/release.json'],
]);

function secure(response) {
  const result = new Response(response.body, response);
  result.headers.set('X-Content-Type-Options', 'nosniff');
  result.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  result.headers.set('Content-Security-Policy', "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  result.headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  result.headers.set('X-ReDZ-Version', '0.3.2');
  return result;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Only /redz belongs to this application. Preserve similarly named paths.
    if (url.pathname !== '/redz' && !url.pathname.startsWith('/redz/')) {
      if (url.hostname === 'muhammadsqlan.com') return fetch(request);
      if (url.pathname === '/') return secure(Response.redirect(new URL('/redz/', url), 302));
      return secure(new Response('Not found', { status: 404 }));
    }
    if (!['GET', 'HEAD'].includes(request.method)) {
      return secure(new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } }));
    }
    const path = url.pathname.slice('/redz'.length);
    const target = REDIRECTS.get(path);
    if (target) {
      return secure(new Response(null, { status: 302, headers: { Location: target, 'Cache-Control': 'public, max-age=300' } }));
    }
    const asset = ASSETS.get(path);
    if (!asset) return secure(new Response(request.method === 'HEAD' ? null : 'Not found', { status: 404 }));
    const assetUrl = new URL(asset, url);
    const response = await env.ASSETS.fetch(new Request(assetUrl, { method: request.method, headers: request.headers }));
    return secure(response);
  },
};
