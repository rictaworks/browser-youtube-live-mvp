// SourceManager（ソースの取得・解除・喪失の監視。requirements.md 11.2・13.1・16.2・25.5。issue #26）。
//   - 種別 4（カメラ・画面共有・マイク・共有音声）の状態（25.5）。状態の遷移は、core の transitionSource を使い、規則を重複して持たない
//   - 取得の制約（エコー除去・雑音抑制・画面共有は {video: true, audio: true}）。取得した音声を、再生へ接続しない（折り返し再生をしない）
//   - 画面共有は、利用者のクリックの直後に、最初の非同期呼び出しとして、直ちに getDisplayMedia を呼ぶ
//   - 拒否・取り消し・デバイスなし・その他（型付きのエラー）。トラックの終了で喪失（lost）へ。レイアウトを解決し直して通知する
//   - 配信中の追加・解除。再取得。デバイスの変更。デバイス名・ラベルを、診断へ出さない
//
// モックの境界: MediaDevices・MediaStream・MediaStreamTrack は、すべて疑似（test-support.ts）。実機のデバイスは、自動テストで使えない。
import fs from "node:fs";
import path from "node:path";
import type { SourceState } from "@/core/contract";
import { SourceError, isSourceError } from "./errors";
import type { SourceErrorCode } from "./errors";
import { SourceManager } from "./SourceManager";
import { FakeMediaDevices, FakeTrack, domError, flushPromises, pendingResponse, rejectWith, respondWith, streamOf } from "./test-support";
import type { ManagedSourceKind, SourceChange, SourceHandle } from "./types";
import { MANAGED_SOURCE_KINDS } from "./types";

interface Harness {
  readonly manager: SourceManager;
  readonly devices: FakeMediaDevices;
  readonly changes: SourceChange[];
  readonly errors: unknown[];
  readonly diagnostics: { event: string; fields: Record<string, unknown> }[];
}

function createHarness(devices: FakeMediaDevices = new FakeMediaDevices()): Harness {
  const changes: SourceChange[] = [];
  const errors: unknown[] = [];
  const diagnostics: { event: string; fields: Record<string, unknown> }[] = [];
  const manager = new SourceManager({
    mediaDevices: devices.asMediaDevices(),
    onError: (error) => errors.push(error),
    onDiagnostic: (event, fields) => diagnostics.push({ event, fields }),
  });
  manager.subscribe((change) => changes.push(change));
  return { manager, devices, changes, errors, diagnostics };
}

function statesOf(changes: readonly SourceChange[], kind: ManagedSourceKind): SourceState[] {
  return changes.filter((change) => change.kind === kind).map((change) => change.current.state);
}

function handleOf(harness: Harness, kind: ManagedSourceKind): SourceHandle {
  return harness.manager.getHandle(kind);
}

/** 失敗するはずの attach を待ち、投げられた SourceError を返す。 */
async function failureOf(promise: Promise<unknown>): Promise<SourceError> {
  try {
    await promise;
  } catch (error) {
    if (isSourceError(error)) {
      return error;
    }
    throw error;
  }
  throw new Error("attach was expected to fail");
}

describe("初期の状態", () => {
  it("4 種別すべてが、未取得（detached）。トラック・デバイス・ラベル・理由は無い。レイアウトは代替スレート", () => {
    const { manager } = createHarness();

    for (const kind of MANAGED_SOURCE_KINDS) {
      expect(manager.getHandle(kind)).toEqual({ kind, state: "detached", track: null, deviceId: null, label: null, reason: null });
    }
    expect(manager.layout).toBe("slate");
  });

  it("状態の記録は凍結されている。sources は、変化がない限り同じオブジェクト", () => {
    const { manager } = createHarness();

    expect(Object.isFrozen(manager.sources)).toBe(true);
    expect(Object.isFrozen(manager.getHandle("camera"))).toBe(true);
    expect(manager.sources).toBe(manager.sources);
    expect(manager.sources.camera).toBe(manager.getHandle("camera"));
  });

  it("画面共有 API（getDisplayMedia）があれば canShareScreen は真、無ければ偽", () => {
    expect(createHarness().manager.canShareScreen).toBe(true);
    expect(createHarness(new FakeMediaDevices({ displayMedia: false })).manager.canShareScreen).toBe(false);
  });

  it("構築しただけでは、デバイスの取得も一覧の取得も行わない", () => {
    const { devices } = createHarness();

    expect(devices.userMediaCalls).toEqual([]);
    expect(devices.displayMediaCalls).toEqual([]);
    expect(devices.enumerateCalls).toBe(0);
  });

  it("mediaDevices が無い（セキュアでない文脈では、navigator.mediaDevices が無い）構築は、原因が分かる TypeError。推測した動作で続けない", () => {
    expect(() => new SourceManager({ mediaDevices: undefined as never })).toThrow(/mediaDevices/);
    expect(() => new SourceManager({ mediaDevices: null as never })).toThrow(TypeError);
  });

  it("不明な種別は、推測せず RangeError（getHandle・detach・onTrackEnded）", () => {
    const { manager } = createHarness();

    expect(() => manager.getHandle("slate" as ManagedSourceKind)).toThrow(RangeError);
    expect(() => manager.detach("unknown" as ManagedSourceKind)).toThrow(RangeError);
    expect(() => manager.onTrackEnded("unknown" as ManagedSourceKind)).toThrow(RangeError);
  });
});

