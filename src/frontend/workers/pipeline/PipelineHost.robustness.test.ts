/**
 * @jest-environment node
 */
// PipelineHost（境界の堅牢さ・資源の解放。issue #27）。
//   - メインスレッドから届く値は信用しない。決められた形でなければ invalid_message の故障にし、ワーカーを落とさない
//   - 例外は、ワーカーの未処理の例外にしない（メインスレッドで「ワーカーの異常終了」に見えるため）。故障として知らせる
//   - 終了（shutdown・dispose）で、すべての資源（フレーム・エンコーダ・ポート・タイマ・プレビュー・ソースの読み取り）を解放する
//   - 故障の通知には、符号と、元のエラーの名前だけを載せる（デバイス名・URL・配信のタイトルを載せない）
import { HostHarness, settle } from "./host-support";
import { FakeCanvas, FakeVideoEncoder, FakeAudioEncoder } from "./test-support";

describe("不正な入力", () => {
  it("未知のコマンド・オブジェクトでない値: invalid_message の故障。例外は投げない", () => {
    const harness = new HostHarness();

    expect(() => {
      harness.host.handle({ type: "explode" });
      harness.host.handle("text");
      harness.host.handle(null);
      harness.host.handle(undefined);
      harness.host.handle(42);
    }).not.toThrow();

    expect(harness.faultCodes()).toEqual(["invalid_message", "invalid_message", "invalid_message", "invalid_message", "invalid_message"]);
  });

  it("応答のある要求（requestId を持つ）が不正なら、故障ではなく、その要求への失敗の応答にする（待たせない）", async () => {
    const harness = new HostHarness();

    harness.host.handle({ type: "configure", requestId: 7, profile: "1080p", videoCodec: "avc1.4D401F", videoBitrateKbps: 4500 });
    const reply = await harness.replyTo(7);

    expect(reply.ok).toBe(false);
    if (!reply.ok) {
      expect(reply.fault.code).toBe("invalid_message");
    }
    expect(harness.eventsOf("fault")).toEqual([]);
  });

  it("でたらめな値を 300 通り送っても、例外を投げない。ワーカーは動き続け、正しい要求に応答できる", async () => {
    const harness = new HostHarness();
    let seed = 777;
    const random = (): number => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };
    const types = ["attach_preview", "detach_preview", "add_source", "remove_source", "configure", "connect_audio", "audio_stalled", "set_bitrate", "get_stats", "end_session", "begin_delivery", "x"];
    const junk = [null, undefined, 0, -1, 1.5, "a", true, {}, [], { getContext: 1 }, { getReader: 1 }, { close: 1 }, Number.NaN];

    for (let index = 0; index < 300; index += 1) {
      const message: Record<string, unknown> = { type: types[Math.floor(random() * types.length)] };
      for (const key of ["canvas", "readable", "port", "kind", "profile", "videoCodec", "videoBitrateKbps", "requestId", "kbps"]) {
        if (random() < 0.5) {
          message[key] = junk[Math.floor(random() * junk.length)];
        }
      }
      expect(() => harness.host.handle(message)).not.toThrow();
    }
    await settle();

    const reply = await harness.replyTo(harness.request("get_stats"));
    expect(reply.ok).toBe(true);
  });

  it("ハンドラが例外を投げても（プレビューの canvas の getContext が例外）、ワーカーの未処理の例外にせず、型付きの故障として知らせる", () => {
    const harness = new HostHarness();
    const broken = new FakeCanvas(300, 150);
    broken.getContext = () => {
      throw new DOMException("context lost", "InvalidStateError");
    };

    expect(() => harness.send({ type: "attach_preview", canvas: broken.asOffscreen() })).not.toThrow();

    expect(harness.eventsOf("fault").map((event) => event.fault)).toEqual([{ code: "preview_unavailable", detail: "InvalidStateError" }]);
  });
});

