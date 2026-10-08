/**
 * @jest-environment node
 */
// sourceBridge（#26 の SourceChange を、パイプラインの映像ソースの追加・解除へ反映する薄い層。requirements.md 11.2・11.3・13.1。issue #27）。
//   - 取得済み（active）になった映像ソース（カメラ・画面共有）は、トラックをパイプラインへ追加する
//   - 取得済みでなくなった映像ソース（喪失・解除）は、パイプラインから外す。外すだけで、トラックは止めない（止めるのはマネージャ）
//   - それ以外の変化（要求中・拒否・取り消し）と、音声のソースは、何もしない
//   - レイアウトは、変化のあとの SourceChange.layout をそのまま返す（ここで解決し直さない）
import { FakeMediaDevices, FakeTrack } from "@/lib/sources/test-support";
import { SourceManager } from "@/lib/sources/SourceManager";
import type { ManagedSourceKind, SourceChange, SourceHandle } from "@/lib/sources/types";
import type { SourceState } from "@/core/contract";
import { applySourceChange } from "./sourceBridge";
import type { VideoSourceTarget } from "./sourceBridge";

interface Call {
  readonly method: "add" | "remove";
  readonly kind: string;
  readonly track?: MediaStreamTrack;
}

class RecordingTarget implements VideoSourceTarget {
  readonly calls: Call[] = [];
  failure: Error | null = null;

  addVideoSource(kind: "screen" | "camera", track: MediaStreamTrack): void {
    if (this.failure !== null) {
      throw this.failure;
    }
    this.calls.push({ method: "add", kind, track });
  }

  removeVideoSource(kind: "screen" | "camera"): void {
    if (this.failure !== null) {
      throw this.failure;
    }
    this.calls.push({ method: "remove", kind });
  }
}

function handle(kind: ManagedSourceKind, state: SourceState, track: MediaStreamTrack | null = null): SourceHandle {
  return Object.freeze({ kind, state, track, deviceId: null, label: null, reason: null });
}

function change(kind: ManagedSourceKind, previous: SourceState, current: SourceState, layout: SourceChange["layout"], track: MediaStreamTrack | null = null): SourceChange {
  return Object.freeze({ kind, previous: handle(kind, previous), current: handle(kind, current, track), layout, layoutChanged: true });
}

describe("映像ソースが取得済み（active）になった: トラックを追加する", () => {
  it.each(["camera", "screen"] as const)("%s: addVideoSource(kind, track)。結果は added で、レイアウトは SourceChange.layout", (kind) => {
    const target = new RecordingTarget();
    const track = new FakeTrack("video").asTrack();

    const result = applySourceChange(target, change(kind, "requesting", "active", kind === "camera" ? "camera_only" : "screen_only", track));

    expect(target.calls).toEqual([{ method: "add", kind, track }]);
    expect(result).toEqual({ outcome: "added", layout: kind === "camera" ? "camera_only" : "screen_only" });
  });

  it("取得済みなのにトラックが無い記録は、不整合なので RangeError（推測して続けない）。何も呼ばない", () => {
    const target = new RecordingTarget();

    expect(() => applySourceChange(target, change("camera", "requesting", "active", "camera_only", null))).toThrow(RangeError);
    expect(target.calls).toEqual([]);
  });

  it("パイプラインが拒否したら（終了済みのトラックなど）、そのまま伝える。握りつぶさない", () => {
    const target = new RecordingTarget();
    target.failure = new Error("pipeline refused");

    expect(() => applySourceChange(target, change("camera", "requesting", "active", "camera_only", new FakeTrack("video").asTrack()))).toThrow("pipeline refused");
  });
});

describe("映像ソースが取得済みでなくなった: パイプラインから外す（トラックは止めない）", () => {
  it.each([
    ["camera", "lost"],
    ["camera", "detached"],
    ["screen", "lost"],
    ["screen", "detached"],
  ] as const)("%s: active -> %s は removeVideoSource", (kind, next) => {
    const target = new RecordingTarget();

    const result = applySourceChange(target, change(kind, "active", next, "slate"));

    expect(target.calls).toEqual([{ method: "remove", kind }]);
    expect(result).toEqual({ outcome: "removed", layout: "slate" });
  });

  it("外すとき、トラックには触れない（止めるのはマネージャ。#26）", () => {
    const target = new RecordingTarget();
    const track = new FakeTrack("video");
    const lost = Object.freeze({ kind: "camera" as const, previous: handle("camera", "active", track.asTrack()), current: handle("camera", "lost"), layout: "slate" as const, layoutChanged: true });

    applySourceChange(target, lost);

    expect(track.stopCount).toBe(0);
    expect(track.readyState).toBe("live");
  });
});

