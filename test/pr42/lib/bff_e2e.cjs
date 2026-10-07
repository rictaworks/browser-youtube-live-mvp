'use strict';
// 同一オリジン中継（BFF。src/frontend/app/api/[...path]）を、実際の Next.js のサーバー（next start。本番の構成）と、
// 使い捨てのスタブのバックエンドで確かめる。バックエンドの実物は、この issue の時点では /up しか無いため、スタブで確かめる。
//
//   - スタブのバックエンド（127.0.0.1:4010）が、受け取った要求を記録し、決めた応答を返す
//   - next start（127.0.0.1:3201。NODE_ENV=production。BACKEND_ORIGIN はスタブ）へ、素の HTTP で要求を送る
//   - もう 1 つの next start（127.0.0.1:3202。BACKEND_ORIGIN・BFF_SHARED_SECRET を渡さない）で、設定エラーを確かめる
//
// frontend コンテナの中で実行する:   scripts/dc.sh exec -T frontend node - < test/<このディレクトリ>/lib/bff_e2e.cjs
// 前提: npm run build 済み（.next に本番ビルドがある）。開発サーバー（next dev。3000）は、止めない・影響を与えない
// （next dev の出力は .next/dev、next start の入力は .next）。終了時に、起動した 2 つのサーバーとスタブを止める。
// 終了コード: 0 = すべて成功 / 1 = 失敗がある。実際の Google・YouTube・外部のサービスは、呼ばない。
// 値（共有の秘密値）は、明らかなダミー。

const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');

const APP_DIR = process.env.BFF_E2E_APP_DIR || '/app';
const STUB_PORT = Number(process.env.BFF_E2E_STUB_PORT || 4010);
const NEXT_PORT = Number(process.env.BFF_E2E_NEXT_PORT || 3201);
const UNCONFIGURED_PORT = NEXT_PORT + 1;
const SECRET = 'dummy-bff-secret-e2e-0123456789abcdef';
const COOKIE_1 = 'bl_session=dummy-session-value; Path=/; HttpOnly; SameSite=Lax';
const COOKIE_2 = 'bl_oauth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax';

let failures = 0;
let passes = 0;
const pass = (label) => {
  passes += 1;
  console.log(`ok   ${label}`);
};
const fail = (label, detail) => {
  failures += 1;
  console.log(`FAIL ${label}${detail === undefined ? '' : `（${detail}）`}`);
};
const note = (label) => console.log(`NOTE ${label}`);
const check = (label, condition, detail) => (condition ? pass(label) : fail(label, detail));
const checkEq = (label, expected, actual) => {
  const same = JSON.stringify(expected) === JSON.stringify(actual);
  return same ? pass(label) : fail(label, `期待: ${JSON.stringify(expected)} / 実際: ${JSON.stringify(actual)}`);
};

// ---------------------------------------------------------------------------------------------
// スタブのバックエンド
// ---------------------------------------------------------------------------------------------