describe("重複した通知", () => {
  it("送出の開始を重ねても、2 回目はキーフレームを強制しない（映像の流れを乱さない）", async () => {
    const harness = new HostHarness();
    await harness.configureAndPrime();
    harness.send({ type: "begin_delivery" });
    harness.feedSeconds(0.2);
    const encoder = FakeVideoEncoder.instances[0];
    const keysBefore = encoder.encodeCalls.filter((call) => call.keyFrame).length;

    harness.send({ type: "begin_delivery" });
    harness.feedSeconds(0.2);

    expect(encoder.encodeCalls.filter((call) => call.keyFrame).length).toBe(keysBefore);
  });

  it("設定の前の pause_delivery・remove_source・detach_preview は、何も起こさない", () => {
    const harness = new HostHarness();

    harness.send({ type: "pause_delivery" });
    harness.send({ type: "remove_source", kind: "camera" });
    harness.send({ type: "detach_preview" });

    expect(harness.events).toEqual([]);
  });
});

describe("shutdown（終了）で、すべての資源を解放する", () => {
  it("フレーム・エンコーダ・ポート・タイマ・プレビュー・ソースの読み取りを解放し、以後のメッセージを受け付けない", async () => {
    const harness = new HostHarness();
    const preview = harness.attachPreview();
    const camera = harness.addSource("camera");
    const screen = harness.addSource("screen");
    camera.controller.enqueue(camera.ledger.create(640, 480));
    screen.controller.enqueue(screen.ledger.create(1920, 1080));
    await settle();
    const port = harness.connectAudio();
    await harness.configureAndPrime();
    harness.send({ type: "begin_delivery" });
    harness.feedSeconds(0.5);

    harness.send({ type: "shutdown" });
    await settle();

    expect(camera.ledger.openCount + screen.ledger.openCount).toBe(0);
    expect(camera.cancelled).toBe(true);
    expect(screen.cancelled).toBe(true);
    expect(FakeVideoEncoder.instances[0].closeCalls).toBe(1);
    expect(FakeAudioEncoder.instances[0].closeCalls).toBe(1);
    expect(port.closeCount).toBe(1);
    expect(harness.scheduler.activeCount).toBe(0);
    expect(harness.videoFrames.created.every((frame) => frame.closeCount === 1)).toBe(true);
    expect(harness.audioData.created.every((data) => data.closeCount === 1)).toBe(true);

    const eventsAfter = harness.events.length;
    preview.context.calls.length = 0;
    harness.send({ type: "set_bitrate", kbps: 3000 });
    harness.send({ type: "attach_preview", canvas: new FakeCanvas(10, 10).asOffscreen() });
    harness.scheduler.advance(1000);
    expect(harness.events.length).toBe(eventsAfter);
    expect(preview.context.calls).toEqual([]);
    expect(harness.scheduler.activeCount).toBe(0);
  });

  it("dispose を直接呼んでも同じ（何度呼んでもよい）", async () => {
    const harness = new HostHarness();
    harness.attachPreview();

    harness.host.dispose();
    harness.host.dispose();

    expect(harness.scheduler.activeCount).toBe(0);
  });
});

describe("診断と、機密の非出力", () => {
  it("故障は診断（ログ）に、符号と、元のエラーの名前だけを出す。エラーのメッセージ（デバイスの名前などを含み得る）は出さない", async () => {
    const harness = new HostHarness();
    const camera = harness.addSource("camera");
    await settle();

    camera.controller.error(new DOMException("Fake Camera 0 (usb-0000:00:14.0) failed", "AbortError"));
    await settle();

    const text = JSON.stringify(harness.diagnostics);
    expect(harness.diagnostics.some((entry) => entry.event === "fault")).toBe(true);
    expect(text).toContain("source_stream_failed");
    expect(text).toContain("AbortError");
    expect(text).not.toContain("Fake Camera");
    expect(text).not.toContain("usb-");
    expect(JSON.stringify(harness.eventsOf("fault"))).not.toContain("Fake Camera");
  });
});
