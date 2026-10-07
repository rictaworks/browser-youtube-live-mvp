// AudioEnvironment（ブラウザの AudioContext・AudioWorkletNode・MediaStream・タイマを、注入できる形にしたもの）。
// ブラウザ用の実装は、window に当たるオブジェクトから、コンストラクタとタイマを読む。無ければ、使えない環境として、型付きのエラー。
import { AudioMixerError } from "./errors";
import { createBrowserAudioEnvironment } from "./environment";
import type { BrowserAudioScope } from "./environment";

class FakeContextConstructor {
  readonly options: unknown;
  constructor(options: unknown) {
    this.options = options;
  }
}

class FakeNodeConstructor {
  readonly args: unknown[];
  constructor(...args: unknown[]) {
    this.args = args;
  }
}

class FakeStreamConstructor {
  readonly tracks: unknown;
  constructor(tracks: unknown) {
    this.tracks = tracks;
  }
}

function scope(overrides: Record<string, unknown> = {}): BrowserAudioScope {
  return {
    AudioContext: FakeContextConstructor,
    AudioWorkletNode: FakeNodeConstructor,
    MediaStream: FakeStreamConstructor,
    setTimeout: jest.fn(() => 7),
    clearTimeout: jest.fn(),
    ...overrides,
  } as unknown as BrowserAudioScope;
}

describe("createBrowserAudioEnvironment", () => {
  it("AudioContext を、渡された設定で作る", () => {
    const environment = createBrowserAudioEnvironment(scope());

    const context = environment.createContext({ sampleRate: 44_100 }) as unknown as FakeContextConstructor;

    expect(context).toBeInstanceOf(FakeContextConstructor);
    expect(context.options).toEqual({ sampleRate: 44_100 });
  });

  it("AudioWorkletNode を、(コンテキスト・名前・設定) で作る", () => {
    const environment = createBrowserAudioEnvironment(scope());
    const context = {} as AudioContext;

    const node = environment.createWorkletNode(context, "stream-mixer", { numberOfInputs: 2 }) as unknown as FakeNodeConstructor;

    expect(node).toBeInstanceOf(FakeNodeConstructor);
    expect(node.args).toEqual([context, "stream-mixer", { numberOfInputs: 2 }]);
  });

  it("MediaStream を、トラックの配列（コピー）から作る", () => {
    const environment = createBrowserAudioEnvironment(scope());
    const tracks = [{} as MediaStreamTrack];

    const stream = environment.createMediaStream(tracks) as unknown as FakeStreamConstructor;

    expect(stream).toBeInstanceOf(FakeStreamConstructor);
    expect(stream.tracks).toEqual(tracks);
    expect(stream.tracks).not.toBe(tracks);
  });

  it("タイマは、渡されたものへ転送する（登録の識別子は、そのまま返す）", () => {
    const setTimeout = jest.fn(() => 7);
    const clearTimeout = jest.fn();
    const environment = createBrowserAudioEnvironment(scope({ setTimeout, clearTimeout }));
    const callback = jest.fn();

    const handle = environment.setTimeout(callback, 5000);
    environment.clearTimeout(handle);

    expect(handle).toBe(7);
    expect(setTimeout).toHaveBeenCalledWith(callback, 5000);
    expect(clearTimeout).toHaveBeenCalledWith(7);
  });

  it.each(["AudioContext", "AudioWorkletNode", "MediaStream"])("%s が無い環境は、使えない（unsupported）", (missing) => {
    let error: unknown;
    try {
      createBrowserAudioEnvironment(scope({ [missing]: undefined }));
    } catch (thrown) {
      error = thrown;
    }

    expect(error).toBeInstanceOf(AudioMixerError);
    expect((error as AudioMixerError).code).toBe("unsupported");
  });
});
