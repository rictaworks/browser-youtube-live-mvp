// ソースの取得（SourceManager・DeviceCatalog）と、音声の混合との接続のテストの共通部品。テストからだけ使う（実行時のコードから import しない）。
//
// モックの境界: 実機のデバイス（カメラ・マイク・画面共有）・MediaDevices・MediaStream・MediaStreamTrack は、すべて疑似（自動テストでは使えない。
// Playwright でも許可できない場合がある）。実機の確認は、画面ができる #29 のユーザーテストで行う。
// 疑似の getDisplayMedia は、利用者の操作（クリック）の直後でなければ InvalidStateError にできる（click の中だけ、操作がある状態にする）。
// 値は、明らかなダミー。デバイス名・識別子には、ログへ漏れていないことを確かめられるよう、見つけやすい印（LABEL-・DEVICE-）を付ける。
import type { MediaDevicesLike } from "./types";

export interface Deferred<T> {
  readonly promise: Promise<T>;
  resolve(value: T): void;
  reject(reason: unknown): void;
}

export function deferred<T>(): Deferred<T> {
  let resolve: (value: T) => void = () => undefined;
  let reject: (reason: unknown) => void = () => undefined;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

/** DOMException（名前つき）。OverconstrainedError の constraint など、追加の項目を持てる。message は、省くと、名前から作る。 */
export function domError(name: string, extra: Record<string, unknown> = {}, message = `message for ${name}`): DOMException {
  return Object.assign(new DOMException(message, name), extra);
}

/** マイクロタスクとタスクを、何回か回して、待っていた処理を進める。 */
export async function flushPromises(rounds = 10): Promise<void> {
  for (let round = 0; round < rounds; round += 1) {
    await Promise.resolve();
  }
}

export interface FakeTrackOptions {
  readonly label?: string;
  readonly deviceId?: string;
}

/** MediaStreamTrack の疑似。stop() は、ended イベントを起こさない（仕様どおり）。end() は、デバイスの喪失・共有の停止（ended を起こす）。 */
export class FakeTrack extends EventTarget {
  readonly kind: "audio" | "video";
  readonly label: string;
  readyState: "live" | "ended" = "live";
  stopCount = 0;
  private readonly endedListeners = new Set<EventListenerOrEventListenerObject>();
  private readonly deviceId: string | undefined;

  constructor(kind: "audio" | "video", options: FakeTrackOptions = {}) {
    super();
    this.kind = kind;
    this.label = options.label ?? `LABEL-${kind}`;
    this.deviceId = options.deviceId;
  }

  getSettings(): MediaTrackSettings {
    return this.deviceId === undefined ? {} : { deviceId: this.deviceId };
  }

  stop(): void {
    this.readyState = "ended";
    this.stopCount += 1;
  }

  end(): void {
    this.readyState = "ended";
    this.dispatchEvent(new Event("ended"));
  }

  override addEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: boolean | AddEventListenerOptions): void {
    if (type === "ended" && listener !== null) {
      this.endedListeners.add(listener);
    }
    super.addEventListener(type, listener, options);
  }

  override removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: boolean | EventListenerOptions): void {
    if (type === "ended" && listener !== null) {
      this.endedListeners.delete(listener);
    }
    super.removeEventListener(type, listener, options);
  }

  /** 登録されている ended の購読者の数（解除し忘れの検査に使う） */
  get endedListenerCount(): number {
    return this.endedListeners.size;
  }

  asTrack(): MediaStreamTrack {
    return this as unknown as MediaStreamTrack;
  }
}

/** MediaStream の疑似。 */
export class FakeStream {
  readonly tracks: FakeTrack[];

  constructor(tracks: readonly FakeTrack[]) {
    this.tracks = [...tracks];
  }

  getTracks(): MediaStreamTrack[] {
    return this.tracks.map((track) => track.asTrack());
  }

  getVideoTracks(): MediaStreamTrack[] {
    return this.tracks.filter((track) => track.kind === "video").map((track) => track.asTrack());
  }

  getAudioTracks(): MediaStreamTrack[] {
    return this.tracks.filter((track) => track.kind === "audio").map((track) => track.asTrack());
  }

  asStream(): MediaStream {
    return this as unknown as MediaStream;
  }
}

export interface FakeDevice {
  readonly kind: MediaDeviceKind;
  readonly deviceId: string;
  readonly label: string;
  readonly groupId: string;
}

/** 取得要求への応答。引数は、要求の制約。 */
export type MediaBehavior = (constraints: unknown) => Promise<MediaStream>;

/** 要求を、エラー（名前つきの DOMException など）で拒否する。 */
export function rejectWith(error: unknown): MediaBehavior {
  return () => Promise.reject(error);
}

/** 応答を、あとで返す（選択画面・権限の確認が開いている間）。deferred に、MediaStream を渡すか、拒否する。 */
export function pendingResponse(): { readonly behavior: MediaBehavior; readonly response: Deferred<MediaStream> } {
  const response = deferred<MediaStream>();
  return { behavior: () => response.promise, response };
}

/** 指定のトラックを持つストリーム。 */
export function streamOf(...tracks: FakeTrack[]): MediaStream {
  return new FakeStream(tracks).asStream();
}

/** 指定のトラックを持つストリームを、すぐに返す。 */
export function respondWith(...tracks: FakeTrack[]): MediaBehavior {
  return () => Promise.resolve(streamOf(...tracks));
}

