'use strict';
// 文言の正本（src/frontend/messages/*.ts）を、テストが読む。画面の表示が、正本と一致するかを確かめるときに、文言をテストへ複写しない
// （文言は、公開用の文章へ差し替わる。差し替わっても、テストが、画面と正本の一致を見続けられるようにする）。
//
// TypeScript のコンパイラで、変換だけを行う（実行するのは、変換した 1 つのファイルだけ。import を持つファイルは読めない）。
// 使う側は、frontend の依存（src/frontend/node_modules/typescript）が必要。無ければ、呼び出し側が、確認できなかった（SKIP）として扱う。

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function frontendDir(repo) {
  return path.join(repo, 'src', 'frontend');
}

/** TypeScript のコンパイラを読む。無ければ null */
function loadTypeScript(repo) {
  try {
    return require(path.join(frontendDir(repo), 'node_modules', 'typescript'));
  } catch {
    return null;
  }
}

/**
 * messages/ の 1 つのファイル（例: landing.ts）を読み、export された値の組を返す（例: { landing: {...} }）。
 * import を含むファイルは、読み込みを拒否する（messages/ja.ts のような、集約のファイルは対象外）。
 */
function loadMessageModule(repo, fileName) {
  const ts = loadTypeScript(repo);
  if (ts === null) {
    throw new Error('TypeScript（src/frontend/node_modules/typescript）が見つかりません');
  }
  const source = fs.readFileSync(path.join(frontendDir(repo), 'messages', fileName), 'utf8');
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    fileName,
  });
  const moduleObject = { exports: {} };
  const refuseImport = () => {
    throw new Error(`${fileName} は、import を持つため、単独では読めません`);
  };
  vm.runInNewContext(outputText, { module: moduleObject, exports: moduleObject.exports, require: refuseImport });
  return moduleObject.exports;
}

/** 文言の {name} を、値で置き換える（足りない値があれば、例外にする。画面の翻訳関数と同じ規則） */
function fillTemplate(template, values) {
  return template.replace(/\{(\w+)\}/g, (_match, name) => {
    if (!Object.prototype.hasOwnProperty.call(values, name)) {
      throw new Error(`文言の値が足りません: ${name}`);
    }
    return String(values[name]);
  });
}

module.exports = { loadMessageModule, fillTemplate, loadTypeScript, frontendDir };
