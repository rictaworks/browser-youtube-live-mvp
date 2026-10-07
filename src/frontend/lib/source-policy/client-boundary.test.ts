/**
 * @jest-environment node
 */
import { findClientOnlyFeatures, hasUseClientDirective } from "./client-boundary";

describe("hasUseClientDirective: ファイルの先頭の 'use client'", () => {
  it.each([
    ["二重引用符", '"use client";\nexport const a = 1;'],
    ["単一引用符", "'use client';\nexport const a = 1;"],
    ["セミコロンなし", '"use client"\nexport const a = 1;'],
    ["先頭にコメントがあっても", '// コメント\n/* ブロック */\n"use client";\nexport const a = 1;'],
  ])("%s は、持つ", (_label, source) => {
    expect(hasUseClientDirective("sample.tsx", source)).toBe(true);
  });

  it.each([
    ["無い", "export const a = 1;"],
    ["import のあとに書いた（ディレクティブとして効かない）", 'import x from "x";\n"use client";\nexport const a = x;'],
    ["似た文字列", '"use server";\nexport const a = 1;'],
    ["文字列の式の一部", 'const s = "use client";\nexport const a = s;'],
  ])("%s は、持たない", (_label, source) => {
    expect(hasUseClientDirective("sample.tsx", source)).toBe(false);
  });
});

describe("findClientOnlyFeatures: クライアントでしか動かない機能（イベントハンドラー・フック）", () => {
  it.each([
    ["onClick", 'export const A = () => <button onClick={() => {}}>x</button>;'],
    ["onChange", "export const A = () => <input onChange={handle} />;"],
    ["onSubmit", "export const A = () => <form onSubmit={handle} />;"],
    ["useState", "export function A() { const [a] = useState(0); return a; }"],
    ["useEffect", "export function A() { useEffect(() => {}, []); return null; }"],
    ["useRef", "export function A() { const r = useRef(null); return r; }"],
    ["usePathname", "export function A() { return usePathname(); }"],
    ["useRouter", "export function A() { return useRouter(); }"],
    ["useContext", "export function A() { return useContext(C); }"],
  ])("%s を見つける", (_label, source) => {
    expect(findClientOnlyFeatures("sample.tsx", source).length).toBeGreaterThan(0);
  });

  it.each([
    ["サーバーでも使える useId", "export function A() { const id = useId(); return id; }"],
    ["on で始まる名前の属性でない（onward）", 'export const A = () => <a data-onward="1">x</a>;'],
    ["ハンドラーを受け取らない部品", 'export const A = () => <button type="button">x</button>;'],
    ["文字列の中", 'const s = "onClick useState";'],
    ["コメントの中", "// useState and onClick"],
    ["use で始まるが、フックでない関数", "export const A = () => userName();"],
  ])("%s は、見つけない", (_label, source) => {
    expect(findClientOnlyFeatures("sample.tsx", source)).toEqual([]);
  });

  it("位置（行・桁）と、見つけた箇所を返す", () => {
    const findings = findClientOnlyFeatures("sample.tsx", 'export function A() {\n  const [a] = useState(0);\n  return a;\n}\n');

    expect(findings).toHaveLength(1);
    expect(findings[0].line).toBe(2);
    expect(findings[0].text).toBe("useState(0)");
  });
});
