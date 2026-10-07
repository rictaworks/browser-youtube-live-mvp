// SourceManager（requirements.md 11.2・13.1・16.2・25.5。issue #26）。カメラ・画面共有・マイク・共有音声の、取得・解除・喪失の監視。
//
// 状態（未取得・要求中・取得済み・拒否・喪失）の遷移は、core の transitionSource を使う（遷移の規則を、ここで重複して持たない）。
// 状態が変わるたびに、購読者へ SourceChange を通知する。通知には、変化のあとのレイアウト（core の resolveLayout。11.3）が付く。
// 合成（#27）と混合（lib/audio の AudioMixer。bindSourcesToMixer が接続する）は、この通知で、追加・解除・喪失を知る（ストリームを再生成しない）。
//
// 取得
//   カメラ  getUserMedia({video: {deviceId: {exact}, ...}})
//   マイク  getUserMedia({audio: {deviceId: {exact}, echoCancellation: true, noiseSuppression: true}})。取得した音声を、再生（<audio>・出力先）へ
//           接続しない（配信者自身への折り返し再生をしない。このクラスは、トラックを持つだけで、音声の出力に関わらない）
//   画面共有と共有音声  getDisplayMedia({video: true, audio: true}) を 1 回。共有音声は、同じ取得の音声トラック。音声トラックが無ければ、共有音声だけが
//           未取得（理由 no_audio_track）。共有音声を単独で取得することはできない（attach("shared_audio") は、型付きのエラー）
//   getDisplayMedia は、利用者のクリック等（一時的なアクティベーション）の直後でなければ、InvalidStateError になる。
//   attach("screen") は、その前に await を挟まず、呼び出し（同期）の中で、最初に getDisplayMedia を呼ぶ。購読者の例外は隔離する（Emitter）ため、
//   状態の変化の通知（同期）で例外が起きても、getDisplayMedia の呼び出しは妨げられない
//
// 失敗の扱い
//   getUserMedia の NotAllowedError = 拒否（denied）
//   getDisplayMedia の NotAllowedError = 拒否と選択の取り消しの両方。ブラウザが区別できないため、拒否と決めつけず、画面共有・共有音声を未取得（detached）へ
//     戻す（権限の拒否として扱うのは、getUserMedia だけ）
//   NotFoundError・指定したデバイスの識別子が無い = 未取得 + 理由 device_not_found
//   その他 = 型付きのエラー（SourceError）。状態は、未取得（理由 request_failed）へ戻す（要求中のまま残さない）
//   権限がすべて拒否された状態でも、例外にならない（レイアウトは代替スレートで、プレビューと配信の開始が成立する。11.2）
//
// トラックの終了（ended）で、取得済みを喪失（lost）へ。画面共有の終了は、共有音声も喪失にする。映像が止まったまま継続する状態を作らない
//
// 要求中の解除・破棄: 要求は取り消せないため、あとから許可されたストリームのトラックを、止めて捨てる（カメラの使用中の表示を残さない）。
//   要求中であることの検査と、要求ごとの世代（isCurrent）で、古い要求の結果が、新しい要求の状態を壊さないようにする
//
// デバイス名・ラベル・デバイスの識別子は、診断（ログ）へ出さない。

import { resolveLayout } from "@/core/layout";
import { transitionSource } from "@/core/state";
import type { SourceEvent } from "@/core/state";
import type { Layout } from "@/core/contract";
import { classifyMediaError } from "./classifyMediaError";
import { buildCameraConstraints, buildDisplayConstraints, buildMicrophoneConstraints } from "./constraints";
import { DeviceCatalog } from "./DeviceCatalog";
import { NO_DIAGNOSTICS } from "./diagnostics";
import type { DiagnosticSink } from "./diagnostics";
import { Emitter, rethrowLater } from "./emitter";
import { SourceError } from "./errors";
import { MANAGED_SOURCE_KINDS, isManagedSourceKind } from "./types";
import type { ManagedSourceKind, MediaDevicesLike, SourceChange, SourceChangeListener, SourceHandle, SourceHandles, SourceReason } from "./types";