describe("カメラの取得", () => {
  it("要求中を経て取得済みになる。トラック・デバイスの識別子（トラックの設定から）・ラベルを持ち、レイアウトはカメラのみ", async () => {
    const harness = createHarness();

    const handle = await harness.manager.attach("camera", "DEVICE-cam-A");

    expect(statesOf(harness.changes, "camera")).toEqual(["requesting", "active"]);
    expect(harness.changes[0]).toMatchObject({ kind: "camera", layout: "slate", layoutChanged: false });
    expect(harness.changes[0].previous.state).toBe("detached");
    const track = harness.devices.createdTracks[0];
    expect(handle).toEqual({ kind: "camera", state: "active", track: track.asTrack(), deviceId: "DEVICE-cam-A", label: "LABEL-camera-DEVICE-cam-A", reason: null });
    expect(handle).toBe(harness.manager.getHandle("camera"));
    expect(harness.changes[1]).toMatchObject({ layout: "camera_only", layoutChanged: true });
    expect(harness.manager.layout).toBe("camera_only");
  });

  it("制約は getUserMedia({video: {deviceId: {exact}, ...}})（音声は要求しない）", async () => {
    const harness = createHarness();

    await harness.manager.attach("camera", "DEVICE-cam-A");

    expect(harness.devices.userMediaCalls).toHaveLength(1);
    expect(harness.devices.userMediaCalls[0].video).toMatchObject({ deviceId: { exact: "DEVICE-cam-A" } });
    expect(harness.devices.userMediaCalls[0]).not.toHaveProperty("audio");
    expect(harness.devices.displayMediaCalls).toEqual([]);
  });

  it("デバイスを指定しないときは、deviceId を制約に含めない（既定のデバイス）", async () => {
    const harness = createHarness();

    await harness.manager.attach("camera");

    expect(harness.devices.userMediaCalls[0].video).not.toHaveProperty("deviceId");
  });

  it("他の種別は変わらない。トラックの終了を監視している（購読者は 1 つ）", async () => {
    const harness = createHarness();

    await harness.manager.attach("camera");

    for (const kind of ["screen", "microphone", "shared_audio"] as const) {
      expect(handleOf(harness, kind).state).toBe("detached");
    }
    expect(harness.devices.createdTracks[0].endedListenerCount).toBe(1);
  });
});

describe("マイクの取得", () => {
  it("エコー除去と雑音抑制を適用して取得する（video は要求しない）", async () => {
    const harness = createHarness();

    await harness.manager.attach("microphone", "DEVICE-mic-A");

    const constraints = harness.devices.userMediaCalls[0];
    expect(constraints.audio).toMatchObject({ deviceId: { exact: "DEVICE-mic-A" }, echoCancellation: true, noiseSuppression: true });
    expect(constraints).not.toHaveProperty("video");
  });

  it("取得済みになる。映像ではないので、レイアウトは変わらない（代替スレートのまま）", async () => {
    const harness = createHarness();

    const handle = await harness.manager.attach("microphone");

    expect(handle.state).toBe("active");
    expect(handle.track).toBe(harness.devices.createdTracks[0].asTrack());
    expect(statesOf(harness.changes, "microphone")).toEqual(["requesting", "active"]);
    expect(harness.changes.every((change) => !change.layoutChanged)).toBe(true);
    expect(harness.manager.layout).toBe("slate");
  });

  it("取得した音声を、再生へ接続しない（SourceManager は、トラックを持つだけ。音声の出力先・要素を、作らない）", async () => {
    const harness = createHarness();

    await harness.manager.attach("microphone");

    // 折り返し再生をしないことは、ソースの静的な検査（audio-rules.test.ts）でも保証する。ここでは、トラックを読み出す操作だけが行われたことを確かめる
    expect(harness.devices.userMediaCalls).toHaveLength(1);
    expect(harness.devices.createdTracks[0].stopCount).toBe(0);
  });
});

