'use strict';
// 実ブラウザの確認（issue #27）の共通部品。ローカルの HTTP サーバー（127.0.0.1）が、src/frontend の TypeScript を、リポジトリの TypeScript で、
// その場で JavaScript にして配る（成果物のファイルは作らない）。ワーカー（モジュールワーカー）も、同じ仕組みで読み込む。
// Playwright は、--playwright-dir（または環境変数 ISSUE27_PLAYWRIGHT_DIR）の下の node_modules/playwright。無ければ「確認できなかった」（終了コード 3）。
// 使うのは、ローカルの 127.0.0.1 だけ。YouTube・Google・reCAPTCHA は呼ばない。

const fs = require('fs');
const http = require('http');
const path = require('path');

const EXIT_OK = 0;
const EXIT_MISMATCH = 1;
const EXIT_UNAVAILABLE = 3;

/** 配る TypeScript のルート（src/frontend からの相対）。 */
const SERVED_ROOTS = ['lib', 'core', 'workers'];

function parseArguments(argv, defaults) {
  const options = { repo: null, playwrightDir: process.env.ISSUE27_PLAYWRIGHT_DIR || null, channel: process.env.ISSUE27_BROWSER_CHANNEL || null, json: false, ...defaults };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--repo') {
      options.repo = argv[(index += 1)];
    } else if (argument === '--playwright-dir') {
      options.playwrightDir = argv[(index += 1)];
    } else if (argument === '--channel') {
      options.channel = argv[(index += 1)];
    } else if (argument === '--work-dir') {
      options.workDir = argv[(index += 1)];
    } else if (argument === '--json') {
      options.json = true;
    } else if (argument.startsWith('--') && Object.prototype.hasOwnProperty.call(defaults || {}, argument.slice(2))) {
      const key = argument.slice(2);
      const value = argv[(index += 1)];
      options[key] = typeof defaults[key] === 'number' ? Number(value) : value;
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!options.repo) {
    throw new Error('--repo is required');
  }
  return options;
}

function unavailable(reason) {
  console.log(`SKIP 確認できなかった: ${reason}`);
  process.exit(EXIT_UNAVAILABLE);
}

function loadModule(label, candidates) {
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch (error) {
      if (error && error.code !== 'MODULE_NOT_FOUND') {
        throw error;
      }
    }
  }
  return unavailable(`${label} が見つかりません（探した場所: ${candidates.join(', ')}）`);
}

function loadTools(options) {
  const frontendRoot = path.join(options.repo, 'src', 'frontend');
  const playwright = loadModule('Playwright', [options.playwrightDir && path.join(options.playwrightDir, 'node_modules', 'playwright'), path.join(frontendRoot, 'node_modules', 'playwright')].filter(Boolean));
  const ts = loadModule('TypeScript', [path.join(frontendRoot, 'node_modules', 'typescript')]);
  return { frontendRoot, playwright, ts };
}

/**
 * ローカルのサーバーを作る。
 *   /                       pageHtml
 *   /app/<パス>.js          src/frontend/<パス>.ts を JavaScript にして返す（lib・core・workers の下だけ）
 *   /probe/<ファイル>        browserDirectory の下のファイルを、そのまま返す（モジュールの import は、/app/... の絶対 URL）
 *   /worklets/<ファイル>     src/frontend/public/worklets の下（Next.js が / から配るのと同じ URL）
 */
function createServer({ ts, frontendRoot, browserDirectory, pageHtml }) {
  function resolveSpecifier(specifier, directory) {
    const base = specifier.startsWith('@/') ? path.resolve(frontendRoot, specifier.slice(2)) : path.resolve(directory, specifier);
    const relative = path.relative(frontendRoot, base).split(path.sep).join('/');
    if (fs.existsSync(`${base}.ts`)) {
      return `/app/${relative}.js`;
    }
    if (fs.existsSync(path.join(base, 'index.ts'))) {
      return `/app/${relative}/index.js`;
    }
    throw new Error(`unresolved import ${specifier} in ${directory}`);
  }

  function transpile(file) {
    const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      fileName: file,
      compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, isolatedModules: true },
    });
    const directory = path.dirname(file);
    return output.outputText.replace(/(\bfrom\s+["'])((?:@\/|\.{1,2}\/)[^"']*)(["'])/g, (_match, head, specifier, tail) => `${head}${resolveSpecifier(specifier, directory)}${tail}`);
  }

  return http.createServer((request, response) => {
    try {
      const url = new URL(request.url, 'http://127.0.0.1');
      if (url.pathname === '/') {
        response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        response.end(pageHtml);
        return;
      }
      const probeMatch = /^\/probe\/([A-Za-z0-9_.-]+)$/.exec(url.pathname);
      if (probeMatch) {
        const file = path.join(browserDirectory, probeMatch[1]);
        if (!fs.existsSync(file)) {
          response.writeHead(404, { 'content-type': 'text/plain' });
          response.end('not found');
          return;
        }
        response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' });
        response.end(fs.readFileSync(file));
        return;
      }
      const workletMatch = /^\/worklets\/([A-Za-z0-9_.-]+)$/.exec(url.pathname);
      if (workletMatch) {
        const file = path.join(frontendRoot, 'public', 'worklets', workletMatch[1]);
        if (!fs.existsSync(file)) {
          response.writeHead(404, { 'content-type': 'text/plain' });
          response.end('not found');
          return;
        }
        response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' });
        response.end(fs.readFileSync(file));
        return;
      }
      const appMatch = /^\/app\/(.+)\.js$/.exec(url.pathname);
      const source = appMatch ? path.resolve(frontendRoot, `${appMatch[1]}.ts`) : null;
      const allowed = source !== null && SERVED_ROOTS.some((root) => source.startsWith(path.join(frontendRoot, root) + path.sep));
      if (!allowed || !fs.existsSync(source)) {
        response.writeHead(404, { 'content-type': 'text/plain' });
        response.end('not found');
        return;
      }
      response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' });
      response.end(transpile(source));
    } catch (error) {
      response.writeHead(500, { 'content-type': 'text/plain' });
      response.end(String(error && error.stack ? error.stack : error));
    }
  });
}

/** サーバーを起動して、基準の URL を返す。 */
async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}/`;
}

/** 検査を 1 件記録して、表示する。results に { ok, label, detail } を足す。 */
function check(results, label, ok, detail = '') {
  results.push({ ok: Boolean(ok), label, detail });
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? `  [${detail}]` : ''}`);
}

function finish(results, options, title) {
  const failed = results.filter((result) => !result.ok);
  if (options.json) {
    console.log(JSON.stringify({ results }, null, 2));
  }
  console.log(`\n${title}: ${results.length - failed.length} 件 ok / ${failed.length} 件 FAIL`);
  process.exit(failed.length === 0 ? EXIT_OK : EXIT_MISMATCH);
}

/** Chromium の起動の引数（偽のカメラ・マイク・画面共有の選択画面）。 */
const FAKE_DEVICE_ARGUMENTS = ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'];

module.exports = { EXIT_OK, EXIT_MISMATCH, EXIT_UNAVAILABLE, FAKE_DEVICE_ARGUMENTS, parseArguments, unavailable, loadModule, loadTools, createServer, listen, check, finish };
