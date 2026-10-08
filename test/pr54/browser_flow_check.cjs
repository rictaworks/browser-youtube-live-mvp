'use strict';
// PR 54（issue #11 YouTube 接続）の、実ブラウザ（Playwright の Chromium）での確認。対象は開発サーバー（ホストの localhost。フロントエンドの 3000）。
// ログインは、本番と同じ経路（ランディング -> 「LOG IN WITH GOOGLE」-> 疑似の Google のアカウント選択 -> /studio）で行う。
// YouTube 接続の開始（POST /api/youtube/connect/start）は、アカウント画面の「YouTube を接続」のボタンが呼ぶ API。ただし、アカウント画面は
// 状態の API（GET /api/state。issue #12）が未実装の間、エラーの表示になり、ボタンが出ない。そこで、ボタンの代わりに、ブラウザの中（ページの fetch）から、
// 同じ API を同じ手順（CSRF トークンつきの POST）で呼ぶ。以降（認可 URL を開く -> 疑似の同意画面 -> 選択 -> 戻り先 -> アカウント画面）は、
// ブラウザの実際の遷移（リダイレクトの連鎖）に任せる。CSRF トークンは、GET /api/state が使えればそれ、使えなければ、backend コンテナのアプリケーションの導出で得る。
//
//   流れ 1  成立: 認可 URL を開く -> 同意画面（見出し Google・選択肢 7 つ）-> allow -> 戻り先 302 -> /account?connect=connected。bl_oauth が残らない。外部へ通信しない
//   流れ 2  不成立: deny・allow_without_youtube・allow_without_refresh_token・allow_no_channel・allow_unverifiable は、それぞれ connect=scope_denied・scope_denied・
//           no_refresh_token・no_channel・unverifiable。allow_live_not_enabled は connect=live_not_enabled（成立）
//   流れ 3  戻る操作での再選択: 一度使った bl_oauth は失効しているので、同意画面へ戻って allow を押し直すと、connect=unverifiable
//   流れ 4  再確認: ページの fetch で POST /api/youtube/recheck -> 200。直後の 2 回目は 429
//   通信    外部のドメインへ通信しない（疑似の Google・疑似の YouTube）。ネイティブのダイアログを開かない。画面（本文・URL・document.cookie）にトークンが出ない
//
// 使い方: PLAYWRIGHT_DIR=<playwright のディレクトリ> node browser_flow_check.cjs --repo <リポジトリのルート>
//   FRONTEND_PORT  frontend のポート（既定 3000。ホストは localhost に固定）
//   ARTIFACT_DIR   スクリーンショットの置き場（既定は、新しく作る一時ディレクトリ）
// 終了コード: 0 成功 / 1 失敗あり / 2 前提の不備 / 3 ブラウザを使えず、確認できなかった

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const EXIT_OK = 0;
const EXIT_FAILED = 1;
const EXIT_PRECONDITION = 2;
const EXIT_UNAVAILABLE = 3;

const NAVIGATION_TIMEOUT_MS = 90000;
const ACTION_TIMEOUT_MS = 30000;
const CHOICES = [
  'allow',
  'allow_live_not_enabled',
  'allow_no_channel',
  'allow_unverifiable',
  'allow_without_youtube',
  'allow_without_refresh_token',
  'deny',
];
// 選択肢 -> アカウント画面へ戻るときの connect の値
const EXPECTED_RESULTS = {
  allow: 'connected',
  allow_live_not_enabled: 'live_not_enabled',
  allow_no_channel: 'no_channel',
  allow_unverifiable: 'unverifiable',
  allow_without_youtube: 'scope_denied',
  allow_without_refresh_token: 'no_refresh_token',
  deny: 'scope_denied',
};

let failures = 0;
let passes = 0;
const pass = (label) => {
  passes += 1;
  console.log(`ok   ${label}`);
};
const fail = (label, detail) => {
  failures += 1;
  console.log(`FAIL ${label}${detail === undefined || detail === '' ? '' : `（${detail}）`}`);
};
const check = (condition, label, detail) => (condition ? pass(label) : fail(label, detail));

function argValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