describe("画面共有と共有音声", () => {
  it("getDisplayMedia({video: true, audio: true}) を 1 回呼び、画面共有と共有音声が取得済みになる。レイアウトは画面共有のみ", async () => {
    const harness = createHarness();

    const handle = await harness.manager.attach("screen");

    expect(harness.devices.displayMediaCalls).toEqual([{ video: true, audio: true }]);
    expect(harness.devices.userMediaCalls).toEqual([]);
    expect(handle.state).toBe("active");
    expect(handle.track).toBe(harness.devices.createdTracks[0].asTrack());
    expect(handle.deviceId).toBeNull();
    expect(handleOf(harness, "shared_audio")).toMatchObject({ state: "active", track: harness.devices.createdTracks[1].asTrack(), deviceId: null, reason: null });
    expect(statesOf(harness.changes, "screen")).toEqual(["requesting", "active"]);
    expect(statesOf(harness.changes, "shared_audio")).toEqual(["requesting", "active"]);
    expect(harness.manager.layout).toBe("screen_only");
  });

  it("音声トラックが無ければ、共有音声だけが未取得（detached）で、その理由（no_audio_track）を状態に持つ。画面共有は取得済み", async () => {
    const harness = createHarness(new FakeMediaDevices({ sharedAudio: false }));

    const handle = await harness.manager.attach("screen");

    expect(handle.state).toBe("active");
    expect(handleOf(harness, "shared_audio")).toEqual({ kind: "shared_audio", state: "detached", track: null, deviceId: null, label: null, reason: "no_audio_track" });
    expect(statesOf(harness.changes, "shared_audio")).toEqual(["requesting", "detached"]);
  });

  it("カメラがあるとき、画面共有を主映像・カメラをワイプにするレイアウトへ解決し直す", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera");

    await harness.manager.attach("screen");

    expect(harness.manager.layout).toBe("screen_with_wipe");
    const screenActive = harness.changes.find((change) => change.kind === "screen" && change.current.state === "active");
    expect(screenActive).toMatchObject({ layout: "screen_with_wipe", layoutChanged: true });
  });

  describe("一時的なアクティベーション（クリック等）の直後の、最初の非同期呼び出し", () => {
    it("attach を呼んだ時点（同期）で、getDisplayMedia が呼ばれている（await の前に、他の非同期処理を挟まない）", async () => {
      const harness = createHarness();

      const attached = harness.manager.attach("screen");

      expect(harness.devices.displayMediaCalls).toHaveLength(1);
      await attached;
    });

    it("クリックのハンドラの中で呼べば、操作が必要な環境（疑似）でも成功する", async () => {
      const harness = createHarness();
      harness.devices.activation.required = true;
      let attached: Promise<SourceHandle> = Promise.reject(new Error("not called"));
      attached.catch(() => undefined);

      harness.devices.click(() => {
        attached = harness.manager.attach("screen");
      });

      expect((await attached).state).toBe("active");
    });

    it("購読者が、要求中への変化の通知で例外を投げても、getDisplayMedia の呼び出しは妨げられない", async () => {
      const harness = createHarness();
      harness.devices.activation.required = true;
      const failure = new Error("subscriber failure");
      harness.manager.subscribe(() => {
        throw failure;
      });
      let attached: Promise<SourceHandle> = Promise.reject(new Error("not called"));
      attached.catch(() => undefined);

      harness.devices.click(() => {
        attached = harness.manager.attach("screen");
      });

      expect((await attached).state).toBe("active");
      expect(harness.errors).toContain(failure);
    });

    it("操作の外（await のあと・タイマ）で呼ぶと、InvalidStateError で、型付きのエラー（invalid_state）。状態は未取得へ戻る", async () => {
      const harness = createHarness();
      harness.devices.activation.required = true;

      const error = await failureOf(harness.manager.attach("screen"));

      expect(error.code).toBe("invalid_state");
      expect(error.kind).toBe("screen");
      expect(error.errorName).toBe("InvalidStateError");
      expect(handleOf(harness, "screen")).toMatchObject({ state: "detached", reason: "request_failed" });
      expect(handleOf(harness, "shared_audio")).toMatchObject({ state: "detached", reason: "request_failed" });
    });
  });

  it("画面共有 API が無い環境では、画面共有の操作のみ提供しない（unsupported。状態は変わらず、API も呼ばない）", async () => {
    const harness = createHarness(new FakeMediaDevices({ displayMedia: false }));

    const error = await failureOf(harness.manager.attach("screen"));

    expect(error.code).toBe("unsupported");
    expect(harness.changes).toEqual([]);
    await harness.manager.attach("camera");
    expect(handleOf(harness, "camera").state).toBe("active");
  });

  it("共有音声だけを単独で取得することはできない（画面共有の取得で得る）。状態を変えず、API も呼ばない", async () => {
    const harness = createHarness();

    const error = await failureOf(harness.manager.attach("shared_audio"));

    expect(error.code).toBe("shared_audio_requires_screen");
    expect(harness.changes).toEqual([]);
    expect(harness.devices.userMediaCalls).toEqual([]);
    expect(harness.devices.displayMediaCalls).toEqual([]);
  });

  it("画面共有に deviceId は指定できない（呼び出しの誤りなので RangeError）。不明な種別も RangeError", async () => {
    const harness = createHarness();

    await expect(harness.manager.attach("screen", "DEVICE-x")).rejects.toThrow(RangeError);
    await expect(harness.manager.attach("slate" as ManagedSourceKind)).rejects.toThrow(RangeError);
    expect(harness.changes).toEqual([]);
  });
});