export interface FakeMediaDevicesOptions {
  /** false にすると、getDisplayMedia を持たない（画面共有 API が無い環境） */
  readonly displayMedia?: boolean;
  /** 画面共有の取得で、音声のトラックを返すか（タブの共有など）。既定は true */
  readonly sharedAudio?: boolean;
}

/** navigator.mediaDevices の疑似。 */
export class FakeMediaDevices extends EventTarget {
  readonly userMediaCalls: MediaStreamConstraints[] = [];
  readonly displayMediaCalls: (DisplayMediaStreamOptions | undefined)[] = [];
  enumerateCalls = 0;
  devices: FakeDevice[] = [];
  enumerateError: unknown = null;
  /** 作ったトラックのすべて（要求ごとに作る既定の応答の分） */
  readonly createdTracks: FakeTrack[] = [];
  /** 利用者の操作（クリック等）の状態。required が真のとき、操作の外の getDisplayMedia は InvalidStateError */
  readonly activation = { active: false, required: false };
  getDisplayMedia?: (options?: DisplayMediaStreamOptions) => Promise<MediaStream>;

  private readonly userMediaQueue: MediaBehavior[] = [];
  private readonly displayMediaQueue: MediaBehavior[] = [];
  private readonly sharedAudio: boolean;

  constructor(options: FakeMediaDevicesOptions = {}) {
    super();
    this.sharedAudio = options.sharedAudio ?? true;
    if (options.displayMedia !== false) {
      this.getDisplayMedia = (displayOptions) => this.handleDisplayMedia(displayOptions);
    }
  }

  /** 次の getUserMedia への応答を、順に積む（積んだ分を使い切ると、既定の応答 = 許可）。 */
  queueUserMedia(...behaviors: MediaBehavior[]): void {
    this.userMediaQueue.push(...behaviors);
  }

  queueDisplayMedia(...behaviors: MediaBehavior[]): void {
    this.displayMediaQueue.push(...behaviors);
  }

  getUserMedia(constraints?: MediaStreamConstraints): Promise<MediaStream> {
    const requested = constraints ?? {};
    this.userMediaCalls.push(requested);
    const behavior = this.userMediaQueue.shift();
    return behavior === undefined ? this.grantUserMedia(requested) : behavior(requested);
  }

  private handleDisplayMedia(options: DisplayMediaStreamOptions | undefined): Promise<MediaStream> {
    this.displayMediaCalls.push(options);
    if (this.activation.required && !this.activation.active) {
      return Promise.reject(domError("InvalidStateError"));
    }
    const behavior = this.displayMediaQueue.shift();
    return behavior === undefined ? this.grantDisplayMedia(options) : behavior(options);
  }

  async enumerateDevices(): Promise<MediaDeviceInfo[]> {
    this.enumerateCalls += 1;
    if (this.enumerateError !== null) {
      throw this.enumerateError;
    }
    return this.devices.map((device) => ({ ...device, toJSON: () => device }) as MediaDeviceInfo);
  }

  /** デバイスの抜き差し（devicechange）を起こす。 */
  changeDevices(devices?: FakeDevice[]): void {
    if (devices !== undefined) {
      this.devices = devices;
    }
    this.dispatchEvent(new Event("devicechange"));
  }

  /** 利用者のクリックの中を、疑似する（ハンドラの同期の部分だけ、操作がある状態）。非同期の継続（await のあと）には、操作が無い。 */
  click(handler: () => void): void {
    this.activation.active = true;
    try {
      handler();
    } finally {
      this.activation.active = false;
    }
  }

  asMediaDevices(): MediaDevicesLike {
    return this as unknown as MediaDevicesLike;
  }

  /** 要求の制約から、デバイスの識別子（exact の指定。無ければ既定）。 */
  private deviceIdFor(constraint: boolean | MediaTrackConstraints | undefined, fallback: string): string {
    if (typeof constraint === "object" && constraint !== null) {
      const deviceId = constraint.deviceId;
      if (typeof deviceId === "object" && deviceId !== null && !Array.isArray(deviceId) && typeof deviceId.exact === "string") {
        return deviceId.exact;
      }
    }
    return fallback;
  }

  private newTrack(kind: "audio" | "video", deviceId: string | undefined, label: string): FakeTrack {
    const track = new FakeTrack(kind, { deviceId, label });
    this.createdTracks.push(track);
    return track;
  }

  private grantUserMedia(constraints: MediaStreamConstraints): Promise<MediaStream> {
    const tracks: FakeTrack[] = [];
    if (constraints.video) {
      const deviceId = this.deviceIdFor(constraints.video, "DEVICE-default-camera");
      tracks.push(this.newTrack("video", deviceId, `LABEL-camera-${deviceId}`));
    }
    if (constraints.audio) {
      const deviceId = this.deviceIdFor(constraints.audio, "DEVICE-default-microphone");
      tracks.push(this.newTrack("audio", deviceId, `LABEL-microphone-${deviceId}`));
    }
    return Promise.resolve(new FakeStream(tracks).asStream());
  }

  private grantDisplayMedia(options: DisplayMediaStreamOptions | undefined): Promise<MediaStream> {
    const tracks = [this.newTrack("video", undefined, "LABEL-screen")];
    if (options?.audio && this.sharedAudio) {
      tracks.push(this.newTrack("audio", undefined, "LABEL-shared-audio"));
    }
    return Promise.resolve(new FakeStream(tracks).asStream());
  }
}
