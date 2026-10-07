// AudioWorklet のプロセッサ（public/worklets/stream-mixer-processor.js）を、疑似の AudioWorkletGlobalScope で実行する、テストの道具。
// テストからだけ使う（実行時のコードから import しない。node:vm・node:fs を使う）。
//
// モックの境界: 実ブラウザの AudioWorkletGlobalScope・AudioWorkletProcessor・MessagePort は、疑似（下の FakeMessagePort など）。
// Worklet のファイルそのものを、Node の vm のコンテキストで実行する（TypeScript へ書き写したものではない）。
// 疑似のスコープでは、Date と performance を、使った瞬間に失敗する物へ差し替えてある（音声の時刻採番に、実時計を使わないことの保証）。
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

/** Worklet のモジュール（public/worklets/stream-mixer-processor.js）の、絶対パス。 */
export const WORKLET_MODULE_PATH = path.resolve(__dirname, "../../public/worklets/stream-mixer-processor.js");

export interface PostedMessage {
  readonly data: unknown;
  readonly transfer: readonly unknown[];
}

interface DeliveredEvent {
  readonly data: unknown;
  readonly ports: readonly unknown[];
}

/** MessagePort の疑似。送ったメッセージを記録する。相手からのメッセージは、deliver で、onmessage へ渡す。 */
export class FakeMessagePort {
  onmessage: ((event: DeliveredEvent) => void) | null = null;
  readonly posted: PostedMessage[] = [];

  postMessage(data: unknown, transfer: readonly unknown[] = []): void {
    this.posted.push({ data, transfer });
  }

  deliver(data: unknown, ports: readonly unknown[] = []): void {
    if (this.onmessage === null) {
      throw new Error("the processor did not set port.onmessage");
    }
    this.onmessage({ data, ports });
  }
}

interface ProcessorInstance {
  readonly port: FakeMessagePort;
  process(inputs: Float32Array[][], outputs: Float32Array[][], parameters: Record<string, Float32Array>): boolean;
}

type ProcessorConstructor = new (options: unknown) => ProcessorInstance;

export interface WorkletProcessorHandle {
  /** プロセッサの port（Worklet 側）。Worklet が、メインスレッドへ送るメッセージが、posted に溜まる。 */
  readonly port: FakeMessagePort;
  /** メインスレッドから届いたコマンドとして、onmessage へ渡す（ports は、転送された MessagePort）。 */
  command(data: unknown, ports?: readonly unknown[]): void;
  /** process() を 1 回呼ぶ。outputs を省くと、2 チャンネル × frames の出力を作って渡す。 */
  process(inputs: Float32Array[][], frames?: number): boolean;
}

export interface LoadedWorklet {
  /** registerProcessor へ渡された名前 */
  readonly registeredName: string;
  /** ファイルの内容 */
  readonly source: string;
  /** registerProcessor の呼び出し回数 */
  readonly registrationCount: number;
  /** プロセッサを作る（processorOptions は、AudioWorkletNode の processorOptions に当たる） */
  create(processorOptions: unknown): WorkletProcessorHandle;
}

/** 使った瞬間に失敗する物（実時計の疑似）。 */
function thrower(name: string): unknown {
  const fail = (): never => {
    throw new Error(`${name} must not be used in the worklet (no wall clock for audio timing)`);
  };
  return new Proxy(function forbidden() {}, { get: fail, construct: fail, apply: fail });
}

/** Worklet のファイルを、疑似のスコープで実行して、登録されたプロセッサを取り出す。 */
export function loadStreamMixerWorklet(): LoadedWorklet {
  const source = fs.readFileSync(WORKLET_MODULE_PATH, "utf8");
  let pendingPort: FakeMessagePort | null = null;

  class FakeAudioWorkletProcessor {
    readonly port: FakeMessagePort;

    constructor() {
      if (pendingPort === null) {
        throw new Error("a processor must be created through the harness");
      }
      this.port = pendingPort;
    }
  }

  const registrations: { name: string; processor: ProcessorConstructor }[] = [];
  const sandbox = {
    AudioWorkletProcessor: FakeAudioWorkletProcessor,
    registerProcessor: (name: string, processor: ProcessorConstructor): void => {
      registrations.push({ name, processor });
    },
    sampleRate: 44_100,
    currentFrame: 0,
    currentTime: 0,
    Date: thrower("Date"),
    performance: thrower("performance"),
  };
  vm.runInContext(source, vm.createContext(sandbox), { filename: WORKLET_MODULE_PATH });

  if (registrations.length !== 1) {
    throw new Error(`the worklet must register exactly one processor: ${registrations.length}`);
  }
  const [{ name, processor }] = registrations;

  return {
    registeredName: name,
    source,
    registrationCount: registrations.length,
    create(processorOptions: unknown): WorkletProcessorHandle {
      pendingPort = new FakeMessagePort();
      let instance: ProcessorInstance;
      try {
        instance = new processor({ processorOptions });
      } finally {
        pendingPort = null;
      }
      return {
        port: instance.port,
        command(data, ports = []) {
          instance.port.deliver(data, ports);
        },
        process(inputs, frames = 128) {
          const outputs = [[new Float32Array(frames), new Float32Array(frames)]];
          return instance.process(inputs, outputs, {});
        },
      };
    },
  };
}
