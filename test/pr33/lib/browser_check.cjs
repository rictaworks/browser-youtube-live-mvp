'use strict';
// 実ブラウザ（Playwright の Chromium）で、PR #33 のユーザーテスト手順 1〜5 を確かめる。対象は開発サーバー（ホストの localhost）。
//
//   手順 1  /healthz（frontend）   {"status":"ok"} と表示される
//   手順 2  /up（backend）         緑一色（画面の全画素が rgb(0, 128, 0)）
//   手順 3  /health（relay）       {"status":"ok"} と表示される
//   手順 4  3101（backend の内部通信の口）  開けない（接続を拒否される）
//   手順 5  /（frontend）          404 の画面
//
// 使い方: PR33_PLAYWRIGHT_DIR=<playwright の置き場> node browser_check.cjs
//   FRONTEND_PORT・BACKEND_PORT・RELAY_PORT  ポート番号（既定は 3000・3001・3002。ホストは localhost に固定）
//   PR33_ARTIFACT_DIR                        スクリーンショットの置き場（既定は、新しく作る一時ディレクトリ）
// 終了コード: 0 成功 / 1 失敗あり / 3 ブラウザを使えず、確認できなかった
//
// ブラウザのメディア API（getUserMedia・getDisplayMedia・WebCodecs など）は、この PR に無いため、確認しない。

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const EXIT_OK = 0;
const EXIT_FAILED = 1;
const EXIT_UNAVAILABLE = 3;

const GREEN = [0, 128, 0];
const INTERNAL_PORT = 3101;

let failures = 0;
const pass = (message) => console.log(`ok   ${message}`);
const fail = (message) => {
  console.log(`FAIL ${message}`);
  failures += 1;
};
const expectEq = (label, expected, actual) => {
  if (JSON.stringify(actual) === JSON.stringify(expected)) {
    pass(label);
  } else {
    fail(`${label}（期待: ${JSON.stringify(expected)} / 実際: ${JSON.stringify(actual)}）`);
  }
};

function port(name, fallback) {
  const value = process.env[name] || String(fallback);
  if (!/^[0-9]{1,5}$/.test(value)) {
    console.log(`FAIL ${name} は、ポート番号ではありません（${value}）`);
    process.exit(2);
  }
  return value;
}

const frontend = `http://localhost:${port('FRONTEND_PORT', 3000)}`;
const backend = `http://localhost:${port('BACKEND_PORT', 3001)}`;
const relay = `http://localhost:${port('RELAY_PORT', 3002)}`;

function loadPlaywright() {
  const dir = process.env.PR33_PLAYWRIGHT_DIR;
  if (!dir) {
    console.log('SKIP PR33_PLAYWRIGHT_DIR が指定されていません');
    process.exit(EXIT_UNAVAILABLE);
  }
  try {
    return require(dir);
  } catch (error) {
    console.log(`SKIP Playwright を読み込めません（${dir}）: ${String(error.message).split('\n')[0]}`);
    process.exit(EXIT_UNAVAILABLE);
  }
}

// スクリーンショット（PNG）の色を、ブラウザの canvas で数える。戻り値: 画素数・色の種類の数・最も多い色とその割合
async function analyzeColors(helperPage, png) {
  return helperPage.evaluate(async (base64) => {
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
    return {
      pixels: canvas.width * canvas.height,
      distinct: counts.size,
      dominant: dominantKey.split(',').map(Number),
      dominantRatio: dominantCount / (canvas.width * canvas.height),
    };
  }, png.toString('base64'));
}

