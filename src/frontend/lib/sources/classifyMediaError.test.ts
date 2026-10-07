// getUserMedia・getDisplayMedia の失敗の分類（requirements.md 11.2・25.5。issue #26）。
//   - getUserMedia の NotAllowedError = 拒否（denied）
//   - getDisplayMedia の NotAllowedError = 選択の取り消し。ブラウザが、拒否と取り消しを区別できないため、画面共有は拒否にせず、未取得へ戻す
//   - NotFoundError（デバイスが無い）・指定したデバイスの識別子が無い（OverconstrainedError の deviceId）= 未取得 + 理由
//   - その他 = 型付きのエラー（符号と、元のエラーの名前）
import type { MediaFailure } from "./classifyMediaError";
import { classifyMediaError } from "./classifyMediaError";
import type { ManagedSourceKind } from "./types";

function domError(name: string, extra: Record<string, unknown> = {}): unknown {
  return Object.assign(new DOMException(`message for ${name}`, name), extra);
}

describe("classifyMediaError", () => {
  const cases: readonly (readonly [ManagedSourceKind, string, MediaFailure])[] = [
    ["camera", "NotAllowedError", { outcome: "denied" }],
    ["microphone", "NotAllowedError", { outcome: "denied" }],
    ["screen", "NotAllowedError", { outcome: "cancelled" }],
    ["camera", "NotFoundError", { outcome: "not_found" }],
    ["microphone", "NotFoundError", { outcome: "not_found" }],
    ["screen", "NotFoundError", { outcome: "not_found" }],
    ["camera", "InvalidStateError", { outcome: "error", code: "invalid_state", errorName: "InvalidStateError" }],
    ["screen", "InvalidStateError", { outcome: "error", code: "invalid_state", errorName: "InvalidStateError" }],
    ["screen", "NotSupportedError", { outcome: "error", code: "unsupported", errorName: "NotSupportedError" }],
    ["camera", "NotReadableError", { outcome: "error", code: "not_readable", errorName: "NotReadableError" }],
    ["screen", "NotReadableError", { outcome: "error", code: "not_readable", errorName: "NotReadableError" }],
    ["microphone", "AbortError", { outcome: "error", code: "aborted", errorName: "AbortError" }],
    ["camera", "SecurityError", { outcome: "error", code: "unexpected", errorName: "SecurityError" }],
    ["camera", "TypeError", { outcome: "error", code: "unexpected", errorName: "TypeError" }],
    ["screen", "SomethingElseError", { outcome: "error", code: "unexpected", errorName: "SomethingElseError" }],
  ];

  it.each(cases)("%s の %s", (kind, name, expected) => {
    expect(classifyMediaError(kind, domError(name))).toEqual(expected);
  });

  it("OverconstrainedError は、指定したデバイスの識別子が無いとき（constraint が deviceId）だけ、デバイスが無いとして扱う", () => {
    expect(classifyMediaError("camera", domError("OverconstrainedError", { constraint: "deviceId" }))).toEqual({ outcome: "not_found" });
    expect(classifyMediaError("microphone", domError("OverconstrainedError", { constraint: "deviceId" }))).toEqual({ outcome: "not_found" });
    expect(classifyMediaError("camera", domError("OverconstrainedError", { constraint: "width" }))).toEqual({
      outcome: "error",
      code: "unexpected",
      errorName: "OverconstrainedError",
    });
    expect(classifyMediaError("camera", domError("OverconstrainedError"))).toEqual({ outcome: "error", code: "unexpected", errorName: "OverconstrainedError" });
  });

  it.each(["constructor", "toString", "__proto__", "hasOwnProperty"])("Object.prototype の名前（%s）は、型付きのエラーの対応に当たらず、想定外として扱う", (name) => {
    expect(classifyMediaError("camera", { name })).toEqual({ outcome: "error", code: "unexpected", errorName: name });
  });

  it("名前を持つ普通のオブジェクト・Error でも、名前で分類する", () => {
    expect(classifyMediaError("camera", { name: "NotAllowedError" })).toEqual({ outcome: "denied" });
    expect(classifyMediaError("camera", new TypeError("bad constraints"))).toEqual({ outcome: "error", code: "unexpected", errorName: "TypeError" });
  });

  it.each([undefined, null, "NotAllowedError", 42, {}, { name: 7 }, { name: "" }])("名前を読めない値（%p）は、分類を推測せず、想定外の型付きのエラー（名前は unknown）", (value) => {
    expect(classifyMediaError("camera", value)).toEqual({ outcome: "error", code: "unexpected", errorName: "unknown" });
  });
});