/** backend コンテナのアプリケーションで、セッションの識別子から CSRF トークンを導出する（GET /api/state が使えないときの代わり） */
function deriveCsrfInContainer(repo, sessionToken) {
  const output = execFileSync(
    path.join(repo, 'scripts/dc.sh'),
    [
      'exec', '-T', '-e', `SESSION_TOKEN=${sessionToken}`, 'backend', 'bin/rails', 'runner',
      'print CsrfToken.new(secret: Rails.application.secret_key_base).derive(ENV.fetch("SESSION_TOKEN"))',
    ],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 120000 },
  );
  return output.trim();
}

async function main() {
  const repo = path.resolve(argValue('--repo') || '.');
  const playwrightDir = process.env.PLAYWRIGHT_DIR;
  if (!playwrightDir || !fs.existsSync(path.join(playwrightDir, 'package.json'))) {
    console.log('SKIP Playwright が見つからず、確認できなかった（PLAYWRIGHT_DIR に playwright のディレクトリを指定する）');
    return EXIT_UNAVAILABLE;
  }
  const port = Number(process.env.FRONTEND_PORT || 3000);
  const origin = `http://localhost:${port}`;
  const artifactDir = process.env.ARTIFACT_DIR || fs.mkdtempSync(path.join(os.tmpdir(), 'issue11_browser.'));
  fs.mkdirSync(artifactDir, { recursive: true });
  const probeIp = `203.0.113.${20 + Math.floor(Math.random() * 200)}`;

  let chromium;
  try {
    ({ chromium } = require(playwrightDir));
  } catch (error) {
    console.log(`SKIP Playwright を読み込めず、確認できなかった（${error.code || error.name}）`);
    return EXIT_UNAVAILABLE;
  }
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch (error) {
    console.log(`SKIP Chromium を起動できず、確認できなかった（${String(error.message).split('\n')[0].slice(0, 120)}）`);
    return EXIT_UNAVAILABLE;
  }

  try {
    const context = await browser.newContext({ locale: 'ja-JP', viewport: { width: 1280, height: 900 } });
    context.setDefaultTimeout(ACTION_TIMEOUT_MS);
    context.setDefaultNavigationTimeout(NAVIGATION_TIMEOUT_MS);
    // 頻度制限の計数を、ほかの利用者・ほかの実行と混ぜない（開発のフロントエンドは、入ってきた X-Forwarded-For の先頭を使う）
    await context.setExtraHTTPHeaders({ 'X-Forwarded-For': probeIp });
    const page = await context.newPage();

    // 観測: 通信の相手・ダイアログ・コールバックの応答
    const hosts = new Set();
    const dialogs = [];
    const callbackResponses = [];
    page.on('request', (request) => hosts.add(new URL(request.url()).host));
    page.on('response', (response) => {
      if (response.url().includes('/api/youtube/connect/callback')) {
        callbackResponses.push({ status: response.status(), location: response.headers().location || null });
      }
    });
    page.on('dialog', async (dialog) => {
      dialogs.push(dialog.type());
      await dialog.dismiss();
    });

    // ----- ログイン（本番と同じ経路） -----
    console.log('-- ログイン: ランディング -> LOG IN WITH GOOGLE -> アカウントの選択 -> /studio');
    await page.goto(`${origin}/`, { waitUntil: 'domcontentloaded' });
    const loginButton = page.getByRole('button', { name: /LOG IN WITH GOOGLE/ }).first();
    await loginButton.waitFor({ state: 'visible' });
    await loginButton.click();
    await page.waitForURL(/\/api\/dev\/google\/authorize/);
    await page.getByRole('link', { name: 'dev-user-3' }).click();
    await page.waitForURL(`${origin}/studio`);
    check(new URL(page.url()).pathname === '/studio', 'ログインして /studio へ戻る（疑似の Google の dev-user-3）');

    const sessionCookie = (await context.cookies(origin)).find((cookie) => cookie.name === 'bl_session');
    check(sessionCookie !== undefined && sessionCookie.httpOnly === true, 'bl_session が HttpOnly で設定されている（JavaScript から読めない）');
    if (sessionCookie === undefined) {
      return EXIT_FAILED;
    }

    // CSRF トークン: GET /api/state が使えればそれ（issue #12）。使えなければ、コンテナのアプリケーションの導出
    const state = await page.evaluate(async () => {
      const response = await fetch('/api/state', { credentials: 'same-origin' });
      return { status: response.status, body: response.status === 200 ? await response.json() : null };
    });
    let csrf;
    if (state.status === 200 && state.body && typeof state.body.csrf_token === 'string') {
      csrf = state.body.csrf_token;
      console.log('NOTE 状態の API（GET /api/state）が使えるので、その CSRF トークンを使う');
    } else {
      csrf = deriveCsrfInContainer(repo, sessionCookie.value);
      console.log(`NOTE 状態の API（GET /api/state）は ${state.status}（issue #12 で追加される）。CSRF トークンは、コンテナのアプリケーションの導出で得る`);
    }
    check(typeof csrf === 'string' && csrf.length >= 32, 'CSRF トークンを得た（値は表示しない）');

    // ページの中から、アカウント画面のボタンと同じ API を呼ぶ
    const startConnect = () =>
      page.evaluate(
        async ({ token }) => {
          const response = await fetch('/api/youtube/connect/start', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json', 'X-BL-Client': 'web', 'X-CSRF-Token': token },
            body: JSON.stringify({ recaptcha_token: 'dev-pass' }),
          });
          return { status: response.status, body: await response.json() };
        },
        { token: csrf },
      );

    // ----- 流れ 1: 成立 -----
    console.log('-- 流れ 1: 認可 URL を開く -> 疑似の同意画面 -> allow -> 戻り先 -> アカウント画面');
    const started = await startConnect();
    check(started.status === 200 && typeof started.body.authorization_url === 'string', 'connect/start が 200 で認可 URL を返す');
    const authorizationUrl = started.body.authorization_url;
    check(authorizationUrl.startsWith(`${origin}/api/dev/google/connect?`), '認可 URL は、フロントエンドと同じオリジンの疑似の同意画面');
    const query = new URL(authorizationUrl).searchParams;
    check(
      query.get('scope') === 'https://www.googleapis.com/auth/youtube' &&
        query.get('access_type') === 'offline' &&
        query.get('prompt') === 'consent' &&
        !query.has('include_granted_scopes') &&
        !query.has('nonce'),
      '認可 URL: スコープは youtube の 1 種・offline・consent。include_granted_scopes・nonce は無い',
    );
    const cookiesAfterStart = await context.cookies(origin);
    const oauthCookie = cookiesAfterStart.find((cookie) => cookie.name === 'bl_oauth');
    check(
      oauthCookie !== undefined && oauthCookie.httpOnly === true && oauthCookie.sameSite === 'Lax',
      'bl_oauth が HttpOnly・SameSite=Lax で設定される',
    );

    await page.goto(authorizationUrl, { waitUntil: 'domcontentloaded' });
    await page.screenshot({ path: path.join(artifactDir, '1_consent.png') });
    check((await page.locator('h1').innerText()).trim() === 'Google', '同意画面の見出しは Google（疑似）');
    const labels = (await page.locator('a').allInnerTexts()).map((text) => text.trim());
    check(JSON.stringify(labels) === JSON.stringify(CHOICES), '選択肢は 7 つ（allow・allow_live_not_enabled・allow_no_channel・allow_unverifiable・allow_without_youtube・allow_without_refresh_token・deny）', labels.join(','));
    const consentUrl = page.url();

    await page.getByRole('link', { name: 'allow', exact: true }).click();
    await page.waitForURL(/\/account/);
    await page.waitForLoadState('domcontentloaded');
    const connectedCallback = callbackResponses.at(-1);
    check(
      connectedCallback !== undefined && connectedCallback.status === 302 && connectedCallback.location === `${origin}/account?connect=connected`,
      '戻り先（コールバック）が 302 /account?connect=connected（公開オリジンの絶対 URL）',
      JSON.stringify(connectedCallback),
    );
    check(new URL(page.url()).pathname === '/account', 'アカウント画面（/account）へ遷移する');
    await page.screenshot({ path: path.join(artifactDir, '2_account.png') });
    const cookiesAfterConnect = await context.cookies(origin);
    check(!cookiesAfterConnect.some((cookie) => cookie.name === 'bl_oauth'), '戻り先のあと、bl_oauth がブラウザに残らない（失効する）');
    check(cookiesAfterConnect.some((cookie) => cookie.name === 'bl_session'), 'bl_session は残る（ログインは続く）');

    // ----- 流れ 2: 選択肢ごとの結果 -----
    console.log('-- 流れ 2: 選択肢ごとに、アカウント画面へ戻る結果（connect）');
    for (const choice of CHOICES.filter((name) => name !== 'allow')) {
      const flow = await startConnect();
      if (flow.status !== 200) {
        fail(`${choice}: connect/start が 200`, String(flow.status));
        continue;
      }
      const beforeCount = callbackResponses.length;
      await page.goto(flow.body.authorization_url, { waitUntil: 'domcontentloaded' });
      await page.getByRole('link', { name: choice, exact: true }).click();
      await page.waitForURL(/\/account/);
      const callback = callbackResponses.slice(beforeCount).at(-1);
      const expected = EXPECTED_RESULTS[choice];
      check(
        callback !== undefined && callback.status === 302 && callback.location === `${origin}/account?connect=${expected}`,
        `${choice} -> 302 /account?connect=${expected}`,
        JSON.stringify(callback),
      );
    }

    // ----- 流れ 3: 戻る操作での再選択 -----
    console.log('-- 流れ 3: 戻る操作での再選択（一度使った bl_oauth は失効している）');
    await page.goto(authorizationUrl, { waitUntil: 'domcontentloaded' }); // 流れ 1 で使った認可の要求（bl_oauth は、後の開始で置き換わった）
    const beforeReplay = callbackResponses.length;
    await page.getByRole('link', { name: 'allow', exact: true }).click();
    await page.waitForURL(/\/account/);
    const replay = callbackResponses.slice(beforeReplay).at(-1);
    check(
      replay !== undefined && replay.location === `${origin}/account?connect=unverifiable`,
      '古い認可の要求での再選択は、connect=unverifiable（state の再利用を防ぐ）',
      JSON.stringify(replay),
    );
    check(consentUrl === authorizationUrl, '（参考）同意画面の URL は、認可 URL と同じ');

    // ----- 流れ 4: 再確認 -----
    console.log('-- 流れ 4: 再確認（POST /api/youtube/recheck。ページの fetch）');
    const recheck = (token) =>
      page.evaluate(
        async ({ csrfToken }) => {
          const response = await fetch('/api/youtube/recheck', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'X-BL-Client': 'web', 'X-CSRF-Token': csrfToken },
          });
          return { status: response.status, body: await response.json() };
        },
        { csrfToken: token },
      );
    const first = await recheck(csrf);
    check(
      first.status === 200 && first.body.youtube && ['connected', 'live_not_enabled'].includes(first.body.youtube.state) && first.body.youtube.channel_title === null,
      '再確認が 200（state は connected か live_not_enabled・channel_title は null）',
      JSON.stringify(first.body),
    );
    check(/\+09:00$/.test(String(first.body.youtube && first.body.youtube.can_recheck_at)), 'can_recheck_at は JST（+09:00）');
    const second = await recheck(csrf);
    check(second.status === 429 && second.body.error && second.body.error.code === 'rate_limited', '直後の 2 回目は 429 rate_limited');

    // ----- 通信・ダイアログ・画面の機密 -----
    check([...hosts].every((host) => host === `localhost:${port}`), '外部のドメインへ通信しない', [...hosts].join(','));
    check(dialogs.length === 0, 'ネイティブのダイアログ（alert・confirm・prompt）を開かない');
    const visible = await page.locator('body').innerText();
    const documentCookie = await page.evaluate(() => document.cookie);
    check(
      !/fake-refresh-token|fake-connect-access-token|fake-access-token|Fake Channel/.test(visible) && !documentCookie.includes('bl_session') && !documentCookie.includes('bl_oauth'),
      '画面の本文・document.cookie に、トークン・チャンネル名・セッションの識別子が出ない',
    );
  } finally {
    await browser.close();
  }

  console.log(`\nスクリーンショットの置き場: ${artifactDir}`);
  console.log(`確認 ${passes + failures} 項目、失敗 ${failures} 項目`);
  return failures === 0 ? EXIT_OK : EXIT_FAILED;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.log(`FAIL 予期しない例外: ${error && error.message ? String(error.message).split('\n')[0] : error}`);
    process.exit(EXIT_FAILED);
  },
);
