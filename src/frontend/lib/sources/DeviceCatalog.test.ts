// DeviceCatalog（デバイスの一覧。requirements.md 16.2・issue #26）。
//   - enumerateDevices で、カメラ（videoinput）とマイク（audioinput）の一覧を作る（出力のデバイスは対象外）
//   - ラベルは、権限の取得後にのみ得られる。取得前は、ラベルが空（識別子も空のことがある）。ラベルが得られているかを、種別ごとに持つ
//   - devicechange（デバイスの抜き差し）で、一覧を更新する
//   - デバイス名・ラベルを、診断（ログ）へ出さない
import { DeviceCatalog } from "./DeviceCatalog";
import type { DeviceList } from "./DeviceCatalog";
import { FakeMediaDevices, deferred, flushPromises } from "./test-support";
import type { FakeDevice } from "./test-support";

function device(kind: MediaDeviceKind, deviceId: string, label: string): FakeDevice {
  return { kind, deviceId, label, groupId: `group-${deviceId}` };
}

const GRANTED_DEVICES: FakeDevice[] = [
  device("videoinput", "DEVICE-cam-1", "LABEL-cam-1"),
  device("videoinput", "DEVICE-cam-2", "LABEL-cam-2"),
  device("audioinput", "DEVICE-mic-1", "LABEL-mic-1"),
  device("audiooutput", "DEVICE-spk-1", "LABEL-spk-1"),
];

function createCatalog(devices: FakeMediaDevices, overrides: { onError?: (error: unknown) => void; onDiagnostic?: (event: string, fields: Record<string, unknown>) => void } = {}): DeviceCatalog {
  return new DeviceCatalog({ mediaDevices: devices.asMediaDevices(), onError: overrides.onError ?? (() => undefined), onDiagnostic: overrides.onDiagnostic });
}

describe("初期の状態", () => {
  it("一覧は空で、ラベルは得られていない（権限の取得前）", () => {
    const catalog = createCatalog(new FakeMediaDevices());

    expect(catalog.snapshot).toEqual({ cameras: [], microphones: [], cameraLabelsAvailable: false, microphoneLabelsAvailable: false });
  });

  it("構築しただけでは、enumerateDevices を呼ばない（呼び出しは、利用者の側の操作）", () => {
    const devices = new FakeMediaDevices();

    createCatalog(devices);

    expect(devices.enumerateCalls).toBe(0);
  });
});

describe("refresh", () => {
  it("カメラ（videoinput）とマイク（audioinput）の一覧を作る。出力のデバイス（audiooutput）は含めない。順は、ブラウザが返した順", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = GRANTED_DEVICES;
    const catalog = createCatalog(devices);

    const list = await catalog.refresh();

    expect(list.cameras).toEqual([
      { kind: "camera", deviceId: "DEVICE-cam-1", label: "LABEL-cam-1" },
      { kind: "camera", deviceId: "DEVICE-cam-2", label: "LABEL-cam-2" },
    ]);
    expect(list.microphones).toEqual([{ kind: "microphone", deviceId: "DEVICE-mic-1", label: "LABEL-mic-1" }]);
    expect(catalog.snapshot).toBe(list);
  });

  it("すべてのデバイスにラベルがあれば、種別ごとに、ラベルが得られている", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = GRANTED_DEVICES;

    const list = await createCatalog(devices).refresh();

    expect(list.cameraLabelsAvailable).toBe(true);
    expect(list.microphoneLabelsAvailable).toBe(true);
  });

  it("権限の取得前（ラベル・識別子が空のデバイス）は、ラベルが得られていない。デバイスは一覧に残す（存在は分かる）", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = [device("videoinput", "", ""), device("audioinput", "", "")];

    const list = await createCatalog(devices).refresh();

    expect(list.cameras).toEqual([{ kind: "camera", deviceId: "", label: "" }]);
    expect(list.microphones).toEqual([{ kind: "microphone", deviceId: "", label: "" }]);
    expect(list.cameraLabelsAvailable).toBe(false);
    expect(list.microphoneLabelsAvailable).toBe(false);
  });

  it("ラベルが得られているかは、種別ごと（カメラの権限だけを得た状態）", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = [device("videoinput", "DEVICE-cam-1", "LABEL-cam-1"), device("audioinput", "", "")];

    const list = await createCatalog(devices).refresh();

    expect(list.cameraLabelsAvailable).toBe(true);
    expect(list.microphoneLabelsAvailable).toBe(false);
  });

  it("デバイスが 1 つも無い種別は、ラベルが得られているとは言わない（得られた証拠が無い）", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = [device("audioinput", "DEVICE-mic-1", "LABEL-mic-1")];

    const list = await createCatalog(devices).refresh();

    expect(list.cameras).toEqual([]);
    expect(list.cameraLabelsAvailable).toBe(false);
    expect(list.microphoneLabelsAvailable).toBe(true);
  });

  it("enumerateDevices の失敗は、握りつぶさず、呼び出し元へ伝える。一覧は変わらない", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = GRANTED_DEVICES;
    const catalog = createCatalog(devices);
    const before = await catalog.refresh();
    const failure = new Error("enumerate failed");
    devices.enumerateError = failure;

    await expect(catalog.refresh()).rejects.toBe(failure);

    expect(catalog.snapshot).toBe(before);
  });

  it("複数の更新が重なったとき、古い要求の結果で、新しい結果を上書きしない", async () => {
    const first = deferred<MediaDeviceInfo[]>();
    const second = deferred<MediaDeviceInfo[]>();
    const responses = [first, second];
    const enumerateDevices = jest.fn(() => responses.shift()?.promise ?? Promise.resolve([]));
    const catalog = new DeviceCatalog({
      mediaDevices: { enumerateDevices, addEventListener: jest.fn(), removeEventListener: jest.fn() },
      onError: () => undefined,
    });

    const olderRefresh = catalog.refresh();
    const newerRefresh = catalog.refresh();
    second.resolve([{ kind: "audioinput", deviceId: "DEVICE-new", label: "LABEL-new", groupId: "g" } as MediaDeviceInfo]);
    await newerRefresh;
    first.resolve([{ kind: "audioinput", deviceId: "DEVICE-old", label: "LABEL-old", groupId: "g" } as MediaDeviceInfo]);
    await olderRefresh;

    expect(catalog.snapshot.microphones.map((entry) => entry.deviceId)).toEqual(["DEVICE-new"]);
  });
});

