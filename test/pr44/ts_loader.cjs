'use strict';
// core の TypeScript を、リポジトリの TypeScript で、その場で CommonJS にして読み込む（ファイルは作らない）。独立した検査（Jest を使わない検査）の共通の道具。
// 読み取りのみ。
//
//   const createCoreLoader = require('./ts_loader.cjs');
//   const requireCore = createCoreLoader(repo);   // TypeScript が無ければ null
//   const transport = requireCore('transport');   // core からの相対（ディレクトリは index.ts を読む）

const fs = require('fs');
const path = require('path');

function createCoreLoader(repo) {
  let ts;
  try {
    ts = require(path.join(repo, 'src', 'frontend', 'node_modules', 'typescript'));
  } catch (error) {
    return null;
  }
  const coreRoot = path.join(repo, 'src', 'frontend', 'core');
  const cache = new Map();

  function resolveFile(base) {
    for (const candidate of [`${base}.ts`, path.join(base, 'index.ts')]) {
      if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
    }
    throw new Error(`module not found: ${path.relative(repo, base)}`);
  }

  function load(file) {
    if (cache.has(file)) return cache.get(file).exports;
    const source = fs.readFileSync(file, 'utf8');
    const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true }, fileName: file }).outputText;
    const moduleObject = { exports: {} };
    cache.set(file, moduleObject);
    const localRequire = (specifier) => {
      if (!specifier.startsWith('.')) throw new Error(`a non-relative import in ${path.relative(repo, file)}: ${specifier}`);
      return load(resolveFile(path.resolve(path.dirname(file), specifier)));
    };
    new Function('exports', 'require', 'module', '__filename', '__dirname', output)(moduleObject.exports, localRequire, moduleObject, file, path.dirname(file));
    return moduleObject.exports;
  }

  return (relative) => load(resolveFile(path.join(coreRoot, relative)));
}

module.exports = createCoreLoader;