describe("拒否・取り消し・デバイスなし・その他", () => {
  interface OutcomeCase {
    readonly name: string;
    readonly kind: "camera" | "microphone" | "screen";
    readonly error: unknown;
    readonly state: SourceState;
    readonly reason: string;
    readonly code?: SourceErrorCode;
  }

  const OUTCOMES: readonly OutcomeCase[] = [
    { name: "カメラの権限の拒否", kind: "camera", error: domError("NotAllowedError"), state: "denied", reason: "permission_denied" },
    { name: "マイクの権限の拒否", kind: "microphone", error: domError("NotAllowedError"), state: "denied", reason: "permission_denied" },
    { name: "画面共有の選択の取り消し（拒否と区別できない）は、未取得へ戻す", kind: "screen", error: domError("NotAllowedError"), state: "detached", reason: "selection_cancelled" },
    { name: "カメラが無い", kind: "camera", error: domError("NotFoundError"), state: "detached", reason: "device_not_found" },
    { name: "マイクが無い", kind: "microphone", error: domError("NotFoundError"), state: "detached", reason: "device_not_found" },
    { name: "指定したマイクの識別子が無い", kind: "microphone", error: domError("OverconstrainedError", { constraint: "deviceId" }), state: "detached", reason: "device_not_found" },
    { name: "共有できる画面が無い", kind: "screen", error: domError("NotFoundError"), state: "detached", reason: "device_not_found" },
    { name: "カメラを読み取れない", kind: "camera", error: domError("NotReadableError"), state: "detached", reason: "request_failed", code: "not_readable" },
    { name: "画面共有の NotReadableError", kind: "screen", error: domError("NotReadableError"), state: "detached", reason: "request_failed", code: "not_readable" },
    { name: "マイクの取得の中断", kind: "microphone", error: domError("AbortError"), state: "detached", reason: "request_failed", code: "aborted" },
    { name: "画面共有の NotSupportedError", kind: "screen", error: domError("NotSupportedError"), state: "detached", reason: "request_failed", code: "unsupported" },
    { name: "カメラの想定外のエラー", kind: "camera", error: new TypeError("bad"), state: "detached", reason: "request_failed", code: "unexpected" },
    { name: "画面共有の InvalidStateError", kind: "screen", error: domError("InvalidStateError"), state: "detached", reason: "request_failed", code: "invalid_state" },
  ];

  it.each(OUTCOMES)("$name", async (outcome) => {
    const harness = createHarness();
    const behavior = rejectWith(outcome.error);
    if (outcome.kind === "screen") {
      harness.devices.queueDisplayMedia(behavior);
    } else {
      harness.devices.queueUserMedia(behavior);
    }

    const attempt = harness.manager.attach(outcome.kind);

    if (outcome.code === undefined) {
      const handle = await attempt;
      expect(handle).toMatchObject({ kind: outcome.kind, state: outcome.state, reason: outcome.reason, track: null });
    } else {
      const error = await failureOf(attempt);
      expect(error.code).toBe(outcome.code);
      expect(error.kind).toBe(outcome.kind);
    }
    expect(handleOf(harness, outcome.kind)).toMatchObject({ state: outcome.state, reason: outcome.reason, track: null, deviceId: null, label: null });
    expect(statesOf(harness.changes, outcome.kind)).toEqual(["requesting", outcome.state]);
    if (outcome.kind === "screen") {
      expect(handleOf(harness, "shared_audio")).toMatchObject({ state: "detached", reason: outcome.reason });
    }
  });

  it("エラーの文面（デバイス名を含み得る）を、SourceError のメッセージ・診断へ出さない", async () => {
    const harness = createHarness();
    harness.devices.queueUserMedia(rejectWith(domError("NotReadableError", {}, "Could not start LABEL-SECRET device")));

    const error = await failureOf(harness.manager.attach("camera", "DEVICE-secret-id"));

    expect(error.message).not.toContain("LABEL-");
    expect(JSON.stringify(harness.diagnostics)).not.toContain("DEVICE-secret-id");
  });

  it("拒否のあとの再要求（denied -> requesting -> active）", async () => {
    const harness = createHarness();
    harness.devices.queueUserMedia(rejectWith(domError("NotAllowedError")));
    await harness.manager.attach("camera");
    expect(handleOf(harness, "camera").state).toBe("denied");

    await harness.manager.attach("camera");

    expect(statesOf(harness.changes, "camera")).toEqual(["requesting", "denied", "requesting", "active"]);
  });

  it("権限がすべて拒否された状態でも、例外にならず、レイアウトは代替スレート（プレビューと配信の開始が成立する）", async () => {
    const harness = createHarness();
    harness.devices.queueUserMedia(rejectWith(domError("NotAllowedError")), rejectWith(domError("NotAllowedError")));
    harness.devices.queueDisplayMedia(rejectWith(domError("NotAllowedError")));

    await harness.manager.attach("camera");
    await harness.manager.attach("microphone");
    await harness.manager.attach("screen");

    expect(harness.manager.layout).toBe("slate");
    expect(handleOf(harness, "camera").state).toBe("denied");
    expect(handleOf(harness, "microphone").state).toBe("denied");
    expect(handleOf(harness, "screen").state).toBe("detached");
  });

  it("取得に成功しても、期待したトラックが無いストリームは、no_track。ストリームのトラックを止め、未取得へ戻す", async () => {
    const harness = createHarness();
    const audioOnly = new FakeTrack("audio");
    harness.devices.queueUserMedia(respondWith(audioOnly));

    const error = await failureOf(harness.manager.attach("camera"));

    expect(error.code).toBe("no_track");
    expect(audioOnly.stopCount).toBe(1);
    expect(handleOf(harness, "camera")).toMatchObject({ state: "detached", reason: "request_failed" });
  });
});

