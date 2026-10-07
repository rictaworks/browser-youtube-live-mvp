'use strict';
// 文言の正本（src/frontend/messages/<ファイル>.ts）の 1 つの文言を、標準出力へ出す。シェルのテストが、文言を複写せずに、画面と照合するために使う。
//
// 使い方: node message_text.cjs <リポジトリのルート> <ファイル名（拡張子なし）> <export の名前> <キーの経路（例: hero.login）>
//   例: node message_text.cjs "$ROOT_DIR" landing landing hero.login
// 終了コード: 0 = 出力した / 1 = 文言が無い・文字列でない / 2 = 引数の不備 / 3 = TypeScript が無く、読めない

const { loadMessageModule, loadTypeScript } = require('./messages_loader.cjs');

const [repo, fileName, exportName, keyPath] = process.argv.slice(2);
if (!repo || !fileName || !exportName || !keyPath) {
  console.error('使い方: node message_text.cjs <リポジトリのルート> <ファイル名> <export の名前> <キーの経路>');
  process.exit(2);
}
if (loadTypeScript(repo) === null) {
  console.error('TypeScript（src/frontend/node_modules/typescript）が見つかりません');
  process.exit(3);
}

let value = loadMessageModule(repo, `${fileName}.ts`)[exportName];
for (const key of keyPath.split('.')) {
  value = value === undefined || value === null ? undefined : value[key];
}
if (typeof value !== 'string') {
  console.error(`文言が見つからない、または文字列ではありません: ${fileName}.${exportName}.${keyPath}`);
  process.exit(1);
}
process.stdout.write(value);