describe("購読", () => {
  it("一覧が変わったときだけ通知する（同じ内容なら、通知せず、スナップショットの同一性も保つ）", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = GRANTED_DEVICES;
    const catalog = createCatalog(devices);
    const lists: DeviceList[] = [];
    catalog.subscribe((list) => lists.push(list));

    const first = await catalog.refresh();
    const second = await catalog.refresh();
    devices.devices = [...GRANTED_DEVICES, device("audioinput", "DEVICE-mic-2", "LABEL-mic-2")];
    const third = await catalog.refresh();

    expect(second).toBe(first);
    expect(lists).toEqual([first, third]);
    expect(third.microphones).toHaveLength(2);
  });

  it("購読の解除のあとは、通知しない。購読者の例外は、他の購読者を止めず、例外の処理へ渡す", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = GRANTED_DEVICES;
    const errors: unknown[] = [];
    const catalog = createCatalog(devices, { onError: (error) => errors.push(error) });
    const failure = new Error("listener failure");
    const after = jest.fn();
    catalog.subscribe(() => {
      throw failure;
    });
    const unsubscribe = catalog.subscribe(after);

    await catalog.refresh();
    unsubscribe();
    devices.devices = [];
    await catalog.refresh();

    expect(errors).toEqual([failure, failure]);
    expect(after).toHaveBeenCalledTimes(1);
  });
});

describe("devicechange（デバイスの抜き差し）", () => {
  it("watch のあと、devicechange で、一覧を更新する", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = [device("audioinput", "DEVICE-mic-1", "LABEL-mic-1")];
    const catalog = createCatalog(devices);
    catalog.watch();

    devices.changeDevices([device("audioinput", "DEVICE-mic-1", "LABEL-mic-1"), device("videoinput", "DEVICE-cam-1", "LABEL-cam-1")]);
    await flushPromises();

    expect(devices.enumerateCalls).toBe(1);
    expect(catalog.snapshot.cameras).toHaveLength(1);
  });

  it("watch の前は、更新しない。watch を重ねて呼んでも、購読は 1 つ", async () => {
    const devices = new FakeMediaDevices();
    const catalog = createCatalog(devices);

    devices.changeDevices([]);
    await flushPromises();
    expect(devices.enumerateCalls).toBe(0);

    catalog.watch();
    catalog.watch();
    devices.changeDevices([]);
    await flushPromises();

    expect(devices.enumerateCalls).toBe(1);
  });

  it("dispose のあとは、devicechange で更新しない。購読も通知されない", async () => {
    const devices = new FakeMediaDevices();
    const catalog = createCatalog(devices);
    const listener = jest.fn();
    catalog.subscribe(listener);
    catalog.watch();

    catalog.dispose();
    devices.changeDevices([device("audioinput", "DEVICE-mic-1", "LABEL-mic-1")]);
    await flushPromises();

    expect(devices.enumerateCalls).toBe(0);
    expect(listener).not.toHaveBeenCalled();
  });

  it("devicechange による更新の失敗は、未処理の例外にせず、例外の処理へ渡す", async () => {
    const devices = new FakeMediaDevices();
    const failure = new Error("enumerate failed");
    devices.enumerateError = failure;
    const errors: unknown[] = [];
    const catalog = createCatalog(devices, { onError: (error) => errors.push(error) });
    catalog.watch();

    devices.changeDevices();
    await flushPromises();

    expect(errors).toEqual([failure]);
  });
});

describe("診断（デバイス名・ラベル・識別子を、ログへ出さない）", () => {
  it("診断には、件数だけを出し、ラベルと識別子を含めない", async () => {
    const devices = new FakeMediaDevices();
    devices.devices = GRANTED_DEVICES;
    const events: { event: string; fields: Record<string, unknown> }[] = [];
    const catalog = createCatalog(devices, { onDiagnostic: (event, fields) => events.push({ event, fields }) });

    await catalog.refresh();

    expect(events.length).toBeGreaterThan(0);
    const text = JSON.stringify(events);
    expect(text).not.toContain("LABEL-");
    expect(text).not.toContain("DEVICE-");
    expect(events[0]).toEqual({ event: "devices_refreshed", fields: { cameras: 2, microphones: 1, cameraLabelsAvailable: true, microphoneLabelsAvailable: true } });
  });
});