describe("トラックの終了（喪失）", () => {
  it("カメラのトラックが終了したら、喪失（lost）。デバイス・ラベルは残し、トラックは持たない。レイアウトを解決し直して通知する", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera", "DEVICE-cam-A");
    harness.changes.length = 0;

    harness.devices.createdTracks[0].end();

    expect(handleOf(harness, "camera")).toEqual({ kind: "camera", state: "lost", track: null, deviceId: "DEVICE-cam-A", label: "LABEL-camera-DEVICE-cam-A", reason: "track_ended" });
    expect(harness.changes).toHaveLength(1);
    expect(harness.changes[0]).toMatchObject({ kind: "camera", layout: "slate", layoutChanged: true });
    expect(harness.changes[0].previous.state).toBe("active");
    expect(harness.manager.layout).toBe("slate");
  });

  it("終了したトラックの購読を解除する。映像が止まったまま継続する状態を作らない（レイアウトから外れる）", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera");
    await harness.manager.attach("screen");
    expect(harness.manager.layout).toBe("screen_with_wipe");

    harness.devices.createdTracks[0].end();

    expect(harness.devices.createdTracks[0].endedListenerCount).toBe(0);
    expect(harness.manager.layout).toBe("screen_only");
  });

  it("画面共有の終了は、共有音声も喪失にする（画面共有が先に通知され、レイアウトは、そのあと解決し直される）", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera");
    await harness.manager.attach("screen");
    harness.changes.length = 0;

    harness.devices.createdTracks[1].end();

    expect(harness.changes.map((change) => [change.kind, change.current.state, change.layout])).toEqual([
      ["screen", "lost", "camera_only"],
      ["shared_audio", "lost", "camera_only"],
    ]);
    expect(handleOf(harness, "shared_audio")).toMatchObject({ state: "lost", track: null, reason: "track_ended" });
    expect(harness.devices.createdTracks[2].stopCount).toBeGreaterThan(0);
  });

  it("共有音声のトラックだけが終了したときは、共有音声だけが喪失。画面共有は取得済みのまま", async () => {
    const harness = createHarness();
    await harness.manager.attach("screen");

    harness.devices.createdTracks[1].end();

    expect(handleOf(harness, "shared_audio").state).toBe("lost");
    expect(handleOf(harness, "screen").state).toBe("active");
    expect(harness.manager.layout).toBe("screen_only");
  });

  it("共有音声が無い（未取得）とき、画面共有の終了では、共有音声は未取得のまま", async () => {
    const harness = createHarness(new FakeMediaDevices({ sharedAudio: false }));
    await harness.manager.attach("screen");

    harness.devices.createdTracks[0].end();

    expect(handleOf(harness, "screen").state).toBe("lost");
    expect(handleOf(harness, "shared_audio")).toMatchObject({ state: "detached", reason: "no_audio_track" });
  });

  it("マイクのトラックが終了したら、マイクが喪失（混合対象から外す通知になる）", async () => {
    const harness = createHarness();
    await harness.manager.attach("microphone");

    harness.devices.createdTracks[0].end();

    expect(handleOf(harness, "microphone")).toMatchObject({ state: "lost", track: null, reason: "track_ended" });
  });

  it("onTrackEnded を直接呼んでも、取得済みのソースだけが喪失になる（未取得・喪失・拒否では、何も起きない）", async () => {
    const harness = createHarness();
    harness.manager.onTrackEnded("camera");
    expect(harness.changes).toEqual([]);

    await harness.manager.attach("camera");
    harness.changes.length = 0;
    harness.manager.onTrackEnded("camera");
    harness.manager.onTrackEnded("camera");

    expect(statesOf(harness.changes, "camera")).toEqual(["lost"]);
    expect(harness.devices.createdTracks[0].stopCount).toBeGreaterThan(0);
  });

  it("許可された時点で、すでに終了しているトラックは、ended が来ないので、取得済みを経て、すぐに喪失にする（取得済みのまま止まらない）", async () => {
    const harness = createHarness();
    const dead = new FakeTrack("video", { deviceId: "DEVICE-cam-A" });
    dead.stop();
    harness.devices.queueUserMedia(respondWith(dead));

    const handle = await harness.manager.attach("camera");

    expect(statesOf(harness.changes, "camera")).toEqual(["requesting", "active", "lost"]);
    expect(handle).toBe(harness.manager.getHandle("camera"));
    expect(handle.state).toBe("lost");
    expect(dead.endedListenerCount).toBe(0);
  });

  it("喪失から再取得（lost -> requesting -> active）。新しいトラックを持つ", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera");
    harness.devices.createdTracks[0].end();

    const handle = await harness.manager.attach("camera");

    expect(statesOf(harness.changes, "camera")).toEqual(["requesting", "active", "lost", "requesting", "active"]);
    expect(handle.track).toBe(harness.devices.createdTracks[1].asTrack());
    expect(harness.manager.layout).toBe("camera_only");
  });

  it("画面共有の喪失からの再取得は、共有音声も、喪失から取得済みへ", async () => {
    const harness = createHarness();
    await harness.manager.attach("screen");
    harness.devices.createdTracks[0].end();

    await harness.manager.attach("screen");

    expect(statesOf(harness.changes, "screen")).toEqual(["requesting", "active", "lost", "requesting", "active"]);
    expect(statesOf(harness.changes, "shared_audio")).toEqual(["requesting", "active", "lost", "requesting", "active"]);
  });
});

describe("解除（detach）", () => {
  it("取得済みを解除すると、トラックを止め、購読を解除して、未取得へ（理由: released。デバイス・ラベルは残さない）", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera", "DEVICE-cam-A");
    const track = harness.devices.createdTracks[0];

    const handle = harness.manager.detach("camera");

    expect(handle).toEqual({ kind: "camera", state: "detached", track: null, deviceId: null, label: null, reason: "released" });
    expect(track.stopCount).toBe(1);
    expect(track.endedListenerCount).toBe(0);
    expect(harness.manager.layout).toBe("slate");
  });

  it("解除したあとに、古いトラックが終了しても、状態は変わらない", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera");
    harness.manager.detach("camera");
    harness.changes.length = 0;

    harness.devices.createdTracks[0].end();

    expect(harness.changes).toEqual([]);
    expect(handleOf(harness, "camera").state).toBe("detached");
  });

  it("喪失・拒否も、解除で未取得へ。未取得の解除は、何も起きない（通知しない）", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera");
    harness.devices.createdTracks[0].end();
    harness.devices.queueUserMedia(rejectWith(domError("NotAllowedError")));
    await harness.manager.attach("microphone");
    harness.changes.length = 0;

    harness.manager.detach("camera");
    harness.manager.detach("microphone");
    harness.manager.detach("camera");

    expect(statesOf(harness.changes, "camera")).toEqual(["detached"]);
    expect(statesOf(harness.changes, "microphone")).toEqual(["detached"]);
  });

  it("画面共有の解除は、共有音声も解除する（どちらのトラックも止める）", async () => {
    const harness = createHarness();
    await harness.manager.attach("screen");

    harness.manager.detach("screen");

    expect(harness.devices.createdTracks.map((track) => track.stopCount)).toEqual([1, 1]);
    expect(handleOf(harness, "screen").state).toBe("detached");
    expect(handleOf(harness, "shared_audio")).toMatchObject({ state: "detached", reason: "released" });
  });

  it("共有音声だけの解除は、音声のトラックだけを止める。画面共有は取得済みのまま", async () => {
    const harness = createHarness();
    await harness.manager.attach("screen");

    harness.manager.detach("shared_audio");

    expect(harness.devices.createdTracks.map((track) => track.stopCount)).toEqual([0, 1]);
    expect(handleOf(harness, "screen").state).toBe("active");
    expect(handleOf(harness, "shared_audio").state).toBe("detached");
  });
});

