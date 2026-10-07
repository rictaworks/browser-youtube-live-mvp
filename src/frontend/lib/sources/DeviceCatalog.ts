// デバイスの一覧（requirements.md 16.2「デバイスの選択」・issue #26）。
//   - enumerateDevices で、カメラ（videoinput）とマイク（audioinput）の一覧を作る（出力のデバイスは対象外）
//   - ラベル（デバイス名）は、権限の取得後にのみ得られる。取得前は、ラベルが空で、識別子も空のことがある。
//     種別ごとに、ラベルが得られているか（デバイスが 1 つ以上あり、すべてにラベルがある）を持つ。画面は、得られていないとき、汎用の名前を出す
//   - devicechange（デバイスの抜き差し）で、一覧を更新する（watch）
//   - 一覧が変わったときだけ購読者へ通知し、変わらなければ、スナップショットの同一性を保つ（画面の無駄な再描画を避ける）
//   - デバイス名・ラベル・識別子を、診断（ログ）へ出さない（件数だけ）

import { NO_DIAGNOSTICS } from "./diagnostics";
import type { DiagnosticSink } from "./diagnostics";
import { Emitter, rethrowLater } from "./emitter";
import type { MediaDevicesLike } from "./types";

export interface DeviceInfo {
  readonly kind: "camera" | "microphone";
  /** 取得（attach）に渡す識別子。権限の取得前は、空文字列のことがある（その場合、attach は、デバイスを指定しない取得になる） */
  readonly deviceId: string;
  /** デバイス名。権限の取得前は、空文字列。画面の表示のためで、ログ・測定イベント・中継へ送らない */
  readonly label: string;
}

export interface DeviceList {
  readonly cameras: readonly DeviceInfo[];
  readonly microphones: readonly DeviceInfo[];
  /** カメラのラベルが得られている（カメラが 1 つ以上あり、すべてにラベルがある） */
  readonly cameraLabelsAvailable: boolean;
  /** マイクのラベルが得られている */
  readonly microphoneLabelsAvailable: boolean;
}

export type DeviceListListener = (list: DeviceList) => void;

export interface DeviceCatalogOptions {
  readonly mediaDevices: Pick<MediaDevicesLike, "enumerateDevices" | "addEventListener" | "removeEventListener">;
  /** 購読者の例外・devicechange による更新の失敗の扱い。既定は、次のタスクで投げ直す（握りつぶさない） */
  readonly onError?: (error: unknown) => void;
  readonly onDiagnostic?: DiagnosticSink;
}

const EMPTY_LIST: DeviceList = Object.freeze({
  cameras: Object.freeze([]),
  microphones: Object.freeze([]),
  cameraLabelsAvailable: false,
  microphoneLabelsAvailable: false,
});

function labelsAvailable(devices: readonly DeviceInfo[]): boolean {
  return devices.length > 0 && devices.every((device) => device.label !== "");
}

function toDeviceList(devices: readonly MediaDeviceInfo[]): DeviceList {
  const cameras: DeviceInfo[] = [];
  const microphones: DeviceInfo[] = [];
  for (const device of devices) {
    if (device.kind === "videoinput") {
      cameras.push({ kind: "camera", deviceId: device.deviceId, label: device.label });
    } else if (device.kind === "audioinput") {
      microphones.push({ kind: "microphone", deviceId: device.deviceId, label: device.label });
    }
  }
  return Object.freeze({
    cameras: Object.freeze(cameras),
    microphones: Object.freeze(microphones),
    cameraLabelsAvailable: labelsAvailable(cameras),
    microphoneLabelsAvailable: labelsAvailable(microphones),
  });
}

function sameDevices(left: readonly DeviceInfo[], right: readonly DeviceInfo[]): boolean {
  return left.length === right.length && left.every((device, index) => device.deviceId === right[index].deviceId && device.label === right[index].label);
}

function sameList(left: DeviceList, right: DeviceList): boolean {
  return (
    left.cameraLabelsAvailable === right.cameraLabelsAvailable &&
    left.microphoneLabelsAvailable === right.microphoneLabelsAvailable &&
    sameDevices(left.cameras, right.cameras) &&
    sameDevices(left.microphones, right.microphones)
  );
}

export class DeviceCatalog {
  private readonly mediaDevices: DeviceCatalogOptions["mediaDevices"];
  private readonly onError: (error: unknown) => void;
  private readonly onDiagnostic: DiagnosticSink;
  private readonly emitter: Emitter<DeviceListListener>;
  private current: DeviceList = EMPTY_LIST;
  private requestCount = 0;
  private latestAppliedRequest = 0;
  private watching = false;
  private disposed = false;

  constructor(options: DeviceCatalogOptions) {
    this.mediaDevices = options.mediaDevices;
    this.onError = options.onError ?? rethrowLater;
    this.onDiagnostic = options.onDiagnostic ?? NO_DIAGNOSTICS;
    this.emitter = new Emitter<DeviceListListener>(this.onError);
  }

  /** 現在の一覧。変わらない限り、同じオブジェクト。 */
  get snapshot(): DeviceList {
    return this.current;
  }

  /**
   * 一覧を取得し直す。enumerateDevices の失敗は、呼び出し元へ伝える（一覧は変えない）。
   * 更新が重なったとき、古い要求の結果で、新しい結果を上書きしない（その場合、現在の一覧を返す）。
   */
  async refresh(): Promise<DeviceList> {
    this.requestCount += 1;
    const request = this.requestCount;
    const devices = await this.mediaDevices.enumerateDevices();
    if (this.disposed || request < this.latestAppliedRequest) {
      return this.current;
    }
    this.latestAppliedRequest = request;
    const next = toDeviceList(devices);
    this.onDiagnostic("devices_refreshed", {
      cameras: next.cameras.length,
      microphones: next.microphones.length,
      cameraLabelsAvailable: next.cameraLabelsAvailable,
      microphoneLabelsAvailable: next.microphoneLabelsAvailable,
    });
    if (!sameList(this.current, next)) {
      this.current = next;
      this.emitter.notify((listener) => listener(next));
    }
    return this.current;
  }

  subscribe(listener: DeviceListListener): () => void {
    return this.emitter.subscribe(listener);
  }

  /** devicechange で、一覧を更新し始める（重ねて呼んでも、購読は 1 つ）。更新の失敗は、onError へ渡す。 */
  watch(): void {
    if (this.watching || this.disposed) {
      return;
    }
    this.watching = true;
    this.mediaDevices.addEventListener("devicechange", this.handleDeviceChange);
  }

  /** 更新を止める。以後、通知もしない。 */
  dispose(): void {
    this.disposed = true;
    if (this.watching) {
      this.watching = false;
      this.mediaDevices.removeEventListener("devicechange", this.handleDeviceChange);
    }
  }

  private readonly handleDeviceChange = (): void => {
    this.refresh().catch((error: unknown) => {
      this.onError(error);
    });
  };
}