async function main() {
  const { chromium } = loadPlaywright();
  const artifactDir = process.env.PR33_ARTIFACT_DIR || fs.mkdtempSync(path.join(os.tmpdir(), 'pr33_browser_'));
  fs.mkdirSync(artifactDir, { recursive: true });

  let browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch (error) {
    console.log(`SKIP Chromium を起動できません: ${String(error.message).split('\n')[0]}`);
    process.exit(EXIT_UNAVAILABLE);
  }

  try {
    // 画素を数えるため、表示の倍率を 1 に固定する
    const context = await browser.newContext({ viewport: { width: 800, height: 600 }, deviceScaleFactor: 1 });
    const page = await context.newPage();
    const helperPage = await context.newPage();

    let pageErrors = [];
    let badResponses = [];
    page.on('pageerror', (error) => pageErrors.push(String(error.message).split('\n')[0]));
    page.on('response', (response) => {
      if (response.status() >= 400) badResponses.push(`${response.status()} ${response.url()}`);
    });
    const resetObservations = () => {
      pageErrors = [];
      badResponses = [];
    };

    const open = async (url) => {
      resetObservations();
      const response = await page.goto(url, { waitUntil: 'load', timeout: 60000 });
      return {
        response,
        text: (await page.evaluate(() => document.body.innerText)).trim(),
        title: await page.title(),
        background: await page.evaluate(() => getComputedStyle(document.body).backgroundColor),
      };
    };
    const shot = async (name) => {
      const png = await page.screenshot({ type: 'png' });
      fs.writeFileSync(path.join(artifactDir, `${name}.png`), png);
      return png;
    };

    console.log(`\n-- 手順 1: ${frontend}/healthz`);
    let visit = await open(`${frontend}/healthz`);
    expectEq('手順 1: HTTP 200', 200, visit.response.status());
    expectEq('手順 1: 画面に {"status":"ok"} と表示される', '{"status":"ok"}', visit.text);
    expectEq('手順 1: ページのエラー（未処理の例外）が無い', [], pageErrors);
    await shot('step1_frontend_healthz');

    console.log(`\n-- 手順 2: ${backend}/up`);
    visit = await open(`${backend}/up`);
    expectEq('手順 2: HTTP 200', 200, visit.response.status());
    expectEq('手順 2: 背景色は緑（rgb(0, 128, 0)）', 'rgb(0, 128, 0)', visit.background);
    expectEq('手順 2: 文字は何も表示されない', '', visit.text);
    const greenShot = await shot('step2_backend_up');
    const colors = await analyzeColors(helperPage, greenShot);
    expectEq(`手順 2: 画面の全画素（${colors.pixels} 画素）が 1 色`, 1, colors.distinct);
    expectEq('手順 2: その色は緑（0, 128, 0）', GREEN, colors.dominant);

    console.log(`\n-- 手順 3: ${relay}/health`);
    visit = await open(`${relay}/health`);
    expectEq('手順 3: HTTP 200', 200, visit.response.status());
    expectEq('手順 3: 画面に {"status":"ok"} と表示される', '{"status":"ok"}', visit.text);
    await shot('step3_relay_health');

    console.log(`\n-- 手順 4: http://localhost:${INTERNAL_PORT}/up（開けない）`);
    // 接続に失敗したページは、ブラウザのエラー画面への遷移が続くことがある。次の手順の遷移と競合しないよう、専用のページで行う
    const unreachablePage = await context.newPage();
    let navigationError = null;
    try {
      await unreachablePage.goto(`http://localhost:${INTERNAL_PORT}/up`, { waitUntil: 'load', timeout: 15000 });
    } catch (error) {
      navigationError = String(error.message).split('\n')[0];
    }
    await unreachablePage.close();
    if (navigationError === null) {
      fail(`手順 4: localhost:${INTERNAL_PORT} が開けてしまった`);
    } else if (/net::ERR_(CONNECTION_REFUSED|CONNECTION_RESET|CONNECTION_TIMED_OUT|EMPTY_RESPONSE|ADDRESS_UNREACHABLE)/.test(navigationError)) {
      pass(`手順 4: localhost:${INTERNAL_PORT} は開けない（${navigationError.replace(/^page\.goto: /, '')}）`);
    } else {
      fail(`手順 4: 接続できない以外の理由で失敗した（${navigationError}）`);
    }

    console.log(`\n-- 手順 5: ${frontend}/（404）`);
    visit = await open(`${frontend}/`);
    expectEq('手順 5: HTTP 404', 404, visit.response.status());
    expectEq('手順 5: ページのタイトル', '404: This page could not be found.', visit.title);
    expectEq('手順 5: 画面に「404」と「This page could not be found.」が表示される', '404\nThis page could not be found.', visit.text);
    expectEq('手順 5: ページのエラー（未処理の例外）が無い', [], pageErrors);
    // 404 の文書そのもの以外に、失敗した読み込み（画面の部品の 404・500）が無い
    expectEq('手順 5: 文書以外に、失敗した読み込みが無い', [`404 ${frontend}/`], badResponses);
    const notFoundShot = await shot('step5_frontend_root_404');
    const notFoundColors = await analyzeColors(helperPage, notFoundShot);
    if (JSON.stringify(notFoundColors.dominant) === JSON.stringify([255, 255, 255]) && notFoundColors.dominantRatio > 0.9) {
      pass('手順 5: 画面の大半は白（文字だけの簡素な 404 の画面）');
    } else {
      fail(`手順 5: 画面の大半は白（実際の最多の色: ${notFoundColors.dominant.join(',')}、割合 ${notFoundColors.dominantRatio.toFixed(2)}）`);
    }

    console.log(`\nスクリーンショットの置き場: ${artifactDir}`);
  } finally {
    await browser.close();
  }
}

main()
  .then(() => {
    if (failures > 0) {
      console.log(`\n${failures} 件失敗しました`);
      process.exit(EXIT_FAILED);
    }
    console.log('\nすべて成功しました');
    process.exit(EXIT_OK);
  })
  .catch((error) => {
    console.log(`FAIL 予期しないエラー: ${error && error.stack ? error.stack.split('\n').slice(0, 4).join(' | ') : error}`);
    process.exit(EXIT_FAILED);
  });