describe("配信中の追加・解除（ストリームを再生成せず、構成の変化を通知する）", () => {
  it("あとからカメラを足す・外すと、そのたびにレイアウトが解決し直されて通知される（他のソースのトラックは、止めない）", async () => {
    const harness = createHarness();
    await harness.manager.attach("screen");
    const screenTrack = harness.devices.createdTracks[0];
    harness.changes.length = 0;

    await harness.manager.attach("camera");
    harness.manager.detach("camera");

    expect(harness.changes.map((change) => [change.kind, change.current.state, change.layout])).toEqual([
      ["camera", "requesting", "screen_only"],
      ["camera", "active", "screen_with_wipe"],
      ["camera", "detached", "screen_only"],
    ]);
    expect(screenTrack.stopCount).toBe(0);
    expect(handleOf(harness, "screen").track).toBe(screenTrack.asTrack());
  });
});

describe("要求中の扱い", () => {
  it("要求中にもう一度 attach しても、新しい要求を出さず、同じ結果になる", async () => {
    const harness = createHarness();
    const pending = pendingResponse();
    harness.devices.queueUserMedia(pending.behavior);

    const first = harness.manager.attach("camera");
    const second = harness.manager.attach("camera");
    expect(harness.devices.userMediaCalls).toHaveLength(1);
    pending.response.resolve(streamOf(new FakeTrack("video", { deviceId: "DEVICE-cam-A" })));
    const [firstHandle, secondHandle] = await Promise.all([first, second]);

    expect(firstHandle.state).toBe("active");
    expect(secondHandle).toBe(firstHandle);
    expect(harness.devices.userMediaCalls).toHaveLength(1);
  });

  it("要求中に解除すると、すぐに未取得へ戻る。あとから許可されたストリームは、トラックを止めて捨てる（状態は変わらない）", async () => {
    const harness = createHarness();
    const pending = pendingResponse();
    harness.devices.queueUserMedia(pending.behavior);
    const attempt = harness.manager.attach("camera");
    expect(handleOf(harness, "camera").state).toBe("requesting");

    harness.manager.detach("camera");
    expect(handleOf(harness, "camera")).toMatchObject({ state: "detached", reason: "released" });
    const late = new FakeTrack("video");
    pending.response.resolve(streamOf(late));
    const result = await attempt;

    expect(late.stopCount).toBe(1);
    expect(late.endedListenerCount).toBe(0);
    expect(result.state).toBe("detached");
    expect(handleOf(harness, "camera").track).toBeNull();
  });

  it("取り消した古い要求が、あとから終わっても、新しい要求の状態を壊さない", async () => {
    const harness = createHarness();
    const older = pendingResponse();
    const newer = pendingResponse();
    harness.devices.queueUserMedia(older.behavior, newer.behavior);
    const olderAttempt = harness.manager.attach("camera");
    harness.manager.detach("camera");
    const newerAttempt = harness.manager.attach("camera");
    const staleTrack = new FakeTrack("video");
    const freshTrack = new FakeTrack("video", { deviceId: "DEVICE-cam-B" });

    older.response.resolve(streamOf(staleTrack));
    await olderAttempt;

    expect(staleTrack.stopCount).toBe(1);
    expect(handleOf(harness, "camera").state).toBe("requesting");
    newer.response.resolve(streamOf(freshTrack));
    const handle = await newerAttempt;
    expect(handle).toMatchObject({ state: "active", deviceId: "DEVICE-cam-B" });
    expect(freshTrack.stopCount).toBe(0);
  });

  it("取り消した古い要求が、あとから失敗しても、状態を変えず、エラーも投げない", async () => {
    const harness = createHarness();
    const pending = pendingResponse();
    harness.devices.queueUserMedia(pending.behavior);
    const attempt = harness.manager.attach("microphone");
    harness.manager.detach("microphone");

    pending.response.reject(domError("NotReadableError"));

    await expect(attempt).resolves.toMatchObject({ state: "detached", reason: "released" });
  });

  it("画面共有の要求中に解除すると、画面共有と共有音声が、すぐに未取得へ戻る。あとから許可された両方のトラックを止める", async () => {
    const harness = createHarness();
    const pending = pendingResponse();
    harness.devices.queueDisplayMedia(pending.behavior);
    const attempt = harness.manager.attach("screen");
    const video = new FakeTrack("video");
    const audio = new FakeTrack("audio");

    harness.manager.detach("screen");
    pending.response.resolve(streamOf(video, audio));
    await attempt;

    expect([video.stopCount, audio.stopCount]).toEqual([1, 1]);
    expect(handleOf(harness, "screen").state).toBe("detached");
    expect(handleOf(harness, "shared_audio").state).toBe("detached");
  });

  it("画面共有の要求中に、共有音声だけを解除すると、画面共有は取得済みになり、音声のトラックは止められる", async () => {
    const harness = createHarness();
    const pending = pendingResponse();
    harness.devices.queueDisplayMedia(pending.behavior);
    const attempt = harness.manager.attach("screen");
    const video = new FakeTrack("video");
    const audio = new FakeTrack("audio");

    harness.manager.detach("shared_audio");
    pending.response.resolve(streamOf(video, audio));
    await attempt;

    expect(handleOf(harness, "screen")).toMatchObject({ state: "active", track: video.asTrack() });
    expect(handleOf(harness, "shared_audio").state).toBe("detached");
    expect([video.stopCount, audio.stopCount]).toEqual([0, 1]);
  });
});