export interface SourceManagerOptions {
  /** navigator.mediaDevices に当たる物（テストで差し替える） */
  readonly mediaDevices: MediaDevicesLike;
  /** 診断の出力先。デバイス名・ラベル・識別子は出さない。既定は、何も出さない */
  readonly onDiagnostic?: DiagnosticSink;
  /** 購読者の例外・devicechange による一覧の更新の失敗の扱い。既定は、次のタスクで投げ直す（握りつぶさない） */
  readonly onError?: (error: unknown) => void;
}

type HandleFields = Pick<SourceHandle, "track" | "deviceId" | "label" | "reason">;

interface Slot {
  handle: SourceHandle;
  /** 取得済みのトラックの後始末（ended の購読を解除し、トラックを止める。冪等） */
  cleanup: (() => void) | null;
  /** 要求のたびに進める世代。新しい要求が出されたあとに、古い要求の結果が届いても、捨てるために使う（解除・破棄で要求中でなくなった結果は、isCurrent の状態の検査で捨てる） */
  generation: number;
  /** 要求中の Promise（要求中の重ねての attach へ、同じ結果を返す） */
  inflight: Promise<SourceHandle> | null;
}

function createHandle(kind: ManagedSourceKind, state: SourceHandle["state"], fields: Partial<HandleFields> = {}): SourceHandle {
  return Object.freeze({
    kind,
    state,
    track: fields.track ?? null,
    deviceId: fields.deviceId ?? null,
    label: fields.label ?? null,
    reason: fields.reason ?? null,
  });
}

function createSlot(kind: ManagedSourceKind): Slot {
  return { handle: createHandle(kind, "detached"), cleanup: null, generation: 0, inflight: null };
}

function stopAll(tracks: readonly MediaStreamTrack[]): void {
  for (const track of tracks) {
    track.stop();
  }
}

export class SourceManager {
  /** デバイスの一覧。取得の成功のあとと、devicechange のたびに、更新される */
  readonly devices: DeviceCatalog;

  private readonly mediaDevices: MediaDevicesLike;
  private readonly onError: (error: unknown) => void;
  private readonly diagnostic: DiagnosticSink;
  private readonly emitter: Emitter<SourceChangeListener>;
  private readonly slots: Record<ManagedSourceKind, Slot>;
  private snapshot: SourceHandles;
  private currentLayout: Layout = "slate";
  private disposed = false;

  constructor(options: SourceManagerOptions) {
    if (typeof options.mediaDevices !== "object" || options.mediaDevices === null) {
      // セキュアでない文脈（HTTPS・localhost 以外）では、navigator.mediaDevices が無い。呼び出し側が、能力検出（30.1）で、先に確かめる
      throw new TypeError("mediaDevices is required (navigator.mediaDevices is unavailable in insecure contexts)");
    }
    this.mediaDevices = options.mediaDevices;
    this.onError = options.onError ?? rethrowLater;
    this.diagnostic = options.onDiagnostic ?? NO_DIAGNOSTICS;
    this.emitter = new Emitter<SourceChangeListener>(this.onError);
    this.slots = {
      camera: createSlot("camera"),
      screen: createSlot("screen"),
      microphone: createSlot("microphone"),
      shared_audio: createSlot("shared_audio"),
    };
    this.snapshot = this.buildSnapshot();
    this.devices = new DeviceCatalog({ mediaDevices: this.mediaDevices, onError: this.onError, onDiagnostic: this.diagnostic });
    this.devices.watch();
  }

  /** 4 種別すべての、現在の状態。変化がない限り、同じオブジェクト（画面の購読に使える）。 */
  get sources(): SourceHandles {
    return this.snapshot;
  }

  /** 現在のレイアウト（有効な映像ソースの組から、一意に決まる。11.3）。 */
  get layout(): Layout {
    return this.currentLayout;
  }

  /** 画面共有 API（getDisplayMedia）がある。無い環境では、画面共有の操作のみ提供しない（30.1）。 */
  get canShareScreen(): boolean {
    return typeof this.mediaDevices.getDisplayMedia === "function";
  }

  getHandle(kind: ManagedSourceKind): SourceHandle {
    this.assertKind(kind);
    return this.slots[kind].handle;
  }

  /** 状態の変化を購読する。購読の解除の関数を返す。 */
  subscribe(listener: SourceChangeListener): () => void {
    return this.emitter.subscribe(listener);
  }