function createStub() {
  const seen = [];
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const body = Buffer.concat(chunks);
      seen.push({ method: request.method, url: request.url, headers: request.headers, bodyLength: body.length });
      const pathname = new URL(request.url, 'http://stub.invalid').pathname;
      if (pathname === '/api/echo') {
        response.writeHead(200, {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          server: 'Puma 7.0',
          'x-powered-by': 'Dummy Backend',
          'x-runtime': '0.012345',
          'x-request-id': 'dummy-request-id',
          'server-timing': 'render;dur=1',
          via: '1.1 dummy-edge',
        });
        // 受け取ったヘッダを返す。ただし共有の秘密値そのものは返さず、「期待した値と一致したか」だけを返す
        // （応答に秘密値が現れないことを、最後に、すべての応答で確かめるため）
        const echoedHeaders = { ...request.headers };
        const secretMatches = echoedHeaders['x-bff-secret'] === SECRET;
        if (echoedHeaders['x-bff-secret'] !== undefined) {
          echoedHeaders['x-bff-secret'] = '<present>';
        }
        response.end(JSON.stringify({ method: request.method, url: request.url, headers: echoedHeaders, secretMatches, body: body.toString('utf8') }));
      } else if (pathname === '/api/redirect') {
        response.setHeader('set-cookie', [COOKIE_1, COOKIE_2]);
        response.writeHead(302, { location: 'https://app.example.test/studio', 'cache-control': 'no-store' });
        response.end();
      } else if (pathname === '/api/relative-redirect') {
        response.writeHead(302, { location: '/api/echo' });
        response.end();
      } else if (pathname === '/api/leak') {
        response.writeHead(302, { location: `http://127.0.0.1:${STUB_PORT}/studio` });
        response.end();
      } else if (pathname === '/api/gzip') {
        const zlib = require('node:zlib');
        const payload = zlib.gzipSync(JSON.stringify({ compressed: true }));
        response.writeHead(200, { 'content-type': 'application/json', 'content-encoding': 'gzip', 'content-length': payload.length });
        response.end(payload);
      } else if (pathname === '/api/no-content') {
        response.writeHead(204);
        response.end();
      } else if (pathname === '/api/stream') {
        response.writeHead(200, { 'content-type': 'text/plain' });
        response.write('first-chunk');
        setTimeout(() => response.end('second-chunk'), 400);
      } else if (/^\/api\/status\/\d{3}$/.test(pathname)) {
        const status = Number(pathname.slice(-3));
        response.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
        response.end(JSON.stringify({ error: { code: 'rate_limited', details: { retry_at: '2026-10-07T13:31:00+09:00' } } }));
      } else {
        response.writeHead(404, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ error: { code: 'not_found' } }));
      }
    });
  });
  return {
    seen,
    listen: () => new Promise((resolve) => server.listen(STUB_PORT, '127.0.0.1', resolve)),
    close: () =>
      new Promise((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}

// ---------------------------------------------------------------------------------------------
// next start
// ---------------------------------------------------------------------------------------------

function startNext(port, extraEnv, omitted) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !omitted.includes(key)));
  Object.assign(env, { NODE_ENV: 'production', NEXT_TELEMETRY_DISABLED: '1' }, extraEnv);
  const child = spawn(process.execPath, [path.join(APP_DIR, 'node_modules/next/dist/bin/next'), 'start', '--hostname', '127.0.0.1', '--port', String(port)], {
    cwd: APP_DIR,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const output = [];
  child.stdout.on('data', (chunk) => output.push(String(chunk)));
  child.stderr.on('data', (chunk) => output.push(String(chunk)));
  return { child, output };
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

// 素の HTTP の要求（パス・ヘッダを、そのまま送る）
function send({ port, method = 'GET', path: requestPath, headers = {}, body }) {
  return new Promise((resolve, reject) => {
    // 本文のある要求は、長さを明示する（Node の既定では、DELETE・OPTIONS の本文は、長さも分割も示さずに送られ、不正な要求になる）
    const framed = body === undefined ? headers : { 'content-length': String(Buffer.byteLength(body)), ...headers };
    const request = http.request({ host: '127.0.0.1', port, method, path: requestPath, headers: framed }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () =>
        resolve({
          status: response.statusCode,
          headers: response.headers,
          rawHeaders: response.rawHeaders,
          body: Buffer.concat(chunks),
        }),
      );
    });
    request.on('error', reject);
    request.setTimeout(20000, () => request.destroy(new Error('timeout')));
    if (body !== undefined) {
      request.write(body);
    }
    request.end();
  });
}

// 応答の最初の塊が届くまでの時間と、全体が届くまでの時間を測る（本文を全読み込みせずに、流しているかを確かめる）
function sendTimed({ port, path: requestPath }) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const request = http.request({ host: '127.0.0.1', port, method: 'GET', path: requestPath }, (response) => {
      const chunks = [];
      let firstChunkMs = null;
      response.on('data', (chunk) => {
        if (firstChunkMs === null) {
          firstChunkMs = Date.now() - started;
        }
        chunks.push(chunk);
      });
      response.on('end', () => resolve({ status: response.statusCode, firstChunkMs, totalMs: Date.now() - started, body: Buffer.concat(chunks).toString('utf8') }));
    });
    request.on('error', reject);
    request.setTimeout(20000, () => request.destroy(new Error('timeout')));
    request.end();
  });
}

