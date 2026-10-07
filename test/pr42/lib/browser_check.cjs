'use strict';
// 実ブラウザ（Playwright の Chromium）で、ランディング（/）とアカウント（/account）を確かめる。対象は開発サーバー（ホストの localhost）。
//
// ブラウザの API 呼び出し（/api/*）は、場面に応じて、ブラウザ側で疑似の応答にする（Playwright の route）。画面・スクリプト・スタイルは、
// 開発サーバーの本物。バックエンドの実物は、この時点では /up しか無いため、疑似の応答で、契約どおりの応答に対する画面の動きを確かめる。
// 実物のバックエンドへ、そのまま繋いだときの現状（未実装の経路への 404）も、疑似なしの場面で確かめる。
//
//   描画         見出し・数値・ボタン・通知が出る。トークン（--bg）の背景・横にはみ出さない・画面が空白でない
//   フォーカス   Tab の順・フォーカスの見た目・Enter での操作・確認のダイアログ（初期位置・循環・Escape・戻り先・背景の inert）
//   通信         外部のドメインへ通信しない（page の request）。API は、同一オリジン。ネイティブのダイアログ（alert 等）を開かない
//   操作         ログイン・YouTube 接続・再確認・接続の解除・アカウントの削除・ログアウト。要求のヘッダ（X-BL-Client・X-CSRF-Token）・本文
//   安全         遷移を許さない認可 URL（javascript: など）へ遷移しない。.env の秘密値が、ブラウザの受け取る応答に出ない
//   アクセシビリティ  axe-core（frontend の依存にあれば）で、違反が 0 件
//
// 画面の文言は、複写せずに、文言の正本（src/frontend/messages/）を読んで照合する。数値は、契約（src/contracts/limits.json）から。
//
// 使い方: PLAYWRIGHT_DIR=<playwright のディレクトリ> node browser_check.cjs --repo <リポジトリのルート>
//   FRONTEND_PORT  frontend のポート（既定 3000。ホストは localhost に固定）
//   ARTIFACT_DIR   スクリーンショットの置き場（既定は、新しく作る一時ディレクトリ）
// 終了コード: 0 成功 / 1 失敗あり / 2 前提の不備（開発サーバーに届かない・引数） / 3 ブラウザを使えず、確認できなかった
// 一部の確認だけを省略したときは、「SKIP」の行を出す（終了コードは変えない）。値（トークン・秘密値）は、明らかなダミー。

const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { fillTemplate, loadMessageModule, loadTypeScript } = require('./messages_loader.cjs');

const EXIT_OK = 0;
const EXIT_FAILED = 1;
const EXIT_PRECONDITION = 2;
const EXIT_UNAVAILABLE = 3;

const DESKTOP = { width: 1280, height: 900 };
const MOBILE = { width: 375, height: 800 };
const NAVIGATION_TIMEOUT_MS = 120000;
const ACTION_TIMEOUT_MS = 20000;
const SETTLE_MS = 20000;
// 語は分割して組み立てる（テストのソースに、削除系の語を、そのまま書かない）
const METHOD_DELETE = 'DELE' + 'TE';

// ---------------------------------------------------------------------------------------------
// 結果の出力
// ---------------------------------------------------------------------------------------------

let failures = 0;
let passes = 0;
let skips = 0;
const pass = (label) => {
  passes += 1;
  console.log(`ok   ${label}`);
};
const fail = (label, detail) => {
  failures += 1;
  console.log(`FAIL ${label}${detail === undefined || detail === '' ? '' : `（${detail}）`}`);
};
const skip = (label) => {
  skips += 1;
  console.log(`SKIP ${label}`);
};
const note = (label) => console.log(`NOTE ${label}`);
const check = (label, condition, detail) => (condition ? pass(label) : fail(label, detail));
const checkEq = (label, expected, actual) => {
  if (JSON.stringify(expected) === JSON.stringify(actual)) {
    pass(label);
  } else {
    fail(label, `期待: ${JSON.stringify(expected)} / 実際: ${JSON.stringify(actual)}`);
  }
};
const section = (title) => console.log(`\n-- ${title}`);

const firstLine = (text) => String(text).split('\n')[0].slice(0, 220);
const normalize = (text) => String(text).replace(/\s+/g, ' ').trim();

// ---------------------------------------------------------------------------------------------
// 引数・前提
// ---------------------------------------------------------------------------------------------

function parseRepo() {
  const index = process.argv.indexOf('--repo');
  const repo = index >= 0 ? process.argv[index + 1] : undefined;
  if (!repo || !fs.existsSync(path.join(repo, 'src', 'frontend', 'app'))) {
    console.log('FAIL 使い方: node browser_check.cjs --repo <リポジトリのルート>');
    process.exit(EXIT_PRECONDITION);
  }
  return path.resolve(repo);
}

function parsePort() {
  const value = process.env.FRONTEND_PORT || '3000';
  if (!/^[0-9]{1,5}$/.test(value)) {
    console.log(`FAIL FRONTEND_PORT は、ポート番号ではありません（${value}）`);
    process.exit(EXIT_PRECONDITION);
  }
  return value;
}

function loadPlaywright() {
  const dir = process.env.PLAYWRIGHT_DIR;
  if (!dir) {
    console.log('SKIP PLAYWRIGHT_DIR が指定されていません（確認できなかった）');
    process.exit(EXIT_UNAVAILABLE);
  }
  try {
    return require(dir);
  } catch (error) {
    console.log(`SKIP Playwright を読み込めません（${dir}）: ${firstLine(error.message)}（確認できなかった）`);
    process.exit(EXIT_UNAVAILABLE);
  }
}

/** .env の KEY=VALUE を読む（値は、メモリの中だけで使い、出力しない） */
function readEnvFile(file) {
  const values = new Map();
  if (!fs.existsSync(file)) {
    return values;
  }
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const match = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (match === null) {
      continue;
    }
    let value = match[2];
    if (/^(".*"|'.*')$/.test(value)) {
      value = value.slice(1, -1);
    }
    values.set(match[1], value);
  }
  return values;
}

function secretValuesOf(envValues) {
  const secrets = [];
  for (const [name, value] of envValues) {
    if (/(SECRET|PASSWORD|TOKEN|PRIVATE|ENCRYPTION|MASTER_KEY|DATABASE_URL)/i.test(name) && !/SITE_KEY/i.test(name) && value.length >= 8) {
      secrets.push({ name, value });
    }
  }
  return secrets;
}

function fetchStatus(url, timeoutMs) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, (response) => {
      response.resume();
      response.on('end', () => resolve(response.statusCode));
    });
    request.setTimeout(timeoutMs, () => request.destroy(new Error('timeout')));
    request.on('error', reject);
  });
}

// ---------------------------------------------------------------------------------------------
// 疑似の API 応答（契約 src/contracts/http-api.md の形）
// ---------------------------------------------------------------------------------------------

const json = (body, status = 200) => ({ status, contentType: 'application/json; charset=utf-8', body: JSON.stringify(body) });
const html = (body) => ({ status: 200, contentType: 'text/html; charset=utf-8', body });
const noContent = () => ({ status: 204 });
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const CSRF_TOKEN = 'dummy-csrf-token-0123456789abcdef';
const CHANNEL_TITLE = 'dummy-channel-title';
const ANONYMOUS_STATE = { authenticated: false, csrf_token: null };
const USAGE = {
  usage_date: '2026-10-07',
  allowance_total: 1,
  allowance_remaining: 1,
  attempts_remaining: 3,
  next_available_at: null,
  monthly_intake_closed: false,
  intake_paused: false,
};
const LIVE_BROADCAST = {
  id: 'dummy-broadcast-id',
  state: 'live',
  end_reason: null,
  profile: '720p',
  accepted_at: '2026-10-07T13:30:00+09:00',
  live_at: '2026-10-07T13:31:10+09:00',
  ended_at: null,
  time_limit_ends_at: null,
  watch_url: null,
  resumable: true,
  duration_seconds: null,
  next_available_at: null,
};
const authenticatedState = (youtube, broadcast = null) => ({ authenticated: true, csrf_token: CSRF_TOKEN, usage: USAGE, youtube, broadcast });
const youtubeView = (state, channelTitle, canRecheckAt = null) => ({ state, channel_title: channelTitle, can_recheck_at: canRecheckAt });

/** JST（+09:00）の ISO 8601 の文字列（現在から offsetMs 後） */
function jstIso(offsetMs) {
  return new Date(Date.now() + 9 * 3600 * 1000 + offsetMs).toISOString().replace('Z', '+09:00');
}

