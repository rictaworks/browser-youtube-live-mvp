'use strict';
// 実ブラウザ（Playwright の Chromium）で、ログインの全体の流れを確かめる。対象は開発サーバー（ホストの localhost。フロントエンドの 3000）。
// 利用者の操作は、本番と同じ経路: ランディング → 「LOG IN WITH GOOGLE」→ 疑似の Google のアカウント選択 → コールバック → /studio。
// フロントエンドの同一オリジン中継（BFF）が /api/auth/* と /api/dev/* を転送する。開発者向けの近道（ログイン済みの状態を直接作る経路）は使わない。
//
//   流れ 1  ログインの成功: ボタン → アカウント選択の画面（固定の 3 アカウント）→ dev-user-1 → /studio。bl_session が設定され（HttpOnly・SameSite=Lax・
//           ブラウザのセッション Cookie）、bl_oauth は残らない。リダイレクトは、公開オリジン（http://localhost:3000）。bot 判定のトークンは dev-pass
//   流れ 2  戻る操作での再選択: 一度使った認可の途中の状態（bl_oauth）は失効しているため、もう一度アカウントを選ぶと、ランディング（/?login_error=oauth_failed）
//           へ戻り、ログインの失敗の通知が出る（state の再利用を防ぐ）
//   流れ 3  Cookie が無い状態でのコールバック: 同じ通知
//   通信    外部のドメインへ通信しない（疑似の Google）。ネイティブのダイアログを開かない
//
// 使い方: PLAYWRIGHT_DIR=<playwright のディレクトリ> node browser_flow_check.cjs --repo <リポジトリのルート>
//   FRONTEND_PORT  frontend のポート（既定 3000。ホストは localhost に固定）
//   ARTIFACT_DIR   スクリーンショットの置き場（既定は、新しく作る一時ディレクトリ）
// 終了コード: 0 成功 / 1 失敗あり / 2 前提の不備 / 3 ブラウザを使えず、確認できなかった

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const EXIT_OK = 0;
const EXIT_FAILED = 1;
const EXIT_PRECONDITION = 2;
const EXIT_UNAVAILABLE = 3;

const NAVIGATION_TIMEOUT_MS = 90000;
const ACTION_TIMEOUT_MS = 30000;
const ACCOUNTS = ['dev-user-1', 'dev-user-2', 'dev-user-3'];

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