describe("それ以外の変化と音声のソース: 何もしない", () => {
  it.each([
    ["detached", "requesting"],
    ["requesting", "denied"],
    ["requesting", "detached"],
    ["denied", "detached"],
    ["denied", "requesting"],
    ["lost", "requesting"],
    ["lost", "detached"],
  ] as const)("映像ソース: %s -> %s は unchanged（追加も解除もしない）", (previous, current) => {
    const target = new RecordingTarget();

    const result = applySourceChange(target, change("camera", previous, current, "slate"));

    expect(target.calls).toEqual([]);
    expect(result).toEqual({ outcome: "unchanged", layout: "slate" });
  });

  it.each(["microphone", "shared_audio"] as const)("%s は ignored（音声は、ミキサーが扱う）。active になっても追加しない", (kind) => {
    const target = new RecordingTarget();

    const result = applySourceChange(target, change(kind, "requesting", "active", "slate", new FakeTrack("audio").asTrack()));

    expect(target.calls).toEqual([]);
    expect(result.outcome).toBe("ignored");
  });

  it("知らない種別は RangeError（推測しない）", () => {
    const target = new RecordingTarget();
    const unknown = { ...change("camera", "requesting", "active", "slate"), kind: "projector" } as unknown as SourceChange;

    expect(() => applySourceChange(target, unknown)).toThrow(RangeError);
  });

  it("SourceChange を書き換えない（凍結されたままでも動く）", () => {
    const target = new RecordingTarget();
    const frozen = change("camera", "requesting", "active", "camera_only", new FakeTrack("video").asTrack());

    expect(() => applySourceChange(target, frozen)).not.toThrow();
    expect(Object.isFrozen(frozen)).toBe(true);
  });
});

describe("実際の SourceManager（疑似のデバイス）の変化に追従する", () => {
  it("カメラ -> 画面共有 -> 画面共有の終了 -> カメラの解除: 追加・解除と、レイアウトが、マネージャの変化どおり", async () => {
    const devices = new FakeMediaDevices();
    const errors: unknown[] = [];
    const manager = new SourceManager({ mediaDevices: devices.asMediaDevices(), onError: (error) => errors.push(error) });
    const target = new RecordingTarget();
    const observed: Array<{ kind: string; outcome: string; layout: string }> = [];
    manager.subscribe((sourceChange) => {
      const result = applySourceChange(target, sourceChange);
      observed.push({ kind: sourceChange.kind, outcome: result.outcome, layout: result.layout });
    });

    const camera = await manager.attach("camera");
    await manager.attach("screen");
    manager.onTrackEnded("screen");
    manager.detach("camera");

    expect(errors).toEqual([]);
    // 画面共有の取得は、共有音声も得るので、音声の変化（ignored）が混じる。映像の変化だけを見る
    const video = observed.filter((entry) => entry.kind === "camera" || entry.kind === "screen");
    expect(video).toEqual([
      { kind: "camera", outcome: "unchanged", layout: "slate" },
      { kind: "camera", outcome: "added", layout: "camera_only" },
      { kind: "screen", outcome: "unchanged", layout: "camera_only" },
      { kind: "screen", outcome: "added", layout: "screen_with_wipe" },
      { kind: "screen", outcome: "removed", layout: "camera_only" },
      { kind: "camera", outcome: "removed", layout: "slate" },
    ]);
    expect(observed.filter((entry) => entry.kind === "shared_audio").every((entry) => entry.outcome === "ignored")).toBe(true);
    expect(target.calls.map((call) => `${call.method}:${call.kind}`)).toEqual(["add:camera", "add:screen", "remove:screen", "remove:camera"]);
    // 追加したトラックは、マネージャが取得したもの（そのまま渡す）
    expect(camera.track).not.toBeNull();
    expect(target.calls[0].track).toBe(camera.track);
    manager.dispose();
  });
});