  /**
   * ソースを取得する。結果の状態（取得済み・拒否・未取得）の SourceHandle で解決する。型付きのエラー（SourceError）は、拒否する。
   *
   * 画面共有（kind が screen）は、共有音声も、同じ取得で得る。利用者のクリックのハンドラから、await を挟まずに呼ぶこと
   * （この関数は、呼び出しの中で、同期的に getDisplayMedia を呼ぶ）。
   *
   * 要求中の重ねての呼び出しは、新しい要求を出さず、同じ結果を返す。取得済みのとき、同じデバイス（または指定なし）なら、そのまま返す。
   * 別のデバイスを指定したときは、いったん解除して、そのデバイスで取得し直す（先に解除してから取得する。取得に失敗すると、元のデバイスには戻らない）。
   */
  async attach(kind: ManagedSourceKind, deviceId?: string): Promise<SourceHandle> {
    this.assertAttachable(kind, deviceId);
    const current = this.reuseCurrent(kind, deviceId);
    if (current !== null) {
      return current;
    }

    const slot = this.slots[kind];
    const run = kind === "screen" ? this.acquireDisplay() : this.acquireDevice(kind, deviceId);
    slot.inflight = run;
    const clear = (): void => {
      if (slot.inflight === run) {
        slot.inflight = null;
      }
    };
    run.then(clear, clear);
    return run;
  }

  /**
   * ソースを解除する（トラックを止める）。取得済み・喪失・拒否は、未取得へ。要求中は、すぐに未取得へ戻し、あとから許可された結果は捨てる。
   * 画面共有を解除すると、共有音声も解除する。共有音声だけを解除すると、音声のトラックだけを止める。未取得なら、何も起きない。
   */
  detach(kind: ManagedSourceKind): SourceHandle {
    this.assertKind(kind);
    if (kind === "screen") {
      this.release("screen");
      this.release("shared_audio");
      return this.slots.screen.handle;
    }
    return this.release(kind);
  }

  /**
   * トラックの終了を知らせる（トラックの ended イベントから呼ばれる）。取得済みのソースだけが、喪失（lost）になる。
   * 画面共有の終了は、共有音声も喪失にする。それ以外の状態では、何も起きない。
   */
  onTrackEnded(kind: ManagedSourceKind): void {
    this.assertKind(kind);
    const slot = this.slots[kind];
    if (slot.handle.state !== "active") {
      return;
    }
    const { deviceId, label } = slot.handle;
    slot.cleanup?.();
    slot.cleanup = null;
    this.apply(kind, "track_ended", { deviceId, label, reason: "track_ended" });
    if (kind === "screen" && this.slots.shared_audio.handle.state === "active") {
      this.onTrackEnded("shared_audio");
    }
  }