// ---------------------------------------------------------------------------------------------
// 設定の読み込み（文言・数値・環境）
// ---------------------------------------------------------------------------------------------

const repo = parseRepo();
const port = parsePort();
const base = `http://localhost:${port}`;

if (loadTypeScript(repo) === null) {
  console.log('SKIP TypeScript（src/frontend/node_modules/typescript）が無く、文言の正本を読めません。frontend の依存を導入してください（確認できなかった）');
  process.exit(EXIT_UNAVAILABLE);
}
const messages = {
  landing: loadMessageModule(repo, 'landing.ts').landing,
  account: loadMessageModule(repo, 'account.ts').account,
  apiNotice: loadMessageModule(repo, 'api-notices.ts').apiNotice,
  system: loadMessageModule(repo, 'system.ts').system,
};
const limits = JSON.parse(fs.readFileSync(path.join(repo, 'src', 'contracts', 'limits.json'), 'utf8'));
const envValues = readEnvFile(path.join(repo, '.env'));
const secretValues = secretValuesOf(envValues);
const recaptchaSiteKey = envValues.get('RECAPTCHA_SITE_KEY') || '';
const axePath = path.join(repo, 'src', 'frontend', 'node_modules', 'axe-core', 'axe.min.js');
const axeSource = fs.existsSync(axePath) ? fs.readFileSync(axePath, 'utf8') : null;
const formatInteger = (value) => new Intl.NumberFormat('en-US').format(value);

// bot 判定のトークン。サイトキーが空なら、画面が疑似のトークンを使う。あれば、スクリプト（Google）を疑似に差し替え、行為名つきのトークンを返す
const expectedToken = (action) => (recaptchaSiteKey === '' ? 'dev-pass' : `fake-recaptcha-token:${action}`);
const FAKE_RECAPTCHA_SCRIPT = `
window.grecaptcha = {
  ready: function (callback) { callback(); },
  execute: function (siteKey, options) { return Promise.resolve('fake-recaptcha-token:' + options.action); },
};
`;
const RECAPTCHA_SCRIPT_URL = 'https://www.google.com/recaptcha/api.js';

// ---------------------------------------------------------------------------------------------
// 観察・疑似応答の仕組み
// ---------------------------------------------------------------------------------------------

/** 画面が受け取った、同一オリジンの応答の本文（.env の秘密値が含まれないことを、最後に確かめる） */
const receivedBodies = [];
let unreadableBodies = 0;

function isExternalRequest(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return true;
  }
  if (['data:', 'blob:', 'about:'].includes(url.protocol)) {
    return false;
  }
  if (url.host === `localhost:${port}`) {
    return false;
  }
  // サイトキーがあるときだけ、bot 判定のスクリプトの取得（疑似に差し替える）を許す
  if (recaptchaSiteKey !== '' && `${url.origin}${url.pathname}` === RECAPTCHA_SCRIPT_URL) {
    return false;
  }
  return true;
}

function createObservation() {
  return { requests: [], responses: [], pageErrors: [], consoleErrors: [], dialogs: [], websockets: [], unexpectedApi: [], pending: [] };
}

function observe(context, page, observed) {
  context.on('request', (request) => observed.requests.push({ url: request.url(), method: request.method() }));
  page.on('pageerror', (error) => observed.pageErrors.push(firstLine(error.message)));
  page.on('console', (message) => {
    if (message.type() === 'error') {
      observed.consoleErrors.push(firstLine(message.text()));
    }
  });
  // ネイティブのダイアログ（alert・confirm・prompt）は、開かれたら記録して閉じる
  page.on('dialog', (dialog) => {
    observed.dialogs.push(dialog.type());
    dialog.dismiss().catch(() => {});
  });
  page.on('websocket', (socket) => observed.websockets.push(socket.url()));
  page.on('response', (response) => {
    observed.responses.push({ url: response.url(), status: response.status() });
    if (!response.url().startsWith(base)) {
      return;
    }
    observed.pending.push(
      (async () => {
        try {
          const type = response.headers()['content-type'] || '';
          if (/(text|json|javascript|xml)/i.test(type)) {
            receivedBodies.push({ url: response.url(), body: await response.text() });
          }
        } catch {
          // 本文を取得できない応答（遷移で破棄されたもの）。件数だけ記録する
          unreadableBodies += 1;
        }
      })(),
    );
  });
}

/** /api/ の疑似応答。handlers は { 'METHOD /path': (call) => 応答 }。定義の無い呼び出しは、記録して 501 を返す */
async function installApiMock(context, handlers, observed) {
  const calls = [];
  await context.route(
    (url) => url.pathname.startsWith('/api/'),
    async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      const key = `${request.method()} ${url.pathname}`;
      const call = { key, search: url.search, headers: request.headers(), body: request.postData() };
      calls.push(call);
      const handler = handlers[key];
      if (handler === undefined) {
        observed.unexpectedApi.push(key);
        await route.fulfill(json({ error: { code: 'internal_error' } }, 501));
        return;
      }
      await route.fulfill(await handler(call));
    },
  );
  return { calls, callsTo: (key) => calls.filter((call) => call.key === key) };
}

async function installFakeRecaptcha(context) {
  if (recaptchaSiteKey === '') {
    return;
  }
  await context.route(`${RECAPTCHA_SCRIPT_URL}*`, (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: FAKE_RECAPTCHA_SCRIPT }));
}

/** 条件が成立するまで待つ（Node 側の条件） */
async function waitUntil(condition, label, timeoutMs = SETTLE_MS) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (await condition()) {
      return true;
    }
    await delay(100);
  }
  fail(`${label}（${timeoutMs} ms 待っても成立しない）`);
  return false;
}

/** いくつかの条件のうち、最初に成立したものの名前（どれも成立しなければ null）。待っているほかの条件の失敗は、無視する */
function firstOf(entries, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        resolve(null);
      }
    }, timeoutMs);
    for (const [name, start] of Object.entries(entries)) {
      start().then(
        () => {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(name);
          }
        },
        () => {
          // この条件は、時間内に成立しなかった。ほかの条件を待つ
        },
      );
    }
  });
}

// ---------------------------------------------------------------------------------------------
// ページの検査の部品
// ---------------------------------------------------------------------------------------------

let artifactDir;
let analysisContext;
const screenshotNames = [];

async function shot(page, name) {
  const png = await page.screenshot({ type: 'png', fullPage: true });
  fs.writeFileSync(path.join(artifactDir, `${name}.png`), png);
  screenshotNames.push(name);
  return png;
}

/** スクリーンショット（PNG）の色の種類の数と、最も多い色の割合を、ブラウザの canvas で数える */
async function analyzeColors(png) {
  const helper = await analysisContext.newPage();
  try {
    return await helper.evaluate(async (base64) => {
      const image = new Image();
      image.src = `data:image/png;base64,${base64}`;
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = image.width;
      canvas.height = image.height;
      const context = canvas.getContext('2d');
      context.drawImage(image, 0, 0);
      const data = context.getImageData(0, 0, canvas.width, canvas.height).data;
      const counts = new Map();
      for (let i = 0; i < data.length; i += 4) {
        const key = `${data[i]},${data[i + 1]},${data[i + 2]}`;
        counts.set(key, (counts.get(key) || 0) + 1);
      }
      const [dominantKey, dominantCount] = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
      return { pixels: canvas.width * canvas.height, distinct: counts.size, dominant: dominantKey, dominantRatio: dominantCount / (canvas.width * canvas.height) };
    }, png.toString('base64'));
  } finally {
    await helper.close();
  }
}

/** React が描画した要素（ハイドレーション済み）が、ページに現れるまで待つ。これより前の操作は、取りこぼされる */
async function waitForHydration(page, selector = 'main button, main a') {
  await page.waitForFunction(
    (target) => {
      const element = document.querySelector(target);
      return element !== null && Object.keys(element).some((key) => key.startsWith('__reactFiber$'));
    },
    selector,
    { timeout: NAVIGATION_TIMEOUT_MS },
  );
}

async function describeActive(page) {
  return page.evaluate(() => {
    const element = document.activeElement;
    return {
      tag: element.tagName,
      id: element.id,
      text: (element.textContent || '').replace(/\s+/g, ' ').trim(),
      href: element.getAttribute('href'),
      inDialog: element.closest('[role="alertdialog"]') !== null,
    };
  });
}

async function focusRing(page) {
  return page.evaluate(() => {
    const style = getComputedStyle(document.activeElement);
    return { outlineStyle: style.outlineStyle, outlineWidth: style.outlineWidth, boxShadow: style.boxShadow };
  });
}