describe("デバイスの変更", () => {
  it("取得済みのカメラを、別のデバイスで attach すると、古いトラックを止めて、新しいデバイスで取得し直す", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera", "DEVICE-cam-A");
    const first = harness.devices.createdTracks[0];

    const handle = await harness.manager.attach("camera", "DEVICE-cam-B");

    expect(first.stopCount).toBe(1);
    expect(harness.devices.userMediaCalls).toHaveLength(2);
    expect(harness.devices.userMediaCalls[1].video).toMatchObject({ deviceId: { exact: "DEVICE-cam-B" } });
    expect(handle).toMatchObject({ state: "active", deviceId: "DEVICE-cam-B" });
    expect(statesOf(harness.changes, "camera")).toEqual(["requesting", "active", "detached", "requesting", "active"]);
  });

  it("同じデバイス・デバイスの指定なしの attach は、取得済みの状態を、そのまま返す（新しい要求を出さない）", async () => {
    const harness = createHarness();
    const first = await harness.manager.attach("camera", "DEVICE-cam-A");

    const same = await harness.manager.attach("camera", "DEVICE-cam-A");
    const unspecified = await harness.manager.attach("camera");

    expect(same).toBe(first);
    expect(unspecified).toBe(first);
    expect(harness.devices.userMediaCalls).toHaveLength(1);
  });

  it("識別子が空文字列（権限の取得前の一覧の値）の attach は、デバイスの指定なしとして扱う", async () => {
    const harness = createHarness();

    await harness.manager.attach("microphone", "");

    expect(harness.devices.userMediaCalls[0].audio).not.toHaveProperty("deviceId");
  });
});

describe("デバイスの一覧との連携", () => {
  it("取得に成功したら、一覧を取得し直す（ラベルは、権限の取得後にのみ得られるため）", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = [{ kind: "videoinput", deviceId: "DEVICE-cam-A", label: "LABEL-cam-A", groupId: "g" }];
    const harness = createHarness(devices);

    await harness.manager.attach("camera");
    await flushPromises();

    expect(devices.enumerateCalls).toBe(1);
    expect(harness.manager.devices.snapshot.cameras).toEqual([{ kind: "camera", deviceId: "DEVICE-cam-A", label: "LABEL-cam-A" }]);
  });

  it("拒否・失敗のときは、一覧を取得し直さない", async () => {
    const harness = createHarness();
    harness.devices.queueUserMedia(rejectWith(domError("NotAllowedError")));

    await harness.manager.attach("camera");
    await flushPromises();

    expect(harness.devices.enumerateCalls).toBe(0);
  });

  it("devicechange（デバイスの抜き差し）で、一覧を更新する。更新の失敗は、例外の処理へ渡す", async () => {
    const devices = new FakeMediaDevices();
    const harness = createHarness(devices);
    devices.changeDevices([{ kind: "audioinput", deviceId: "DEVICE-mic-A", label: "LABEL-mic-A", groupId: "g" }]);
    await flushPromises();
    expect(harness.manager.devices.snapshot.microphones).toHaveLength(1);

    const failure = new Error("enumerate failed");
    devices.enumerateError = failure;
    devices.changeDevices();
    await flushPromises();

    expect(harness.errors).toEqual([failure]);
  });
});

describe("購読", () => {
  it("購読を解除すると、通知されない", async () => {
    const harness = createHarness();
    const listener = jest.fn();
    const unsubscribe = harness.manager.subscribe(listener);

    unsubscribe();
    await harness.manager.attach("camera");

    expect(listener).not.toHaveBeenCalled();
  });

  it("購読者の例外は、他の購読者・取得の処理を止めず、例外の処理へ渡す", async () => {
    const harness = createHarness();
    const failure = new Error("subscriber failure");
    harness.manager.subscribe(() => {
      throw failure;
    });
    const after = jest.fn();
    harness.manager.subscribe(after);

    const handle = await harness.manager.attach("camera");

    expect(handle.state).toBe("active");
    expect(after).toHaveBeenCalledTimes(2);
    expect(harness.errors).toEqual([failure, failure]);
  });
});