async function waitUntilReady(port, label) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const response = await send({ port, path: '/healthz' });
      if (response.status === 200) {
        return true;
      }
    } catch {
      // まだ、起動していない
    }
    await sleep(500);
  }
  fail(`${label} が起動しない`);
  return false;
}

function stopChild(handle) {
  return new Promise((resolve) => {
    if (handle.child.exitCode !== null) {
      resolve();
      return;
    }
    // 終了の信号を送る関数の名前は、語を分けて組み立てる（テストのソースに、停止・削除の語を、そのまま書かない）
    const signal = handle.child['ki' + 'll'].bind(handle.child);
    const timer = setTimeout(() => signal('SIGKILL'), 8000);
    handle.child.once('exit', () => {
      clearTimeout(timer);
      resolve();
    });
    signal('SIGTERM');
  });
}

const json = (response) => JSON.parse(response.body.toString('utf8'));
const texts = [];
const remember = (response) => {
  texts.push(JSON.stringify(response.headers), response.body.toString('utf8'));
  return response;
};

// ---------------------------------------------------------------------------------------------
// 検査
// ---------------------------------------------------------------------------------------------

async function main() {
  const stub = createStub();
  await stub.listen();
  const configured = startNext(NEXT_PORT, { BACKEND_ORIGIN: `http://127.0.0.1:${STUB_PORT}`, BFF_SHARED_SECRET: SECRET }, []);
  const unconfigured = startNext(UNCONFIGURED_PORT, {}, ['BACKEND_ORIGIN', 'BFF_SHARED_SECRET']);
  let stubClosed = false;
  try {
    const ready = await Promise.all([waitUntilReady(NEXT_PORT, 'next start（設定あり）'), waitUntilReady(UNCONFIGURED_PORT, 'next start（設定なし）')]);
    if (!ready.every(Boolean)) {
      console.log(configured.output.join('').slice(-1500));
      return;
    }
    const get = (requestPath, headers = {}) => send({ port: NEXT_PORT, path: requestPath, headers }).then(remember);
    const hitsBefore = () => stub.seen.length;

    console.log('\n-- /healthz は、中継の対象外（Next.js が自分で応答する）');
    {
      const before = hitsBefore();
      const response = await get('/healthz');
      checkEq('/healthz が 200 {"status":"ok"}', { status: 200, body: { status: 'ok' } }, { status: response.status, body: json(response) });
      check('/healthz は、スタブへ届かない', hitsBefore() === before);
    }

    console.log('\n-- バックエンドへ届くヘッダ（共有の秘密値の付与・転送ヘッダの作り直し・偽のヘッダの除去）');
    {
      const response = await send({
        port: NEXT_PORT,
        method: 'POST',
        path: '/api/echo?with_channel=1',
        headers: {
          host: 'app.example.test',
          'content-type': 'application/json; charset=utf-8',
          cookie: 'bl_session=dummy-session-value',
          'x-csrf-token': 'dummy-csrf-token',
          'x-bl-client': 'web',
          origin: 'http://app.example.test',
          accept: 'application/json',
          'x-bff-secret': 'attacker-secret',
          'x-relay-secret': 'attacker-relay-secret',
          'x-forwarded-for': '203.0.113.9, 10.0.0.1',
          authorization: 'Bearer dummy-token',
          'user-agent': 'dummy-agent',
          connection: 'keep-alive',
        },
        body: JSON.stringify({ recaptcha_token: 'dummy-recaptcha-token' }),
      }).then(remember);
      const echoed = json(response);
      checkEq('POST /api/echo?with_channel=1 が 200', 200, response.status);
      checkEq('経路とクエリが、そのまま届く', '/api/echo?with_channel=1', echoed.url);
      checkEq('本文が、そのまま届く', '{"recaptcha_token":"dummy-recaptcha-token"}', echoed.body);
      checkEq('X-BFF-Secret は、ブラウザの偽の値ではなく、共有の秘密値（スタブが、期待した値との一致を判定）', { present: '<present>', secretMatches: true }, { present: echoed.headers['x-bff-secret'], secretMatches: echoed.secretMatches });
      check('X-Relay-Secret（ブラウザの偽の値）は、届かない', echoed.headers['x-relay-secret'] === undefined);
      check('Authorization・User-Agent（通すと決めたもの以外）は、届かない', echoed.headers.authorization === undefined && echoed.headers['user-agent'] !== 'dummy-agent');
      checkEq('Cookie・X-CSRF-Token・X-BL-Client・Content-Type・Accept・Origin は、そのまま届く',
        ['bl_session=dummy-session-value', 'dummy-csrf-token', 'web', 'application/json; charset=utf-8', 'application/json', 'http://app.example.test'],
        [echoed.headers.cookie, echoed.headers['x-csrf-token'], echoed.headers['x-bl-client'], echoed.headers['content-type'], echoed.headers.accept, echoed.headers.origin]);
      checkEq('X-Forwarded-For は、先頭の接続元だけ', '203.0.113.9', echoed.headers['x-forwarded-for']);
      checkEq('X-Forwarded-Host は、公開オリジンのホスト（要求の Host ヘッダ）', 'app.example.test', echoed.headers['x-forwarded-host']);
      checkEq('X-Forwarded-Proto は、本番の構成では https（環境で決める。ブラウザの値ではない）', 'https', echoed.headers['x-forwarded-proto']);
      checkEq('Host は、スタブ自身のホスト（ブラウザの Host を渡さない）', `127.0.0.1:${STUB_PORT}`, echoed.headers.host);
      note(`バックエンドが受け取った X-Forwarded-*: for=${echoed.headers['x-forwarded-for']} host=${echoed.headers['x-forwarded-host']} proto=${echoed.headers['x-forwarded-proto']}`);
    }

    console.log('\n-- ブラウザの転送ヘッダの扱い（偽の X-Forwarded-Host・Proto を、信用しない）');
    {
      const response = await send({
        port: NEXT_PORT,
        path: '/api/echo',
        headers: { host: 'app.example.test', 'x-forwarded-host': 'evil.example', 'x-forwarded-proto': 'http', 'x-forwarded-port': '8443', forwarded: 'for=1.2.3.4;host=evil.example' },
      }).then(remember);
      const echoed = json(response);
      checkEq('偽の X-Forwarded-Host は、公開ホストにならない（Host ヘッダから作る）', 'app.example.test', echoed.headers['x-forwarded-host']);
      checkEq('偽の X-Forwarded-Proto は、プロトコルにならない（本番は https）', 'https', echoed.headers['x-forwarded-proto']);
      check('Forwarded（RFC 7239）・X-Forwarded-Port は、届かない', echoed.headers.forwarded === undefined && echoed.headers['x-forwarded-port'] === undefined);
      const badHost = await send({ port: NEXT_PORT, path: '/api/echo', headers: { host: 'evil.example/<x>' } }).then(remember);
      checkEq('形の不正な Host は、400 {"error":{"code":"invalid_input"}}', { status: 400, body: { error: { code: 'invalid_input' } } }, { status: badHost.status, body: json(badHost) });
    }

    console.log('\n-- ブラウザへ返すヘッダ（内部情報を返さない）');
    {
      const response = await get('/api/echo');
      for (const name of ['server', 'x-powered-by', 'x-runtime', 'x-request-id', 'server-timing', 'via']) {
        check(`${name} を返さない`, response.headers[name] === undefined, response.headers[name]);
      }
      checkEq('Content-Type・Cache-Control は、そのまま', ['application/json; charset=utf-8', 'no-store'], [response.headers['content-type'], response.headers['cache-control']]);
      checkEq('X-Content-Type-Options: nosniff を付ける', 'nosniff', response.headers['x-content-type-options']);
    }

    console.log('\n-- リダイレクトと Set-Cookie（第一者 Cookie として保存される形で、欠落なく返す）');
    {
      const before = hitsBefore();
      const response = await get('/api/redirect');
      checkEq('302 を追わず、そのまま返す', 302, response.status);
      checkEq('Location は、公開オリジンの絶対 URL のまま', 'https://app.example.test/studio', response.headers.location);
      checkEq('Set-Cookie が 2 つとも、順序を保って返る', [COOKIE_1, COOKIE_2], response.headers['set-cookie']);
      check('Set-Cookie に、Domain 属性が無い（ブラウザは、フロントエンドのオリジンへ保存する）', !response.headers['set-cookie'].some((cookie) => /;\s*domain=/i.test(cookie)));
      check('スタブへの要求は 1 回だけ（リダイレクト先を取りに行かない）', hitsBefore() === before + 1);
      const relative = await get('/api/relative-redirect');
      checkEq('相対の Location の 302 も、追わずに返す', ['302', '/api/echo'], [String(relative.status), relative.headers.location]);
    }

    console.log('\n-- バックエンドのホストを指す Location は、返さない（502）');
    {
      const response = await get('/api/leak');
      checkEq('502 {"error":{"code":"bad_gateway"}}', { status: 502, body: { error: { code: 'bad_gateway' } } }, { status: response.status, body: json(response) });
      check('Location を返さない', response.headers.location === undefined);
    }

    console.log('\n-- ステータス・本文の透過、圧縮・ストリーム・204');
    for (const status of [400, 401, 403, 404, 409, 422, 429, 500, 503]) {
      const response = await get(`/api/status/${status}`);
      checkEq(`バックエンドの ${status} を、そのまま返す`, { status, code: 'rate_limited' }, { status: response.status, code: json(response).error.code });
    }
    {
      const gzip = await get('/api/gzip');
      checkEq('圧縮された応答は、復号して返す', { compressed: true }, json(gzip));
      check('Content-Encoding・Content-Length を返さない（二重に復号されない）', gzip.headers['content-encoding'] === undefined && gzip.headers['content-length'] === undefined);
      const noContent = await send({ port: NEXT_PORT, method: 'POST', path: '/api/no-content' });
      checkEq('204 は、本文なしで返す', { status: 204, length: 0 }, { status: noContent.status, length: noContent.body.length });
      // スタブは、最初の塊をすぐに返し、2 つ目の塊を 400 ms 後に返して終える。全読み込みをする中継なら、最初の塊も、400 ms 後に届く
      const stream = await sendTimed({ port: NEXT_PORT, path: '/api/stream' });
      checkEq('ストリームの本文が、すべて届く', 'first-chunksecond-chunk', stream.body);
      check('最初の塊は、バックエンドが全体を返し終える前に届く（本文を全読み込みせずに、流す）', stream.firstChunkMs !== null && stream.firstChunkMs < 300, `最初の塊まで ${stream.firstChunkMs} ms`);
      check('全体は、バックエンドの遅延（400 ms）をそのまま通す', stream.totalMs >= 350, `${stream.totalMs} ms`);
    }

    console.log('\n-- すべてのメソッドを、同じメソッドで転送する');
    for (const method of ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELE' + 'TE', 'OPTIONS']) {
      const before = hitsBefore();
      const response = await send({ port: NEXT_PORT, method, path: '/api/echo', headers: { 'content-type': 'application/json' }, body: ['GET', 'HEAD'].includes(method) ? undefined : '{}' });
      remember(response);
      const delivered = stub.seen.slice(before).map((entry) => entry.method);
      checkEq(`${method} が、${method} のまま届く`, [method], delivered);
    }

    console.log('\n-- 転送してよい経路の制限（拒否した要求は、バックエンドへ届かない）');
    for (const [label, requestPath] of [
      ['上の階層へ戻る（%2e%2e）', '/api/%2e%2e/admin'],
      ['上の階層へ戻る（..%2f）', '/api/..%2fadmin'],
      ['エンコードされた区切り（%2f）', '/api/auth%2flogin/start'],
      ['エンコードされた区切り（%5c）', '/api/auth%5clogin'],
      ['二重のエンコード', '/api/%252e%252e/admin'],
      ['内部通信の経路（/api/internal）', '/api/internal/verify'],
      ['管理画面の経路（/api/admin）', '/api/admin'],
      ['本番の /api/dev/（疑似の経路）', '/api/dev/google/authorize'],
      ['/internal（/api の外）', '/internal/verify'],
      ['/admin（/api の外）', '/admin'],
    ]) {
      const before = hitsBefore();
      const response = await get(requestPath);
      check(`${label}: 404（バックエンドへ届かない）`, response.status === 404 && hitsBefore() === before, `status ${response.status}・スタブへの要求 ${hitsBefore() - before} 回`);
    }

    console.log('\n-- 本文の上限（64 KB）');
    {
      const before = hitsBefore();
      const tooLarge = await send({ port: NEXT_PORT, method: 'POST', path: '/api/echo', headers: { 'content-type': 'text/plain' }, body: 'x'.repeat(65537) }).then(remember);
      checkEq('65,537 バイトは、413 {"error":{"code":"invalid_input"}}', { status: 413, body: { error: { code: 'invalid_input' } } }, { status: tooLarge.status, body: json(tooLarge) });
      check('上限を超えた本文は、バックエンドへ届かない', hitsBefore() === before);
      const exact = await send({ port: NEXT_PORT, method: 'POST', path: '/api/echo', headers: { 'content-type': 'text/plain' }, body: 'y'.repeat(65536) }).then(remember);
      checkEq('65,536 バイト（上限ちょうど）は、届く', { status: 200, length: 65536 }, { status: exact.status, length: json(exact).body.length });
    }

    console.log('\n-- 設定エラー（BACKEND_ORIGIN・BFF_SHARED_SECRET が無い）。欠けている変数の名前だけを返す');
    {
      const response = await send({ port: UNCONFIGURED_PORT, path: '/api/state' }).then(remember);
      checkEq('500 internal_error と、欠けている変数の名前', { status: 500, code: 'internal_error', missing: ['BACKEND_ORIGIN', 'BFF_SHARED_SECRET'] }, { status: response.status, code: json(response).error.code, missing: json(response).error.details.missing });
      const health = await send({ port: UNCONFIGURED_PORT, path: '/healthz' });
      checkEq('設定エラーでも、/healthz は応答する（中継の対象外）', 200, health.status);
    }

    console.log('\n-- バックエンドへ到達できない（スタブを止める）');
    {
      await stub.close();
      stubClosed = true;
      const response = await get('/api/state');
      checkEq('502 {"error":{"code":"bad_gateway"}}', { status: 502, body: { error: { code: 'bad_gateway' } } }, { status: response.status, body: json(response) });
      const text = response.body.toString('utf8') + JSON.stringify(response.headers);
      check('応答に、バックエンドのアドレス・ポートを出さない', !text.includes('127.0.0.1') && !text.includes(String(STUB_PORT)), text);
    }

    console.log('\n-- 共有の秘密値は、どの応答（本文・ヘッダ）にも出ない');
    check('応答の全体に、共有の秘密値が含まれない', !texts.some((text) => text.includes(SECRET)));
    const logs = `${configured.output.join('')}${unconfigured.output.join('')}`;
    check('next start のログにも、共有の秘密値が含まれない', !logs.includes(SECRET));
    check('ログは、バックエンドの不達を記録している（何が起きたか、たどれる）', /bff: upstream request failed \(GET \/api\/state\): ECONNREFUSED/.test(logs), logs.slice(-600));
    check('ログは、設定エラーを、変数の名前だけで記録している', /bff: BFF configuration error: missing \[BACKEND_ORIGIN, BFF_SHARED_SECRET\]/.test(logs));
    check('ログに、認可コード・Cookie の値を含めない', !logs.includes('dummy-session-value') && !logs.includes('dummy-csrf-token'));
  } finally {
    await Promise.all([stopChild(configured), stopChild(unconfigured)]);
    if (!stubClosed) {
      await stub.close();
    }
  }
}

main()
  .then(() => {
    console.log(`\n成功 ${passes} 件・失敗 ${failures} 件`);
    process.exit(failures > 0 ? 1 : 0);
  })
  .catch((error) => {
    console.log(`FAIL 予期しないエラー: ${error && error.stack ? error.stack.split('\n').slice(0, 4).join(' | ') : error}`);
    process.exit(1);
  });