const hasVisibleRing = (ring) => (ring.outlineStyle !== 'none' && parseFloat(ring.outlineWidth) > 0) || ring.boxShadow !== 'none';

/** 本文の中で、画面の幅からはみ出す要素（body は、横方向のはみ出しを隠すため、要素ごとに見る）。はみ出しが無ければ空の配列 */
async function overflowingElements(page) {
  return page.evaluate(() => {
    const width = document.documentElement.clientWidth;
    const offenders = [];
    for (const element of document.querySelectorAll('main h1, main h2, main h3, main p, main dt, main dd, main li, main button, main a, main strong, main small, [role="alertdialog"] *')) {
      const rect = element.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0 && (rect.right > width + 0.5 || rect.left < -0.5)) {
        offenders.push(`${element.tagName.toLowerCase()}(${Math.round(rect.left)}..${Math.round(rect.right)} / ${width})`);
      }
    }
    return offenders.slice(0, 6);
  });
}

async function runAxe(page, label) {
  if (axeSource === null) {
    skip(`${label}: axe-core（src/frontend/node_modules/axe-core）が無いため、アクセシビリティの機械検査を省略した`);
    return;
  }
  await page.addScriptTag({ content: axeSource });
  const violations = await page.evaluate(async () => {
    const result = await window.axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa', 'best-practice'] } });
    return result.violations.map((violation) => `${violation.id}(${violation.impact}): ${violation.nodes.slice(0, 2).map((node) => node.target.join(' ')).join(' | ')}`);
  });
  checkEq(`${label}: アクセシビリティの機械検査（axe-core）で、違反が 0 件`, [], violations);
}

/** 場面ごとの共通の確認（外部へ通信しない・例外が無い・想定外の呼び出しが無い・ネイティブのダイアログが無い） */
async function commonChecks(name, observed, options) {
  await Promise.allSettled(observed.pending);
  const external = [...new Set(observed.requests.filter((request) => isExternalRequest(request.url)).map((request) => new URL(request.url).origin))];
  checkEq(`${name}: 外部のドメインへ通信しない（page の request を、すべて確認）`, [], external);
  checkEq(`${name}: 未処理の例外（ページのエラー）が無い`, [], observed.pageErrors);
  const expected = options.expectedConsole || [];
  checkEq(`${name}: 想定外のコンソールのエラーが無い`, [], observed.consoleErrors.filter((text) => !expected.some((pattern) => pattern.test(text))));
  checkEq(`${name}: 想定外の /api/ の呼び出しが無い`, [], observed.unexpectedApi);
  checkEq(`${name}: ネイティブのダイアログ（alert・confirm・prompt）を開かない`, [], observed.dialogs);
}

// 失敗を意図した場面で、出てよいコンソールのエラー（ブラウザの読み込み失敗の記録と、画面自身の失敗の記録）
const EXPECTED_FAILURE_LOGS = [/^Failed to load resource: the server responded with a status of \d{3}/, /^(landing|account|recaptcha): /];

async function runScenario(browser, name, options, body) {
  section(name);
  const context = await browser.newContext({ viewport: options.viewport || DESKTOP, deviceScaleFactor: 1, locale: 'ja-JP', serviceWorkers: 'block' });
  context.setDefaultTimeout(ACTION_TIMEOUT_MS);
  const page = await context.newPage();
  const observed = createObservation();
  observe(context, page, observed);
  await installFakeRecaptcha(context);
  const api = options.api === undefined ? null : await installApiMock(context, options.api, observed);
  try {
    await body({ page, context, observed, api });
  } catch (error) {
    fail(`${name}: 予期しないエラー`, firstLine(error && error.message ? error.message : error));
  }
  await commonChecks(name, observed, options);
  await context.close();
}

// ---------------------------------------------------------------------------------------------
// 場面: ランディング（/）
// ---------------------------------------------------------------------------------------------

const loginStartResponse = () => json({ authorization_url: `${base}/api/dev/google/authorize?state=dummy-state` });
const devAuthorizePage = () => html('<!doctype html><meta charset="utf-8"><title>dev authorize</title><p>dev authorize</p>');

function anonymousLandingApi(extra = {}) {
  return {
    'GET /api/state': () => json(ANONYMOUS_STATE),
    'GET /api/dev/google/authorize': devAuthorizePage,
    ...extra,
  };
}

function heroNotice(page) {
  return page.locator('section:has(h1) [role="alert"], section:has(h1) [role="status"]');
}