describe("状態遷移（25.5 の矢印をすべて）", () => {
  it("Detached->Requesting->Active->Detached・Requesting->Denied->Requesting・Requesting->Detached・Active->Lost->Requesting・Lost->Detached・Denied->Detached", async () => {
    const harness = createHarness();
    const all = (): SourceState => handleOf(harness, "camera").state;
    const seen: SourceState[] = [all()];
    harness.manager.subscribe((change) => {
      if (change.kind === "camera") {
        seen.push(change.current.state);
      }
    });

    await harness.manager.attach("camera"); // detached -> requesting -> active
    harness.manager.detach("camera"); // active -> detached
    harness.devices.queueUserMedia(rejectWith(domError("NotAllowedError")));
    await harness.manager.attach("camera"); // detached -> requesting -> denied
    harness.devices.queueUserMedia(rejectWith(domError("NotFoundError")));
    await harness.manager.attach("camera"); // denied -> requesting -> detached（選択の取り消し・デバイスなし）
    await harness.manager.attach("camera"); // detached -> requesting -> active
    harness.devices.createdTracks[harness.devices.createdTracks.length - 1].end(); // active -> lost
    harness.manager.detach("camera"); // lost -> detached
    harness.devices.queueUserMedia(rejectWith(domError("NotAllowedError")));
    await harness.manager.attach("camera"); // detached -> requesting -> denied
    harness.manager.detach("camera"); // denied -> detached
    await harness.manager.attach("camera"); // detached -> requesting -> active
    harness.devices.createdTracks[harness.devices.createdTracks.length - 1].end(); // active -> lost
    await harness.manager.attach("camera"); // lost -> requesting -> active

    expect(seen).toEqual([
      "detached",
      "requesting",
      "active",
      "detached",
      "requesting",
      "denied",
      "requesting",
      "detached",
      "requesting",
      "active",
      "lost",
      "detached",
      "requesting",
      "denied",
      "detached",
      "requesting",
      "active",
      "lost",
      "requesting",
      "active",
    ]);
  });

  it("要求中の解除（Requesting->Detached。選択の取り消し）も、通知される", async () => {
    const harness = createHarness();
    harness.devices.queueUserMedia(pendingResponse().behavior);
    const attempt = harness.manager.attach("camera");
    attempt.catch(() => undefined);

    harness.manager.detach("camera");

    expect(statesOf(harness.changes, "camera")).toEqual(["requesting", "detached"]);
  });
});

describe("破棄（dispose）", () => {
  it("すべてのトラックを止めて、未取得へ戻す。デバイスの変更の監視も止める。以後の attach は、disposed", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera");
    await harness.manager.attach("screen");
    const tracks = [...harness.devices.createdTracks];

    harness.manager.dispose();

    expect(tracks.map((track) => track.stopCount)).toEqual([1, 1, 1]);
    for (const kind of MANAGED_SOURCE_KINDS) {
      expect(handleOf(harness, kind).state).toBe("detached");
    }
    harness.devices.changeDevices([]);
    await flushPromises();
    expect(harness.devices.enumerateCalls).toBe(1);
    expect((await failureOf(harness.manager.attach("camera"))).code).toBe("disposed");
  });

  it("要求中に破棄すると、あとから許可されたトラックを、止めて捨てる（カメラの使用中の表示を残さない）", async () => {
    const harness = createHarness();
    const pending = pendingResponse();
    harness.devices.queueUserMedia(pending.behavior);
    const attempt = harness.manager.attach("camera");
    const late = new FakeTrack("video");

    harness.manager.dispose();
    pending.response.resolve(streamOf(late));
    await attempt;

    expect(late.stopCount).toBe(1);
    expect(handleOf(harness, "camera").state).toBe("detached");
  });

  it("破棄のあとの、購読・解除・トラックの終了は、何も起こさない", async () => {
    const harness = createHarness();
    await harness.manager.attach("microphone");
    const track = harness.devices.createdTracks[0];
    harness.manager.dispose();
    harness.changes.length = 0;

    track.end();
    harness.manager.detach("microphone");
    harness.manager.dispose();

    expect(harness.changes).toEqual([]);
  });
});

describe("診断（デバイス名・ラベル・識別子を、ログへ出さない）", () => {
  it("状態の変化・失敗が、種別と符号で追える。ラベルとデバイスの識別子は、含まれない", async () => {
    const harness = createHarness();
    await harness.manager.attach("camera", "DEVICE-secret-cam");
    await harness.manager.attach("microphone", "DEVICE-secret-mic");
    await harness.manager.attach("screen");
    harness.devices.createdTracks[0].end();
    harness.devices.queueUserMedia(rejectWith(domError("NotReadableError")));
    await failureOf(harness.manager.attach("camera"));
    harness.manager.detach("microphone");

    const text = JSON.stringify(harness.diagnostics);
    expect(text).not.toContain("LABEL-");
    expect(text).not.toContain("DEVICE-");
    const events = harness.diagnostics.map((entry) => entry.event);
    expect(events).toEqual(expect.arrayContaining(["source_state", "source_failed"]));
    expect(harness.diagnostics.find((entry) => entry.event === "source_state")?.fields).toEqual({ kind: "camera", from: "detached", to: "requesting", reason: null });
    expect(harness.diagnostics.find((entry) => entry.event === "source_failed")?.fields).toEqual({ kind: "camera", code: "not_readable", errorName: "NotReadableError" });
  });
});

describe("実装の方針", () => {
  it("遷移の規則は、core の transitionSource を使う（このクラスに、状態ごとの遷移の表を持たない）", () => {
    const source = fs.readFileSync(path.resolve(__dirname, "SourceManager.ts"), "utf8");

    expect(source).toContain("transitionSource");
    expect(source).not.toMatch(/\b(detached|requesting|active|denied|lost)\s*:\s*\{/);
  });
});