  /** すべてのソースを解除し、デバイスの変更の監視を止める。要求中のものは、あとから許可されたトラックを止めて捨てる。以後の attach は、disposed。 */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    for (const kind of MANAGED_SOURCE_KINDS) {
      this.release(kind);
    }
    this.devices.dispose();
  }

  // ---------------------------------------------------------------------------
  // attach の前提
  // ---------------------------------------------------------------------------

  /** attach の引数と環境を確かめる。取得を始める前に、状態を変えずに失敗させる。 */
  private assertAttachable(kind: ManagedSourceKind, deviceId: string | undefined): asserts kind is "camera" | "screen" | "microphone" {
    this.assertKind(kind);
    if (this.disposed) {
      throw new SourceError("disposed", kind);
    }
    if (kind === "shared_audio") {
      throw new SourceError("shared_audio_requires_screen", kind);
    }
    if (kind === "screen" && deviceId !== undefined) {
      throw new RangeError("deviceId cannot be specified for screen capture");
    }
    if (kind === "screen" && !this.canShareScreen) {
      throw new SourceError("unsupported", kind);
    }
  }

  /**
   * すでに要求中・取得済みなら、新しい要求を出さずに、その結果を返す。取得済みのソースに、別のデバイスが指定されたときは、先に解除して、null を返す
   * （呼び出し側が、そのデバイスで取得し直す）。それ以外（未取得・拒否・喪失）は、null。
   */
  private reuseCurrent(kind: ManagedSourceKind, deviceId: string | undefined): SourceHandle | Promise<SourceHandle> | null {
    const slot = this.slots[kind];
    if (slot.handle.state === "requesting") {
      return slot.inflight ?? slot.handle;
    }
    if (slot.handle.state !== "active") {
      return null;
    }
    if (deviceId === undefined || deviceId === "" || deviceId === slot.handle.deviceId) {
      return slot.handle;
    }
    this.release(kind);
    return null;
  }

  // ---------------------------------------------------------------------------
  // 取得
  // ---------------------------------------------------------------------------

  private async acquireDevice(kind: "camera" | "microphone", deviceId: string | undefined): Promise<SourceHandle> {
    const slot = this.slots[kind];
    slot.generation += 1;
    const generation = slot.generation;
    this.apply(kind, "request");
    const constraints = kind === "camera" ? buildCameraConstraints(deviceId) : buildMicrophoneConstraints(deviceId);

    let stream: MediaStream;
    try {
      stream = await this.mediaDevices.getUserMedia(constraints);
    } catch (error) {
      return this.failDevice(kind, generation, error);
    }
    return this.completeDevice(kind, generation, stream);
  }

  private failDevice(kind: ManagedSourceKind, generation: number, error: unknown): SourceHandle {
    if (!this.isCurrent(kind, generation)) {
      this.diagnostic("source_result_discarded", { kind });
      return this.slots[kind].handle;
    }
    const failure = classifyMediaError(kind, error);
    switch (failure.outcome) {
      case "denied":
        return this.apply(kind, "denied", { reason: "permission_denied" });
      case "cancelled":
        return this.apply(kind, "selection_cancelled", { reason: "selection_cancelled" });
      case "not_found":
        return this.apply(kind, "selection_cancelled", { reason: "device_not_found" });
      case "error":
        this.apply(kind, "selection_cancelled", { reason: "request_failed" });
        this.diagnostic("source_failed", { kind, code: failure.code, errorName: failure.errorName });
        throw new SourceError(failure.code, kind, error);
    }
  }

  private completeDevice(kind: "camera" | "microphone", generation: number, stream: MediaStream): SourceHandle {
    const tracks = stream.getTracks();
    if (!this.isCurrent(kind, generation)) {
      stopAll(tracks);
      this.diagnostic("source_result_discarded", { kind });
      return this.slots[kind].handle;
    }
    const track = (kind === "camera" ? stream.getVideoTracks() : stream.getAudioTracks())[0];
    if (track === undefined) {
      return this.failWithoutTrack(kind, tracks);
    }
    stopAll(tracks.filter((other) => other !== track));
    this.activate(kind, track);
    this.endIfAlreadyEnded(kind, track);
    this.refreshDevices();
    return this.slots[kind].handle;
  }

  private async acquireDisplay(): Promise<SourceHandle> {
    this.slots.screen.generation += 1;
    this.slots.shared_audio.generation += 1;
    const screenGeneration = this.slots.screen.generation;
    const sharedGeneration = this.slots.shared_audio.generation;
    this.apply("screen", "request");
    this.apply("shared_audio", "request");

    let stream: MediaStream;
    try {
      stream = await this.requestDisplayMedia();
    } catch (error) {
      return this.failDisplay(screenGeneration, sharedGeneration, error);
    }
    return this.completeDisplay(stream, screenGeneration, sharedGeneration);
  }

  /** getDisplayMedia を、呼び出しの中で、同期的に呼ぶ（呼び出しの前に、await を挟まない）。 */
  private requestDisplayMedia(): Promise<MediaStream> {
    const { mediaDevices } = this;
    if (typeof mediaDevices.getDisplayMedia !== "function") {
      return Promise.reject(new SourceError("unsupported", "screen"));
    }
    return mediaDevices.getDisplayMedia(buildDisplayConstraints());
  }

  private failDisplay(screenGeneration: number, sharedGeneration: number, error: unknown): SourceHandle {
    const screenCurrent = this.isCurrent("screen", screenGeneration);
    const sharedCurrent = this.isCurrent("shared_audio", sharedGeneration);
    if (!screenCurrent && !sharedCurrent) {
      this.diagnostic("source_result_discarded", { kind: "screen" });
      return this.slots.screen.handle;
    }
    const { reason, typedError } = this.interpretDisplayFailure(error);
    if (screenCurrent) {
      this.apply("screen", "selection_cancelled", { reason });
    }
    if (sharedCurrent) {
      this.apply("shared_audio", "selection_cancelled", { reason });
    }
    if (typedError !== null) {
      throw typedError;
    }
    return this.slots.screen.handle;
  }

  /** 画面共有の取得の失敗を、未取得へ戻す理由と（型付きのエラーにするなら）そのエラーにする。 */
  private interpretDisplayFailure(error: unknown): { readonly reason: SourceReason; readonly typedError: SourceError | null } {
    const failure = classifyMediaError("screen", error);
    switch (failure.outcome) {
      case "denied":
      case "cancelled":
        return { reason: "selection_cancelled", typedError: null };
      case "not_found":
        return { reason: "device_not_found", typedError: null };
      case "error":
        this.diagnostic("source_failed", { kind: "screen", code: failure.code, errorName: failure.errorName });
        return { reason: "request_failed", typedError: new SourceError(failure.code, "screen", error) };
    }
  }

  private completeDisplay(stream: MediaStream, screenGeneration: number, sharedGeneration: number): SourceHandle {
    const tracks = stream.getTracks();
    const screenCurrent = this.isCurrent("screen", screenGeneration);
    const sharedCurrent = this.isCurrent("shared_audio", sharedGeneration);
    const video = stream.getVideoTracks()[0];

    if (screenCurrent && video === undefined) {
      if (sharedCurrent) {
        this.apply("shared_audio", "selection_cancelled", { reason: "request_failed" });
      }
      return this.failWithoutTrack("screen", tracks);
    }

    const accepted = this.activateDisplayTracks({ screen: screenCurrent ? video : undefined, shared: sharedCurrent ? stream.getAudioTracks()[0] : undefined }, sharedCurrent);
    if (accepted.size === 0) {
      this.diagnostic("source_result_discarded", { kind: "screen" });
    }
    stopAll(tracks.filter((track) => ![...accepted.values()].includes(track)));
    for (const [kind, track] of accepted) {
      this.endIfAlreadyEnded(kind, track);
    }
    return this.slots.screen.handle;
  }

  /**
   * 画面共有の取得で得たトラックのうち、この要求のものを、取得済みにする。screen・shared は、この要求のものとして扱うトラック（解除された種別は undefined）。
   * 共有音声がこの要求のもので、音声のトラックが無いときは、共有音声だけを未取得（理由 no_audio_track）へ戻す。取得済みにしたトラックを返す。
   */
  private activateDisplayTracks(tracks: { readonly screen: MediaStreamTrack | undefined; readonly shared: MediaStreamTrack | undefined }, sharedCurrent: boolean): Map<"screen" | "shared_audio", MediaStreamTrack> {
    const accepted = new Map<"screen" | "shared_audio", MediaStreamTrack>();
    if (tracks.screen !== undefined) {
      this.activate("screen", tracks.screen);
      accepted.set("screen", tracks.screen);
    }
    if (tracks.shared !== undefined) {
      this.activate("shared_audio", tracks.shared);
      accepted.set("shared_audio", tracks.shared);
    } else if (sharedCurrent) {
      // 共有音声が得られるのは、Chrome・Edge の「タブの共有」と、Windows・ChromeOS の「画面全体の共有」だけ。音声が無いのは、エラーではない
      this.apply("shared_audio", "selection_cancelled", { reason: "no_audio_track" });
    }
    return accepted;
  }

  /** 取得に成功したが、期待したトラックが無い。ストリームのトラックをすべて止め、未取得へ戻して、型付きのエラーにする。 */
  private failWithoutTrack(kind: ManagedSourceKind, tracks: readonly MediaStreamTrack[]): never {
    stopAll(tracks);
    this.apply(kind, "selection_cancelled", { reason: "request_failed" });
    this.diagnostic("source_failed", { kind, code: "no_track", errorName: null });
    throw new SourceError("no_track", kind);
  }

  /** 要求の結果を、この要求のものとして扱えるか（破棄・解除・再要求で、世代が進んでいない。まだ要求中）。 */
  private isCurrent(kind: ManagedSourceKind, generation: number): boolean {
    const slot = this.slots[kind];
    return !this.disposed && slot.generation === generation && slot.handle.state === "requesting";
  }

  /** 許可されたトラックを、取得済みにする。ended の購読を始め、解除・終了のときの後始末を持つ。 */
  private activate(kind: ManagedSourceKind, track: MediaStreamTrack): SourceHandle {
    const slot = this.slots[kind];
    const onEnded = (): void => {
      if (slot.handle.track === track) {
        this.onTrackEnded(kind);
      }
    };
    track.addEventListener("ended", onEnded);
    slot.cleanup = () => {
      track.removeEventListener("ended", onEnded);
      track.stop();
    };
    const settings = track.getSettings();
    // デバイスの識別子は、カメラ・マイクだけ。画面共有・共有音声の識別子は、利用者にとって意味が無いので持たない
    const deviceId = (kind === "camera" || kind === "microphone") && typeof settings.deviceId === "string" && settings.deviceId !== "" ? settings.deviceId : null;
    return this.apply(kind, "granted", { track, deviceId, label: track.label === "" ? null : track.label });
  }

  /** 許可された時点で、すでに終了しているトラックは、ended が来ない。取得済みを経て、すぐに喪失にする。 */
  private endIfAlreadyEnded(kind: ManagedSourceKind, track: MediaStreamTrack): void {
    if (track.readyState === "ended" && this.slots[kind].handle.track === track) {
      this.onTrackEnded(kind);
    }
  }

  /** 取得の成功のあとに、デバイスの一覧を取得し直す（ラベルは、権限の取得後にのみ得られる）。失敗は、例外の処理へ渡す。 */
  private refreshDevices(): void {
    this.devices.refresh().catch((error: unknown) => {
      this.onError(error);
    });
  }

  // ---------------------------------------------------------------------------
  // 解除・状態
  // ---------------------------------------------------------------------------

  private release(kind: ManagedSourceKind): SourceHandle {
    const slot = this.slots[kind];
    switch (slot.handle.state) {
      case "detached":
        return slot.handle;
      case "requesting":
        // 25.5 に、要求中から未取得へ戻る矢印は、選択の取り消しだけ。要求そのものは取り消せない。あとから届く結果は、状態が要求中でなくなっているため
        // （isCurrent）、捨てられる。そのあとに新しい要求が出されても、要求のたびに進む世代が違うため、古い結果は捨てられる
        slot.inflight = null;
        return this.apply(kind, "selection_cancelled", { reason: "released" });
      default:
        slot.cleanup?.();
        slot.cleanup = null;
        return this.apply(kind, "release", { reason: "released" });
    }
  }

  /**
   * 事象を、状態機械（core の transitionSource）へ渡し、状態が変わったときだけ、記録を作り直して、購読者へ通知する。
   * 定義のない（状態, 事象）の組は、状態を変えないので、何も通知しない。
   */
  private apply(kind: ManagedSourceKind, event: SourceEvent, fields: Partial<HandleFields> = {}): SourceHandle {
    const slot = this.slots[kind];
    const previous = slot.handle;
    const nextState = transitionSource(previous.state, event);
    if (nextState === previous.state) {
      return previous;
    }
    const current = createHandle(kind, nextState, fields);
    slot.handle = current;
    this.snapshot = this.buildSnapshot();
    const layout = resolveLayout({ screen: this.slots.screen.handle.state, camera: this.slots.camera.handle.state });
    const layoutChanged = layout !== this.currentLayout;
    this.currentLayout = layout;
    this.diagnostic("source_state", { kind, from: previous.state, to: nextState, reason: current.reason });
    const change: SourceChange = Object.freeze({ kind, previous, current, layout, layoutChanged });
    this.emitter.notify((listener) => listener(change));
    return current;
  }

  private buildSnapshot(): SourceHandles {
    return Object.freeze({
      camera: this.slots.camera.handle,
      screen: this.slots.screen.handle,
      microphone: this.slots.microphone.handle,
      shared_audio: this.slots.shared_audio.handle,
    });
  }

  private assertKind(kind: unknown): asserts kind is ManagedSourceKind {
    if (!isManagedSourceKind(kind)) {
      throw new RangeError(`unknown source kind (expected one of ${MANAGED_SOURCE_KINDS.join(", ")}): ${String(kind)}`);
    }
  }
}
