// 診断（デバッグでたどるための記録）の出力先。項目は、文字列・数値・真偽・null だけ。デバイス名・ラベルなどの機微な値は、呼び出し側が入れない。
import { NO_DIAGNOSTICS, createConsoleDiagnosticSink } from "./diagnostics";

describe("NO_DIAGNOSTICS", () => {
  it("何もしない（呼んでも、例外を投げない）", () => {
    expect(() => NO_DIAGNOSTICS("source_attach", { kind: "camera" })).not.toThrow();
  });
});

describe("createConsoleDiagnosticSink", () => {
  it("接頭辞・出来事の名前・項目（JSON）を、1 行で出力する", () => {
    const debug = jest.fn();
    const sink = createConsoleDiagnosticSink("sources", { debug });

    sink("source_state", { kind: "camera", state: "active", count: 2, ok: true, reason: null });

    expect(debug).toHaveBeenCalledTimes(1);
    expect(debug).toHaveBeenCalledWith('sources: source_state {"kind":"camera","state":"active","count":2,"ok":true,"reason":null}');
  });

  it("項目が空でも出力する", () => {
    const debug = jest.fn();

    createConsoleDiagnosticSink("audio", { debug })("mixer_started", {});

    expect(debug).toHaveBeenCalledWith("audio: mixer_started {}");
  });

  it("出力先を省くと、console.debug を使う", () => {
    const spy = jest.spyOn(console, "debug").mockImplementation(() => undefined);
    try {
      createConsoleDiagnosticSink("sources")("source_state", { kind: "screen" });

      expect(spy).toHaveBeenCalledWith('sources: source_state {"kind":"screen"}');
    } finally {
      spy.mockRestore();
    }
  });
});