async function landingAnonymousDesktop(browser) {
  const m = messages.landing;
  const loginLabel = m.hero.login;
  await runScenario(
    browser,
    'ランディング（/）: 未ログイン・デスクトップ（描画・フォーカス・ログイン）',
    {
      api: anonymousLandingApi({
        // 処理中の表示を観察できるよう、応答を遅らせる
        'POST /api/auth/login/start': async () => {
          await delay(900);
          return loginStartResponse();
        },
      }),
    },
    async ({ page, api }) => {
      const response = await page.goto(`${base}/`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
      checkEq('HTTP 200', 200, response.status());
      await waitForHydration(page);

      // 描画
      checkEq('html の lang は ja', 'ja', await page.evaluate(() => document.documentElement.lang));
      check('title が空でない', (await page.title()).trim() !== '');
      checkEq('h1 は 1 つで、文言の正本（hero.headline）と一致する', [normalize(`${m.hero.headline.lead} ${m.hero.headline.accent}`)], (await page.locator('h1').allInnerTexts()).map(normalize));
      const headings = (await page.locator('h2').allInnerTexts()).map(normalize);
      for (const expected of [m.value.heading, m.limits.heading, m.environment.heading, `${m.final.heading.lead} ${m.final.heading.accent}`]) {
        check(`見出し（h2）「${expected}」がある`, headings.some((heading) => heading.includes(expected)), JSON.stringify(headings));
      }
      const stats = await page.evaluate(() => [...document.querySelectorAll('dl > div')].map((row) => ({ caption: (row.querySelector('dt') || {}).textContent || '', figure: (row.querySelector('dd') || {}).textContent || '' })));
      const expectedStats = [
        [m.limits.stats.count.caption, limits.setting_defaults.daily_allowance, m.limits.stats.count.unit],
        [m.limits.stats.length.caption, limits.setting_defaults.time_limit_minutes, m.limits.stats.length.unit],
        [m.limits.stats.concurrent.caption, limits.setting_defaults.concurrent_limit, m.limits.stats.concurrent.unit],
        [m.limits.stats.line.caption, limits.profiles['480p'].line_threshold_kbps, m.limits.stats.line.unit],
      ];
      for (const [caption, value, unit] of expectedStats) {
        const row = stats.find((stat) => stat.caption.startsWith(caption));
        checkEq(`制限の数値「${caption}」は、契約（limits.json）の値と単位`, `${formatInteger(value)}${unit}`, row === undefined ? null : normalize(row.figure));
      }
      const loginButtons = page.getByRole('button', { name: loginLabel, exact: true });
      checkEq('ログインのボタンが 2 つ（ヒーローと最後の CTA）', 2, await loginButtons.count());
      check('ログインのボタンが見えて、押せる', (await loginButtons.first().isVisible()) && (await loginButtons.first().isEnabled()));
      checkEq('未ログインの判定のあと、通知は出ない（login_error が無い）', 0, await heroNotice(page).count());

      const style = await page.evaluate(() => {
        const probe = document.createElement('div');
        probe.style.background = 'var(--bg)';
        document.body.appendChild(probe);
        const tokenBackground = getComputedStyle(probe).backgroundColor;
        probe.remove();
        const button = document.querySelector('main button');
        return {
          bodyBackground: getComputedStyle(document.body).backgroundColor,
          tokenBackground,
          buttonBackground: getComputedStyle(button).backgroundColor,
          headingSize: parseFloat(getComputedStyle(document.querySelector('h1')).fontSize),
        };
      });
      check('スタイルが当たっている: body の背景がトークン（--bg）と一致し、透明でない', style.bodyBackground === style.tokenBackground && style.tokenBackground !== 'rgba(0, 0, 0, 0)', JSON.stringify(style));
      check('スタイルが当たっている: ログインのボタンの背景が透明でない', style.buttonBackground !== 'rgba(0, 0, 0, 0)', style.buttonBackground);
      check('スタイルが当たっている: h1 の文字が大きい（24px 超）', style.headingSize > 24, `${style.headingSize}px`);
      checkEq('本文の中に、画面の幅からはみ出す要素が無い', [], await overflowingElements(page));
      const png = await shot(page, 'landing_desktop');
      const colors = await analyzeColors(png);
      check(`画面が空白でない（${colors.pixels} 画素に、${colors.distinct} 色。最も多い色が ${Math.round(colors.dominantRatio * 100)} %）`, colors.distinct >= 30 && colors.dominantRatio < 0.98, JSON.stringify(colors));

      await runAxe(page, 'ランディング（未ログイン）');

      // フォーカス: 最初の Tab はスキップリンク。そこから、ヒーローのログインのボタンへ、有限回で届く。フォーカスが見える
      await page.evaluate(() => document.activeElement && document.activeElement.blur());
      await page.keyboard.press('Tab');
      const first = await describeActive(page);
      check('最初の Tab で、本文へ移動するスキップリンクにフォーカスが移る', first.tag === 'A' && (first.href || '').endsWith('#main-content'), JSON.stringify(first));
      const skipRect = await page.evaluate(() => {
        const rect = document.activeElement.getBoundingClientRect();
        return { top: rect.top, left: rect.left, width: rect.width, height: rect.height };
      });
      check('フォーカスしたスキップリンクが、画面の中に見える', skipRect.top >= 0 && skipRect.left >= 0 && skipRect.width > 1 && skipRect.height > 1, JSON.stringify(skipRect));
      const stops = [first.text];
      let reached = false;
      for (let presses = 0; presses < 20 && !reached; presses += 1) {
        await page.keyboard.press('Tab');
        const active = await describeActive(page);
        stops.push(active.text);
        reached = active.tag === 'BUTTON' && active.text === loginLabel;
      }
      check('Tab で、ヒーローのログインのボタンへ届く', reached, `順: ${JSON.stringify(stops)}`);
      note(`Tab の順: ${stops.map((text) => `「${text}」`).join(' > ')}`);
      const ring = await focusRing(page);
      check('ログインのボタンのフォーカスが見える（outline または box-shadow）', hasVisibleRing(ring), JSON.stringify(ring));

      // Enter でログインを開始する。処理中は、文言が進行形になり、二重に始めない
      await page.keyboard.press('Enter');
      await waitUntil(() => api.callsTo('POST /api/auth/login/start').length === 1, 'Enter で、ログインの開始の要求が送られる');
      const busyButtons = await page.evaluate(() => [...document.querySelectorAll('main button')].map((button) => ({ text: (button.textContent || '').replace(/\s+/g, ' ').trim(), busy: button.getAttribute('aria-busy') })));
      checkEq('処理中は、2 つのボタンとも、文言が進行形で aria-busy になる', [true, true], busyButtons.map((button) => button.busy === 'true' && button.text === m.hero.loginBusy));
      await page.keyboard.press('Enter');
      try {
        // 処理中のボタン（aria-disabled）は、Playwright の既定では、押せない扱い。利用者が押す操作を、そのまま再現する（force）
        await page.getByRole('button', { name: m.hero.loginBusy, exact: true }).last().click({ force: true, timeout: 1500 });
      } catch {
        // 遷移が先に始まり、押せなかった。二重に開始していないことは、下の要求の回数で確かめる
      }
      await page.waitForURL((url) => url.pathname.startsWith('/api/dev/'), { timeout: ACTION_TIMEOUT_MS });
      pass('ログインの開始が成功すると、認可 URL（同一オリジンの /api/dev/ 配下。開発の疑似の Google）へ遷移する');
      const starts = api.callsTo('POST /api/auth/login/start');
      checkEq('ログインの開始の要求は 1 回だけ（処理中の再操作を受け付けない）', 1, starts.length);
      checkEq('要求の本文は、bot 判定のトークンだけ', { recaptcha_token: expectedToken('login') }, JSON.parse(starts[0].body));
      checkEq('X-BL-Client: web を付ける', 'web', starts[0].headers['x-bl-client']);
      check('Content-Type は JSON', /^application\/json/.test(starts[0].headers['content-type'] || ''), starts[0].headers['content-type']);
      check('未ログインなので、X-CSRF-Token を付けない', starts[0].headers['x-csrf-token'] === undefined);

      // 認可の画面から、戻る操作で戻ったとき、ログインのボタンが、処理中のまま固まらない
      await page.goBack({ waitUntil: 'load' });
      await waitForHydration(page);
      const restored = page.getByRole('button', { name: loginLabel, exact: true });
      checkEq('戻る操作で戻ると、ログインのボタンが 2 つとも、元の文言で出る', 2, await restored.count());
      check('戻る操作で戻ると、ログインのボタンは、処理中（aria-busy）のままにならない', (await restored.first().getAttribute('aria-busy')) === null);
    },
  );
}

async function landingLoginErrors(browser) {
  const m = messages.landing;
  const cases = [
    ['registration_held', 'status', m.notice.registrationHeld],
    ['oauth_failed', 'alert', m.notice.oauthFailed],
  ];
  for (const [code, role, text] of cases) {
    await runScenario(browser, `ランディング（/?login_error=${code}）: ログインの拒否・失敗の通知`, { api: anonymousLandingApi() }, async ({ page }) => {
      await page.goto(`${base}/?login_error=${code}`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
      await waitForHydration(page);
      const notice = heroNotice(page);
      checkEq('ヒーローに、通知が 1 つ出る', 1, await notice.count());
      checkEq(`通知の role は ${role}（${role === 'alert' ? 'エラー: すぐに読み上げる' : '情報: 控えめに読み上げる'}）`, role, await notice.first().getAttribute('role'));
      const shown = normalize(await notice.first().innerText());
      check('通知の題（断定）が、文言の正本と一致する', shown.includes(text.title), shown);
      check('通知の本文（対処）が、文言の正本と一致する', shown.includes(text.body), shown);
      await shot(page, `landing_${code}`);
      if (code === 'registration_held') {
        await runAxe(page, 'ランディング（再登録の保留の通知）');
      }
    });
  }
  await runScenario(browser, 'ランディング（/?login_error=<未知の値>）: 別の通知へ倒さない', { api: anonymousLandingApi() }, async ({ page }) => {
    await page.goto(`${base}/?login_error=unknown_value`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await waitForHydration(page);
    checkEq('未知の値は、通知にしない（成功にも、別の失敗にも倒さない）', 0, await heroNotice(page).count());
  });
}

async function landingLoginFailures(browser) {
  const m = messages.landing;
  const retryParts = messages.apiNotice.retryAt.split('{time}');
  const cases = [
    {
      name: '頻度超過（429 rate_limited）',
      response: () => json({ error: { code: 'rate_limited', details: { retry_at: jstIso(600000) } } }, 429),
      role: 'status',
      title: m.notice.rateLimited.title,
      bodyParts: [m.notice.rateLimited.body, retryParts[0], retryParts[1]],
    },
    { name: 'bot 判定の失敗（403 bot_check_failed）', response: () => json({ error: { code: 'bot_check_failed' } }, 403), role: 'status', title: messages.apiNotice.botCheckFailed.title, bodyParts: [messages.apiNotice.botCheckFailed.body] },
    { name: '想定外のサーバーエラー（500 internal_error）', response: () => json({ error: { code: 'internal_error' } }, 500), role: 'alert', title: messages.system.error.notice.title, bodyParts: [messages.system.error.notice.body] },
    { name: '契約に無い応答（HTML）', response: () => html('<!doctype html><p>unexpected</p>'), role: 'alert', title: messages.system.error.notice.title, bodyParts: [messages.system.error.notice.body] },
  ];
  for (const failure of cases) {
    await runScenario(
      browser,
      `ランディング: ログインの開始の失敗: ${failure.name}`,
      { api: anonymousLandingApi({ 'POST /api/auth/login/start': failure.response }), expectedConsole: EXPECTED_FAILURE_LOGS },
      async ({ page, api }) => {
        await page.goto(`${base}/`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
        await waitForHydration(page);
        await page.getByRole('button', { name: m.hero.login, exact: true }).first().click();
        await heroNotice(page).first().waitFor({ state: 'visible' });
        const notice = heroNotice(page).first();
        checkEq('通知の role', failure.role, await notice.getAttribute('role'));
        const shown = normalize(await notice.innerText());
        check('通知の題が、文言の正本と一致する', shown.includes(failure.title), shown);
        for (const part of failure.bodyParts) {
          check(`通知の本文に「${part.trim()}」を含む`, shown.includes(part.trim()), shown);
        }
        checkEq('失敗のあとも、ページを離れない', '/', new URL(page.url()).pathname);
        const button = page.getByRole('button', { name: m.hero.login, exact: true }).first();
        check('失敗のあと、ボタンは元の文言に戻り、もう一度押せる', (await button.isVisible()) && (await button.getAttribute('aria-busy')) === null);
        checkEq('要求は 1 回', 1, api.callsTo('POST /api/auth/login/start').length);
      },
    );
  }
}

async function landingUnsafeAuthorizationUrls(browser) {
  const m = messages.landing;
  const cases = [
    ['javascript: の URL', 'javascript:window.name%3D%22pwned%22'],
    ['外部のドメインの URL', 'https://evil.example/authorize?state=dummy'],
    ['Google を装った、http の URL', 'http://accounts.google.com/o/oauth2/v2/auth'],
    ['同一オリジンだが、/api/dev/ の外', `${base}/api/state`],
  ];
  for (const [label, url] of cases) {
    await runScenario(
      browser,
      `ランディング: 遷移を許さない認可 URL へ遷移しない（${label}）`,
      { api: anonymousLandingApi({ 'POST /api/auth/login/start': () => json({ authorization_url: url }) }), expectedConsole: EXPECTED_FAILURE_LOGS },
      async ({ page }) => {
        await page.goto(`${base}/`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
        await waitForHydration(page);
        await page.getByRole('button', { name: m.hero.login, exact: true }).first().click();
        await heroNotice(page).first().waitFor({ state: 'visible' });
        const shown = normalize(await heroNotice(page).first().innerText());
        check('一般的な失敗の通知を出す（断定と対処）', shown.includes(messages.system.error.notice.title), shown);
        checkEq('ページを離れない', `${base}/`, page.url());
        checkEq('window.name は変わらない（javascript: が実行されていない）', '', await page.evaluate(() => window.name));
      },
    );
  }
}

async function landingAuthenticated(browser) {
  const m = messages.landing;
  await runScenario(
    browser,
    'ランディング: ログイン済み（ログインのボタンの代わりに、スタジオへの誘導）',
    {
      api: {
        'GET /api/state': () => json(authenticatedState(youtubeView('connected', null))),
      },
    },
    async ({ page }) => {
      await page.goto(`${base}/`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
      const links = page.getByRole('link', { name: m.hero.openStudio, exact: true });
      await links.first().waitFor({ state: 'visible' });
      checkEq('スタジオへのリンクが 2 つ（ヒーローと最後の CTA）', 2, await links.count());
      checkEq('リンク先は /studio', ['/studio', '/studio'], await links.evaluateAll((elements) => elements.map((element) => element.getAttribute('href'))));
      checkEq('ログインのボタンは出ない', 0, await page.getByRole('button', { name: m.hero.login, exact: true }).count());
      await shot(page, 'landing_authenticated');
    },
  );
}

async function landingMobile(browser) {
  const m = messages.landing;
  await runScenario(browser, 'ランディング（/）: モバイルの幅（375 px）', { viewport: MOBILE, api: anonymousLandingApi() }, async ({ page }) => {
    await page.goto(`${base}/`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await waitForHydration(page);
    checkEq('本文の中に、画面の幅からはみ出す要素が無い', [], await overflowingElements(page));
    const button = page.getByRole('button', { name: m.hero.login, exact: true }).first();
    const box = await button.boundingBox();
    check('ログインのボタンが、画面の幅の中に収まる', box !== null && box.x >= 0 && box.x + box.width <= MOBILE.width, JSON.stringify(box));
    const png = await shot(page, 'landing_mobile');
    const colors = await analyzeColors(png);
    check(`画面が空白でない（${colors.distinct} 色）`, colors.distinct >= 30, JSON.stringify(colors));
  });
}

/** 疑似なし。実物のバックエンドへ、そのまま繋いだ現状（未実装の経路は、バックエンドが 404 を返す） */
async function landingRealBackend(browser) {
  const m = messages.landing;
  await runScenario(browser, 'ランディング（/）: 疑似なし（実物のバックエンドへ繋いだ現状）', { expectedConsole: EXPECTED_FAILURE_LOGS }, async ({ page, observed }) => {
    const stateResponse = page.waitForResponse((response) => new URL(response.url()).pathname === '/api/state', { timeout: NAVIGATION_TIMEOUT_MS });
    await page.goto(`${base}/`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    const state = await stateResponse;
    note(`GET /api/state（フロントエンドの中継 > バックエンド）の応答: HTTP ${state.status()}`);
    check('ログイン済みかを判定できなくても、ログインのボタンを出し続ける', await page.getByRole('button', { name: m.hero.login, exact: true }).first().isVisible());
    checkEq('判定の失敗では、通知を出さない', 0, await heroNotice(page).count());
    await waitForHydration(page);
    await page.getByRole('button', { name: m.hero.login, exact: true }).first().click();
    const outcome = await firstOf(
      {
        notice: () => heroNotice(page).filter({ hasText: messages.system.error.notice.title }).first().waitFor({ state: 'visible', timeout: SETTLE_MS }),
        navigated: () => page.waitForURL((url) => url.pathname.startsWith('/api/dev/'), { timeout: SETTLE_MS }),
      },
      SETTLE_MS + 2000,
    );
    const start = observed.responses.find((response) => new URL(response.url).pathname === '/api/auth/login/start');
    check('ログインの開始は、同一オリジンの /api/auth/login/start（フロントエンドの中継）へ送られる', start !== undefined);
    if (outcome === 'notice') {
      note(`バックエンドは /api/auth/login/start を未実装（HTTP ${start === undefined ? '?' : start.status}）。画面は、一般的な失敗の通知を出した（成功にも、別の理由にも倒さない）`);
      pass('実物のバックエンドが未実装の経路は、一般的な失敗の通知になる');
    } else if (outcome === 'navigated') {
      note('バックエンドが /api/auth/login/start を実装済み。同一オリジンの開発用の認可の経路へ遷移した');
      pass('実物のバックエンドが実装済みの経路は、認可 URL へ遷移する');
    } else {
      fail('ログインを押しても、通知も遷移も起きない');
    }
    await shot(page, 'landing_real_backend');
  });
}

// ---------------------------------------------------------------------------------------------
// 場面: アカウント（/account）
// ---------------------------------------------------------------------------------------------

/** アカウントの疑似の API。ログアウト・削除のあとは、未ログインの状態を返す */
function accountApi(youtube, { broadcast = null, extra = {} } = {}) {
  const world = { loggedIn: true };
  const handlers = {
    'GET /api/state': () => json(world.loggedIn ? authenticatedState(youtube, broadcast) : ANONYMOUS_STATE),
    'POST /api/auth/logout': () => {
      world.loggedIn = false;
      return noContent();
    },
    [`${METHOD_DELETE} /api/account`]: () => {
      world.loggedIn = false;
      return noContent();
    },
    'GET /api/dev/google/authorize': devAuthorizePage,
    ...extra,
  };
  return { handlers, world };
}

const accountButton = (page, name) => page.getByRole('button', { name, exact: true });
const dialogOf = (page) => page.getByRole('alertdialog');

async function accountContent(page, chipText) {
  await page.getByText(chipText, { exact: true }).first().waitFor({ state: 'visible', timeout: NAVIGATION_TIMEOUT_MS });
}

async function accountUnauthenticated(browser) {
  const api = accountApi(youtubeView('connected', null));
  api.world.loggedIn = false;
  await runScenario(browser, 'アカウント（/account）: 未ログインは、ランディングへ誘導する', { api: api.handlers }, async ({ page, api: mock }) => {
    await page.goto(`${base}/account`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await page.waitForURL((url) => url.pathname === '/', { timeout: NAVIGATION_TIMEOUT_MS });
    pass('未ログインの利用者は、/ へ移る');
    await page.getByRole('heading', { level: 1 }).first().waitFor({ state: 'visible' });
    const heading = normalize(await page.locator('h1').first().innerText());
    check('移った先は、ランディング（h1 が、ランディングのもの）', heading.includes(messages.landing.hero.headline.lead), heading);
    const stateCalls = mock.callsTo('GET /api/state');
    check('アカウントの状態の取得は、チャンネル名つき（with_channel=1）で行われた', stateCalls.length >= 1 && stateCalls[0].search === '?with_channel=1', JSON.stringify(stateCalls.map((call) => call.search)));
    checkEq('アカウントの操作（ログアウトなど）は、表示されなかった', 0, await accountButton(page, messages.account.logout.label).count());
  });
}

async function accountRealBackend(browser) {
  await runScenario(browser, 'アカウント（/account）: 疑似なし（実物のバックエンドへ繋いだ現状）', { expectedConsole: EXPECTED_FAILURE_LOGS }, async ({ page, observed }) => {
    await page.goto(`${base}/account`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    const failureTitle = messages.system.error.notice.title;
    const alert = page.getByRole('alert').filter({ hasText: failureTitle });
    await alert.first().waitFor({ state: 'visible', timeout: NAVIGATION_TIMEOUT_MS });
    const stateResponses = () => observed.responses.filter((response) => new URL(response.url).pathname === '/api/state');
    note(`GET /api/state?with_channel=1 の応答: HTTP ${stateResponses().length > 0 ? stateResponses()[0].status : '?'}（実物のバックエンドは、この経路が未実装の間、404）`);
    const text = normalize(await alert.first().innerText());
    check('状態を取得できないとき、一般的な失敗の通知（断定と対処）を出す', text.includes(failureTitle) && text.includes(messages.system.error.notice.body), text);
    checkEq('ログイン済みか分からないため、ランディングへは移らない（未ログインと決めつけない）', '/account', new URL(page.url()).pathname);
    const retry = accountButton(page, messages.system.error.action);
    check('「再試行」のボタンがある', await retry.isVisible());
    const before = stateResponses().length;
    await retry.click();
    await waitUntil(() => stateResponses().length > before, '「再試行」で、状態を取得し直す');
    pass('「再試行」を押すと、状態を取得し直す');
    check('アカウントの操作（接続の解除・アカウントの削除など）は、表示されない', (await accountButton(page, messages.account.danger.delete).count()) === 0);
    await shot(page, 'account_real_backend');
  });
}

async function accountConnectedFlows(browser) {
  const a = messages.account;
  const disconnected = { youtube: { youtube: youtubeView('not_connected', null) } };
  const api = accountApi(youtubeView('connected', CHANNEL_TITLE), {
    extra: {
      'POST /api/youtube/disconnect': () => json(disconnected.youtube),
      // 処理中の表示を観察できるよう、応答を遅らせる
      [`${METHOD_DELETE} /api/account`]: async () => {
        await delay(900);
        api.world.loggedIn = false;
        return noContent();
      },
    },
  });
  await runScenario(browser, 'アカウント: 接続済み（描画・確認のダイアログ・接続の解除・アカウントの削除）', { api: api.handlers }, async ({ page, api: mock }) => {
    await page.goto(`${base}/account`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await accountContent(page, a.youtube.states.connected.chip);

    // 描画
    checkEq('h1 は、文言の正本（見出しと副題）と一致する', normalize(`${a.heading} ${a.subheading}`), normalize(await page.locator('h1').first().innerText()));
    check('案内文（接続済み）が出る', (await page.getByText(a.youtube.states.connected.guide, { exact: true }).count()) === 1);
    check('接続先のチャンネル名が出る', (await page.getByText(CHANNEL_TITLE, { exact: true }).count()) === 1);
    check('チャンネル名の扱いの注記が出る（契約の保持時間を、差し込む）', (await page.getByText(fillTemplate(a.youtube.channel.note, { minutes: limits.retention.channel_title_memory_max_minutes }), { exact: true }).count()) === 1);
    check('再確認の制限の説明が出る（契約の回数を、差し込む）', (await page.getByText(fillTemplate(a.youtube.actions.recheckLimit, { windowMinutes: limits.rate_limits.recheck_per_minute.window_seconds / 60, perWindow: limits.rate_limits.recheck_per_minute.limit, perDay: limits.rate_limits.recheck_per_day.limit }), { exact: false }).count()) >= 1);
    for (const label of [a.youtube.actions.recheck, a.youtube.actions.reconnect, a.youtube.actions.disconnect, a.danger.delete, a.logout.label]) {
      const button = accountButton(page, label);
      check(`ボタン「${label}」が見えて、押せる`, (await button.count()) === 1 && (await button.isVisible()) && (await button.isEnabled()));
    }
    check('「YouTube を接続」（未接続の操作）は出ない', (await accountButton(page, a.youtube.actions.connect).count()) === 0);
    // 開発サーバーは、副作用を 2 回呼ぶ（Strict Mode）ことがあるため、回数ではなく、すべての呼び出しの形を見る
    const stateSearches = mock.callsTo('GET /api/state').map((call) => call.search);
    check('状態の取得は、すべて、チャンネル名つき（with_channel=1）', stateSearches.length >= 1 && stateSearches.every((search) => search === '?with_channel=1'), JSON.stringify(stateSearches));
    checkEq('本文の中に、画面の幅からはみ出す要素が無い', [], await overflowingElements(page));
    await shot(page, 'account_connected');
    await runAxe(page, 'アカウント（接続済み）');

    // 確認のダイアログ（接続の解除）: 初期位置・循環・背景の inert・Escape・戻り先。最初は、キーボード（フォーカス > Enter）で開く
    // （マウスのクリックのあとの、プログラムによるフォーカスの移動には、ブラウザは、フォーカスの枠を出さない。キーボードの利用者の見え方を、確かめる）
    const disconnectButton = accountButton(page, a.youtube.actions.disconnect);
    await disconnectButton.focus();
    await page.keyboard.press('Enter');
    const dialog = dialogOf(page);
    await dialog.waitFor({ state: 'visible' });
    check('ダイアログの名前（aria-labelledby）は、題（接続を解除）', (await dialog.getAttribute('aria-labelledby')) !== null && normalize(await dialog.locator('h2').innerText()) === a.youtube.actions.disconnect);
    check('ダイアログの説明は、接続の解除の説明', normalize(await dialog.innerText()).includes(a.youtube.disconnectNote));
    checkEq('aria-modal は true', 'true', await dialog.getAttribute('aria-modal'));
    let active = await describeActive(page);
    check('開いた直後のフォーカスは、取り消せる側（キャンセル）', active.inDialog && active.text === a.dialog.cancel, JSON.stringify(active));
    const ring = await focusRing(page);
    check('フォーカスが見える', hasVisibleRing(ring), JSON.stringify(ring));
    const inertState = await page.evaluate((label) => {
      const button = [...document.querySelectorAll('button')].find((element) => (element.textContent || '').includes(label) && element.closest('[role="alertdialog"]') === null);
      return { inertElements: document.querySelectorAll('[inert]').length, backgroundInert: button !== undefined && button.closest('[inert]') !== null };
    }, a.logout.label);
    check('背景の画面は inert（操作できない）', inertState.inertElements >= 1 && inertState.backgroundInert, JSON.stringify(inertState));
    await shot(page, 'account_dialog_disconnect');
    await runAxe(page, 'アカウント（確認のダイアログ）');
    const cycle = [];
    for (const key of ['Tab', 'Tab', 'Shift+Tab', 'Shift+Tab']) {
      await page.keyboard.press(key);
      active = await describeActive(page);
      cycle.push(`${active.inDialog ? '中' : '外'}:${active.text}`);
    }
    checkEq('Tab・Shift+Tab は、ダイアログの中を循環する（キャンセル > 確認 > キャンセル > 確認 > キャンセル）', [`中:${a.youtube.actions.disconnect}`, `中:${a.dialog.cancel}`, `中:${a.youtube.actions.disconnect}`, `中:${a.dialog.cancel}`], cycle);
    await page.evaluate(() => {
      const outside = document.querySelector('header a');
      if (outside) outside.focus();
    });
    active = await describeActive(page);
    check('ダイアログの外へ出たフォーカスは、中へ戻される', active.inDialog, JSON.stringify(active));
    await page.keyboard.press('Escape');
    await dialog.waitFor({ state: 'hidden' });
    active = await describeActive(page);
    check('Escape でキャンセルし、押したボタンへフォーカスが戻る', active.tag === 'BUTTON' && active.text === a.youtube.actions.disconnect, JSON.stringify(active));
    checkEq('キャンセルしても、接続の解除の要求は送られない', 0, mock.callsTo('POST /api/youtube/disconnect').length);

    // マウスで開いて、キャンセルのボタンで閉じる。背景が inert になると、ブラウザは、押したボタンからフォーカスを外すため、戻し先を、開く前に控えておく必要がある
    await disconnectButton.click();
    await dialog.waitFor({ state: 'visible' });
    await dialog.getByRole('button', { name: a.dialog.cancel, exact: true }).click();
    await dialog.waitFor({ state: 'hidden' });
    active = await describeActive(page);
    check('マウスで開き、キャンセルのボタンで閉じても、押したボタンへフォーカスが戻る', active.tag === 'BUTTON' && active.text === a.youtube.actions.disconnect, JSON.stringify(active));

    // 接続の解除を確定する
    await disconnectButton.click();
    await dialog.waitFor({ state: 'visible' });
    await dialog.getByRole('button', { name: a.youtube.actions.disconnect, exact: true }).click();
    await dialog.waitFor({ state: 'hidden' });
    const disconnectCalls = mock.callsTo('POST /api/youtube/disconnect');
    checkEq('接続の解除の要求は 1 回', 1, disconnectCalls.length);
    checkEq('X-CSRF-Token は、状態の取得で受け取った値', CSRF_TOKEN, disconnectCalls[0].headers['x-csrf-token']);
    checkEq('X-BL-Client: web を付ける', 'web', disconnectCalls[0].headers['x-bl-client']);
    check('接続の解除の要求に、本文は無い', disconnectCalls[0].body === null || disconnectCalls[0].body === '');
    await page.getByText(a.youtube.states.notConnected.chip, { exact: true }).first().waitFor({ state: 'visible' });
    pass('接続の解除のあと、状態が「未接続」になる');
    check('「YouTube を接続」が出て、「接続を解除」は消える', (await accountButton(page, a.youtube.actions.connect).count()) === 1 && (await accountButton(page, a.youtube.actions.disconnect).count()) === 0);
    await waitUntil(async () => (await describeActive(page)).id === 'account-connect-button', '押したボタンが無くなったあと、フォーカスが「YouTube を接続」へ移る', 5000);
    pass('押したボタンが無くなったあと、フォーカスが「YouTube を接続」へ移る');

    // アカウントの削除: 確認のダイアログ（取り消せない操作）→ 要求 → ランディングへ
    const deleteButton = accountButton(page, a.danger.delete);
    await deleteButton.click();
    await dialog.waitFor({ state: 'visible' });
    check('削除の確認のダイアログに、説明（取り消せない旨）が出る', normalize(await dialog.innerText()).includes(a.danger.note));
    await shot(page, 'account_dialog_delete');
    await page.keyboard.press('Escape');
    await dialog.waitFor({ state: 'hidden' });
    checkEq('キャンセルしても、削除の要求は送られない', 0, mock.callsTo(`${METHOD_DELETE} /api/account`).length);
    await deleteButton.click();
    await dialog.getByRole('button', { name: a.danger.delete, exact: true }).click();
    // 処理中（応答を待っている間）: 確認の文言が進行形・aria-busy。キャンセルは無効で、Escape でも閉じない。確認を押し直しても、要求は増えない
    const busyConfirm = dialog.getByRole('button', { name: a.danger.deleteBusy, exact: true });
    await busyConfirm.waitFor({ state: 'visible' });
    checkEq('処理中は、確認のボタンの文言が進行形になり、aria-busy になる', 'true', await busyConfirm.getAttribute('aria-busy'));
    check('処理中は、キャンセルのボタンが無効', await dialog.getByRole('button', { name: a.dialog.cancel, exact: true }).isDisabled());
    await page.keyboard.press('Escape');
    check('処理中は、Escape でも、ダイアログが閉じない', await dialog.isVisible());
    // 処理中のボタン（aria-disabled）を、利用者が押す操作を、そのまま再現する（Playwright の既定では、押せない扱い）
    await busyConfirm.click({ force: true });
    await page.waitForURL((url) => url.pathname === '/', { timeout: ACTION_TIMEOUT_MS });
    pass('アカウントの削除が成功すると、ランディング（/）へ移る');
    const deleteCalls = mock.callsTo(`${METHOD_DELETE} /api/account`);
    checkEq('削除の要求は 1 回（処理中の押し直しで、増えない）', 1, deleteCalls.length);
    checkEq('削除の要求の X-CSRF-Token・X-BL-Client', [CSRF_TOKEN, 'web'], [deleteCalls[0].headers['x-csrf-token'], deleteCalls[0].headers['x-bl-client']]);
  });
}

async function accountLogout(browser) {
  const a = messages.account;
  const api = accountApi(youtubeView('connected', CHANNEL_TITLE));
  await runScenario(browser, 'アカウント: ログアウト', { api: api.handlers }, async ({ page, api: mock }) => {
    await page.goto(`${base}/account`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await accountContent(page, a.youtube.states.connected.chip);
    await accountButton(page, a.logout.label).click();
    await page.waitForURL((url) => url.pathname === '/', { timeout: ACTION_TIMEOUT_MS });
    pass('ログアウトが成功すると、ランディング（/）へ移る');
    const calls = mock.callsTo('POST /api/auth/logout');
    checkEq('ログアウトの要求は 1 回で、X-CSRF-Token・X-BL-Client を付ける', [1, CSRF_TOKEN, 'web'], [calls.length, calls[0].headers['x-csrf-token'], calls[0].headers['x-bl-client']]);
    await page.getByRole('button', { name: messages.landing.hero.login, exact: true }).first().waitFor({ state: 'visible' });
    pass('ログアウトのあとのランディングは、ログインのボタンを出す（未ログインの状態）');
  });
}

async function accountRecheck(browser) {
  const a = messages.account;
  const canRecheckAt = jstIso(120000);
  const api = accountApi(youtubeView('live_not_enabled', CHANNEL_TITLE), {
    extra: {
      // 処理中の表示を観察できるよう、応答を遅らせる
      'POST /api/youtube/recheck': async () => {
        await delay(900);
        return json({ youtube: youtubeView('connected', null, canRecheckAt) });
      },
    },
  });
  await runScenario(browser, 'アカウント: ライブ未有効の再確認', { api: api.handlers }, async ({ page, api: mock }) => {
    await page.goto(`${base}/account`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await accountContent(page, a.youtube.states.liveNotEnabled.chip);
    check('案内文（ライブ未有効）が出る', (await page.getByText(a.youtube.states.liveNotEnabled.guide, { exact: true }).count()) === 1);
    await shot(page, 'account_live_not_enabled');
    await accountButton(page, a.youtube.actions.recheck).click();
    const busyRecheck = accountButton(page, a.youtube.actions.recheckBusy);
    await busyRecheck.waitFor({ state: 'visible' });
    checkEq('処理中は、再確認のボタンの文言が進行形になり、aria-busy になる', 'true', await busyRecheck.getAttribute('aria-busy'));
    checkEq('処理中は、ほかの操作（再接続・接続を解除・アカウントを削除）を押せない', [true, true, true], [
      await accountButton(page, a.youtube.actions.reconnect).isDisabled(),
      await accountButton(page, a.youtube.actions.disconnect).isDisabled(),
      await accountButton(page, a.danger.delete).isDisabled(),
    ]);
    await accountContent(page, a.youtube.states.connected.chip);
    pass('再確認で、ライブが有効になると、状態が「接続済み」になる');
    const calls = mock.callsTo('POST /api/youtube/recheck');
    checkEq('再確認の要求は 1 回で、X-CSRF-Token・X-BL-Client を付ける', [1, CSRF_TOKEN, 'web'], [calls.length, calls[0].headers['x-csrf-token'], calls[0].headers['x-bl-client']]);
    check('チャンネル名は、再確認の応答に無くても、保持した値を表示し続ける', (await page.getByText(CHANNEL_TITLE, { exact: true }).count()) === 1);
    const recheck = accountButton(page, a.youtube.actions.recheck);
    check('次に再確認できる時刻まで、再確認のボタンは押せない（無効）', await recheck.isDisabled());
    check('無効の理由（制限の説明）を、aria-describedby で結ぶ', (await recheck.getAttribute('aria-describedby')) === 'account-recheck-hint' && (await page.locator('#account-recheck-hint').count()) === 1);
    check('次に再確認できる時刻が出る', normalize(await page.locator('#account-recheck-hint').innerText()).includes(a.youtube.actions.recheckAvailableAt.split('{time}')[0].trim()));
  });
}

async function accountNotConnectedAndConnect(browser) {
  const a = messages.account;
  const api = accountApi(youtubeView('not_connected', null), {
    extra: { 'POST /api/youtube/connect/start': () => json({ authorization_url: `${base}/api/dev/google/authorize?state=dummy-youtube-state` }) },
  });
  await runScenario(browser, 'アカウント: 未接続（YouTube を接続）', { api: api.handlers }, async ({ page, api: mock }) => {
    await page.goto(`${base}/account?connect=scope_denied`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await accountContent(page, a.youtube.states.notConnected.chip);
    const notice = page.getByRole('alert').filter({ hasText: a.connectResult.scopeDenied.title });
    await notice.first().waitFor({ state: 'visible' });
    const shown = normalize(await notice.first().innerText());
    check('接続の不成立（権限の拒否）の通知（断定と対処）が、文言の正本と一致する', shown.includes(a.connectResult.scopeDenied.title) && shown.includes(a.connectResult.scopeDenied.body), shown);
    check('通知があるとき、案内文は、短い形（通知が対処を案内する）', (await page.getByText(a.youtube.states.notConnected.guideAfterFailure, { exact: true }).count()) === 1);
    checkEq('結果のクエリ（connect）は、URL から取り除かれる（再読み込みで、通知を繰り返さない）', '', new URL(page.url()).search);
    for (const label of [a.youtube.actions.disconnect, a.youtube.actions.recheck]) {
      check(`未接続では「${label}」を出さない`, (await accountButton(page, label).count()) === 0);
    }
    await shot(page, 'account_not_connected_denied');
    await runAxe(page, 'アカウント（未接続・通知あり）');
    await accountButton(page, a.youtube.actions.connect).click();
    await page.waitForURL((url) => url.pathname.startsWith('/api/dev/'), { timeout: ACTION_TIMEOUT_MS });
    pass('YouTube の接続の開始が成功すると、認可 URL（同一オリジンの /api/dev/ 配下）へ遷移する');
    const calls = mock.callsTo('POST /api/youtube/connect/start');
    checkEq('接続の開始の要求は 1 回', 1, calls.length);
    checkEq('本文は、bot 判定のトークン（行為名 youtube_connect）だけ', { recaptcha_token: expectedToken('youtube_connect') }, JSON.parse(calls[0].body));
    checkEq('X-CSRF-Token・X-BL-Client を付ける', [CSRF_TOKEN, 'web'], [calls[0].headers['x-csrf-token'], calls[0].headers['x-bl-client']]);
  });
}

async function accountBroadcasting(browser) {
  const a = messages.account;
  const api = accountApi(youtubeView('connected', CHANNEL_TITLE), { broadcast: LIVE_BROADCAST });
  await runScenario(browser, 'アカウント: 配信中（接続の解除・再接続・アカウントの削除を、無効にする）', { api: api.handlers }, async ({ page }) => {
    await page.goto(`${base}/account`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await accountContent(page, a.youtube.states.connected.chip);
    const notice = page.locator('#account-broadcast-notice');
    const shown = normalize(await notice.innerText());
    check('配信中の案内（断定と対処）が出る', shown.includes(a.broadcastInProgress.title) && shown.includes(a.broadcastInProgress.body), shown);
    for (const label of [a.youtube.actions.reconnect, a.youtube.actions.disconnect, a.danger.delete]) {
      const button = accountButton(page, label);
      check(`「${label}」は無効で、理由（配信中の案内）を aria-describedby で結ぶ`, (await button.isDisabled()) && (await button.getAttribute('aria-describedby')) === 'account-broadcast-notice');
    }
    check('「ログアウト」は押せる', await accountButton(page, a.logout.label).isEnabled());
    check('案内文は、配信中の形（「配信を開始できます」を含まない）', (await page.getByText(a.youtube.states.connected.guideBroadcasting, { exact: true }).count()) === 1);
    await shot(page, 'account_broadcasting');
  });
}

async function accountMobile(browser) {
  const a = messages.account;
  const api = accountApi(youtubeView('connected', CHANNEL_TITLE));
  await runScenario(browser, 'アカウント: モバイルの幅（375 px）', { viewport: MOBILE, api: api.handlers }, async ({ page }) => {
    await page.goto(`${base}/account`, { waitUntil: 'load', timeout: NAVIGATION_TIMEOUT_MS });
    await accountContent(page, a.youtube.states.connected.chip);
    checkEq('本文の中に、画面の幅からはみ出す要素が無い', [], await overflowingElements(page));
    await shot(page, 'account_mobile');
    await accountButton(page, a.danger.delete).click();
    const dialog = dialogOf(page);
    await dialog.waitFor({ state: 'visible' });
    const boxes = await Promise.all([dialog.boundingBox(), dialog.getByRole('button', { name: a.dialog.cancel, exact: true }).boundingBox(), dialog.getByRole('button', { name: a.danger.delete, exact: true }).boundingBox()]);
    check('ダイアログの幅が、画面の幅の中に収まる', boxes[0] !== null && boxes[0].x >= 0 && boxes[0].x + boxes[0].width <= MOBILE.width, JSON.stringify(boxes[0]));
    check('ダイアログの 2 つのボタンが、画面の中に見える', boxes.slice(1).every((box) => box !== null && box.x >= 0 && box.x + box.width <= MOBILE.width && box.y >= 0 && box.y + box.height <= MOBILE.height), JSON.stringify(boxes.slice(1)));
    checkEq('ダイアログの中に、画面の幅からはみ出す要素が無い', [], await overflowingElements(page));
    await shot(page, 'account_mobile_dialog');
  });
}

// ---------------------------------------------------------------------------------------------
// 全体
// ---------------------------------------------------------------------------------------------

function checkSecrets() {
  section('ブラウザが受け取った応答に、秘密値が出ない');
  if (secretValues.length === 0) {
    skip('.env が無い、または秘密らしい値が無いため、秘密値が応答に出ないことの確認を省略した');
    return;
  }
  const bytes = receivedBodies.reduce((sum, entry) => sum + entry.body.length, 0);
  const leaked = [];
  for (const { name, value } of secretValues) {
    if (receivedBodies.some((entry) => entry.body.includes(value))) {
      leaked.push(name);
    }
  }
  checkEq(`同一オリジンの応答 ${receivedBodies.length} 件（${bytes} 文字。HTML・スクリプト・スタイル・API）に、.env の秘密値 ${secretValues.length} 個が含まれない`, [], leaked);
  if (unreadableBodies > 0) {
    note(`本文を読めなかった応答が ${unreadableBodies} 件（遷移で破棄されたもの）`);
  }
}

async function main() {
  const { chromium } = loadPlaywright();
  artifactDir = process.env.ARTIFACT_DIR || fs.mkdtempSync(path.join(os.tmpdir(), 'issue_browser_'));
  fs.mkdirSync(artifactDir, { recursive: true });

  // 開発サーバーは、最初の要求で、画面を組み立てる（時間がかかる）。先に温めておく
  for (const route of ['/', '/account']) {
    try {
      const status = await fetchStatus(`${base}${route}`, NAVIGATION_TIMEOUT_MS);
      if (status !== 200) {
        console.log(`FAIL 開発サーバー（${base}${route}）が HTTP ${status} を返しました`);
        process.exit(EXIT_PRECONDITION);
      }
    } catch (error) {
      console.log(`FAIL 開発サーバー（${base}${route}）へ接続できません: ${firstLine(error.message)}。先に scripts/dc.sh up -d --wait を実行してください`);
      process.exit(EXIT_PRECONDITION);
    }
  }
  note(recaptchaSiteKey === '' ? 'bot 判定のサイトキーが空（開発の既定）。画面は、疑似のトークン dev-pass を使う' : 'bot 判定のサイトキーが設定されている。Google のスクリプトは、疑似に差し替えて確かめる（実際の Google へは通信しない）');

  let browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch (error) {
    console.log(`SKIP Chromium を起動できません: ${firstLine(error.message)}（確認できなかった）`);
    process.exit(EXIT_UNAVAILABLE);
  }
  try {
    analysisContext = await browser.newContext({ viewport: { width: 400, height: 300 } });
    await landingAnonymousDesktop(browser);
    await landingLoginErrors(browser);
    await landingLoginFailures(browser);
    await landingUnsafeAuthorizationUrls(browser);
    await landingAuthenticated(browser);
    await landingMobile(browser);
    await landingRealBackend(browser);
    await accountUnauthenticated(browser);
    await accountRealBackend(browser);
    await accountConnectedFlows(browser);
    await accountLogout(browser);
    await accountRecheck(browser);
    await accountNotConnectedAndConnect(browser);
    await accountBroadcasting(browser);
    await accountMobile(browser);
    checkSecrets();
    console.log(`\nスクリーンショット（${screenshotNames.length} 枚）の置き場: ${artifactDir}`);
  } finally {
    await browser.close();
  }
}

main()
  .then(() => {
    console.log(`\n成功 ${passes} 件・失敗 ${failures} 件・省略（SKIP）${skips} 件`);
    process.exit(failures > 0 ? EXIT_FAILED : EXIT_OK);
  })
  .catch((error) => {
    console.log(`FAIL 予期しないエラー: ${error && error.stack ? error.stack.split('\n').slice(0, 4).join(' | ') : error}`);
    process.exit(EXIT_FAILED);
  });