/** 文言の正本（フロントエンドの文言カタログ）から、ログインの失敗の通知の見出しを読む（複写しない） */
function readOauthFailedTitle(repo) {
  const text = fs.readFileSync(path.join(repo, 'src/frontend/messages/landing.ts'), 'utf8');
  const match = /oauthFailed:\s*\{\s*title:\s*"([^"]+)"/.exec(text);
  return match ? match[1] : null;
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
  const artifactDir = process.env.ARTIFACT_DIR || fs.mkdtempSync(path.join(os.tmpdir(), 'issue8_browser.'));
  fs.mkdirSync(artifactDir, { recursive: true });
  const failedTitle = readOauthFailedTitle(repo);
  if (failedTitle === null) {
    console.log('FAIL 文言カタログから、ログインの失敗の通知の見出しを読めません');
    return EXIT_PRECONDITION;
  }

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
    const page = await context.newPage();

    // 観測: 通信の相手・ダイアログ・ログイン開始の本文・コールバックの応答
    const hosts = new Set();
    const dialogs = [];
    const startBodies = [];
    const callbackResponses = [];
    page.on('request', (request) => {
      hosts.add(new URL(request.url()).host);
      if (request.url().endsWith('/api/auth/login/start') && request.method() === 'POST') {
        startBodies.push(request.postData());
      }
    });
    page.on('response', (response) => {
      if (response.url().includes('/api/auth/callback')) {
        callbackResponses.push({ status: response.status(), location: response.headers().location || null });
      }
    });
    page.on('dialog', async (dialog) => {
      dialogs.push(dialog.type());
      await dialog.dismiss();
    });

    // ----- 流れ 1: ログインの成功 -----
    console.log('-- 流れ 1: ランディング → LOG IN WITH GOOGLE → アカウントの選択 → /studio');
    await page.goto(`${origin}/`, { waitUntil: 'domcontentloaded' });
    const loginButton = page.getByRole('button', { name: /LOG IN WITH GOOGLE/ }).first();
    await loginButton.waitFor({ state: 'visible' });
    await page.screenshot({ path: path.join(artifactDir, '1_landing.png') });
    await loginButton.click();
    await page.waitForURL(/\/api\/dev\/google\/authorize\?/);
    const chooserUrl = new URL(page.url());
    check(chooserUrl.origin === origin, 'アカウント選択の画面は、フロントエンドと同じオリジン（同一オリジン中継を通る）', chooserUrl.origin);
    check(
      chooserUrl.searchParams.get('scope') === 'openid' && chooserUrl.searchParams.get('code_challenge_method') === 'S256' &&
        chooserUrl.searchParams.get('response_type') === 'code' && chooserUrl.searchParams.get('redirect_uri') === `${origin}/api/auth/callback`,
      '認可の要求: スコープは openid のみ・response_type=code・PKCE の S256・redirect_uri は公開オリジンの /api/auth/callback',
    );
    const links = await page.locator('a').allTextContents();
    check(JSON.stringify(links.map((text) => text.trim())) === JSON.stringify(ACCOUNTS), '固定の 3 アカウント（dev-user-1〜dev-user-3）のリンクだけがある', links.join(','));
    check((await page.locator('form, script, iframe, img').count()) === 0, '画面は最小の HTML（フォーム・スクリプト・画像・フレームが無い）');
    await page.screenshot({ path: path.join(artifactDir, '2_account_chooser.png') });
    check(startBodies.length === 1 && JSON.parse(startBodies[0]).recaptcha_token === 'dev-pass', 'bot 判定のトークンは、開発・テストの疑似のトークン dev-pass（サイトキーが空のとき）');

    const cookiesBefore = await context.cookies();
    const oauthCookie = cookiesBefore.find((cookie) => cookie.name === 'bl_oauth');
    check(
      oauthCookie !== undefined && oauthCookie.httpOnly === true && oauthCookie.sameSite === 'Lax' && oauthCookie.path === '/',
      'bl_oauth（認可の途中の状態）が、HttpOnly・SameSite=Lax・Path=/ で設定されている',
      JSON.stringify(oauthCookie),
    );

    await page.getByRole('link', { name: 'dev-user-1' }).click();
    await page.waitForURL(`${origin}/studio`);
    await page.screenshot({ path: path.join(artifactDir, '3_after_login_studio.png') });
    check(page.url() === `${origin}/studio`, 'アカウントを選ぶと /studio へ移る（リダイレクト先は公開オリジン。バックエンドのホストではない）', page.url());
    check(
      callbackResponses.length > 0 && callbackResponses[0].status === 302 && callbackResponses[0].location === `${origin}/studio`,
      'コールバックの応答は 302 で、Location は http://localhost:3000/studio',
      JSON.stringify(callbackResponses[0]),
    );
    const cookiesAfter = await context.cookies();
    const sessionCookie = cookiesAfter.find((cookie) => cookie.name === 'bl_session');
    check(
      sessionCookie !== undefined && sessionCookie.httpOnly === true && sessionCookie.sameSite === 'Lax' && sessionCookie.path === '/' &&
        sessionCookie.expires === -1 && sessionCookie.secure === false && /^[A-Za-z0-9_-]{43}$/.test(sessionCookie.value),
      'bl_session が設定されている（HttpOnly・SameSite=Lax・ブラウザのセッション Cookie・開発の http なので Secure は付かない）',
      JSON.stringify({ ...sessionCookie, value: sessionCookie ? '[省略]' : undefined }),
    );
    check(cookiesAfter.find((cookie) => cookie.name === 'bl_oauth') === undefined, 'bl_oauth は残らない（成功したら失効する）');
    const visibleToScripts = await page.evaluate(() => document.cookie);
    check(!visibleToScripts.includes('bl_session') && !visibleToScripts.includes('bl_oauth'), 'ページのスクリプト（document.cookie）から、bl_session・bl_oauth は見えない（HttpOnly）');

    // ----- 流れ 2: 戻る操作での再選択 -----
    console.log('-- 流れ 2: 戻る操作でアカウント選択の画面へ戻り、もう一度選ぶ（一度使った認可の途中の状態は失効している）');
    await page.goBack();
    await page.waitForURL(/\/api\/dev\/google\/authorize\?/);
    await page.getByRole('link', { name: 'dev-user-1' }).click();
    await page.waitForURL(/\/\?login_error=oauth_failed/);
    await page.screenshot({ path: path.join(artifactDir, '4_back_and_retry_failed.png') });
    check(new URL(page.url()).origin === origin && new URL(page.url()).searchParams.get('login_error') === 'oauth_failed', '/?login_error=oauth_failed へ戻る（公開オリジン）', page.url());
    const notice = page.getByText(failedTitle).first();
    await notice.waitFor({ state: 'visible' });
    check(await notice.isVisible(), `ログインの失敗の通知が出る（文言は文言カタログ: 「${failedTitle}」）`);

    // ----- 流れ 3: Cookie が無い状態でのコールバック -----
    console.log('-- 流れ 3: 新しいブラウザ（Cookie なし）で、アカウント選択の画面のリンクを開く');
    const clean = await browser.newContext({ locale: 'ja-JP' });
    clean.setDefaultNavigationTimeout(NAVIGATION_TIMEOUT_MS);
    const cleanPage = await clean.newPage();
    await cleanPage.goto(`${origin}/`, { waitUntil: 'domcontentloaded' });
    await cleanPage.getByRole('button', { name: /LOG IN WITH GOOGLE/ }).first().click();
    await cleanPage.waitForURL(/\/api\/dev\/google\/authorize\?/);
    const href = await cleanPage.getByRole('link', { name: 'dev-user-2' }).getAttribute('href');
    await clean.clearCookies();
    await cleanPage.goto(href, { waitUntil: 'domcontentloaded' });
    await cleanPage.waitForURL(/\/\?login_error=oauth_failed/);
    check(new URL(cleanPage.url()).searchParams.get('login_error') === 'oauth_failed', '認可の途中の状態（Cookie）が無いコールバックは、oauth_failed に戻る');
    check((await clean.cookies()).find((cookie) => cookie.name === 'bl_session') === undefined, 'その場合、セッションは発行されない');
    await clean.close();

    // ----- 通信・ダイアログ -----
    const external = [...hosts].filter((host) => host !== `localhost:${port}`);
    check(external.length === 0, '外部のドメインへ通信しない（疑似の Google。実際の Google・reCAPTCHA を呼ばない）', external.join(','));
    check(dialogs.length === 0, 'ネイティブのダイアログ（alert・confirm・prompt）を開かない', dialogs.join(','));
    console.log(`NOTE スクリーンショットの置き場: ${artifactDir}`);
  } finally {
    await browser.close();
  }
  console.log(`\n${passes + failures} 件を確認しました（失敗 ${failures} 件）`);
  return failures === 0 ? EXIT_OK : EXIT_FAILED;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.log(`FAIL 想定外の失敗: ${String(error && error.stack ? error.stack : error).slice(0, 600)}`);
    process.exit(EXIT_FAILED);
  },
);
