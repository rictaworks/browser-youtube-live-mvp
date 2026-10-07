// 音声の混合（AudioMixer・bindSourcesToMixer）のテストの共通部品。テストからだけ使う（実行時のコードから import しない）。
//
// モックの境界: AudioContext・AudioWorkletNode・MediaStreamAudioSourceNode・MediaStreamAudioDestinationNode・MessagePort・タイマは、すべて疑似。
// グラフの接続（どのノードが、どのノードの、どの入力へつながったか）と、呼び出しの順序を記録する。実際に音声は流れない
// （数値処理は、Worklet のファイルを疑似のスコープで実行するテスト（streamMixerProcessor.test.ts）で保証し、実ブラウザの確認は test/ の実機の確認）。
import { FakeStream, deferred } from "@/lib/sources/test-support";
import type { Deferred, FakeTrack } from "@/lib/sources/test-support";
import type { AudioEnvironment } from "./environment";

export interface Connection {
  readonly destination: FakeAudioNode;
  readonly output: number | undefined;
  readonly input: number | undefined;
}

/** AudioNode の疑似。出力側の接続を記録する。 */
export class FakeAudioNode {
  readonly connections: Connection[] = [];
  disconnectCount = 0;

  connect(destination: FakeAudioNode, output?: number, input?: number): FakeAudioNode {
    this.connections.push({ destination, output, input });
    return destination;
  }

  /** 引数なしの AudioNode.disconnect()。出力側の接続をすべて外す。 */
  disconnect(): void {
    this.connections.length = 0;
    this.disconnectCount += 1;
  }
}

/** MediaStreamAudioSourceNode の疑似。 */
export class FakeSourceNode extends FakeAudioNode {
  readonly stream: FakeStream;

  constructor(stream: FakeStream) {
    super();
    this.stream = stream;
  }
}

/** MediaStreamAudioDestinationNode の疑似（出力デバイスではない。グラフの終端で、ノードが処理され続けるようにするためのもの）。 */
export class FakeSinkNode extends FakeAudioNode {}

interface PostedMessage {
  readonly data: unknown;
  readonly transfer: readonly unknown[];
}

/** AudioWorkletNode.port の疑似。メインスレッドから送ったコマンドを記録する。Worklet からのメッセージは、receive で疑似する。 */
export class FakeNodePort {
  onmessage: ((event: MessageEvent) => void) | null = null;
  readonly posted: PostedMessage[] = [];

  postMessage(data: unknown, transfer: readonly unknown[] = []): void {
    this.posted.push({ data, transfer });
  }

  /** Worklet からメッセージが届いたことを疑似する。 */
  receive(data: unknown): void {
    this.onmessage?.({ data } as MessageEvent);
  }
}

/** AudioWorkletNode の疑似。 */
export class FakeWorkletNode extends FakeAudioNode {
  readonly name: string;
  readonly options: AudioWorkletNodeOptions;
  readonly port = new FakeNodePort();
  private readonly processorErrorListeners = new Set<EventListener>();

  constructor(name: string, options: AudioWorkletNodeOptions) {
    super();
    this.name = name;
    this.options = options;
  }

  addEventListener(type: string, listener: EventListener): void {
    if (type === "processorerror") {
      this.processorErrorListeners.add(listener);
    }
  }

  removeEventListener(type: string, listener: EventListener): void {
    if (type === "processorerror") {
      this.processorErrorListeners.delete(listener);
    }
  }

  get processorErrorListenerCount(): number {
    return this.processorErrorListeners.size;
  }

  /** プロセッサの例外（processorerror）を起こす。 */
  failProcessor(): void {
    for (const listener of [...this.processorErrorListeners]) {
      listener(new Event("processorerror"));
    }
  }

  /** コマンドとして送られたメッセージだけを、取り出す。 */
  get commands(): unknown[] {
    return this.port.posted.map((message) => message.data);
  }
}

export interface FakeContextBehavior {
  /** 実際の sampleRate（既定は、要求した値） */
  readonly sampleRate?: number;
  /** 作った直後の状態。既定は suspended（自動再生の制限で、利用者の操作まで止まっている状態） */
  readonly initialState?: AudioContextState;
  /**
   * resume() の挙動。run = 実行状態になって解決（既定）・blocked = 解決も拒否もしない（自動再生の制限で止まったまま）・
   * reject = 拒否・stay_suspended = 解決するが、状態は suspended のまま
   */
  readonly resume?: "run" | "blocked" | "reject" | "stay_suspended";
  /** audioWorklet.addModule の挙動。resolve（既定）・reject・pending（addModuleControl で解決・拒否する） */
  readonly addModule?: "resolve" | "reject" | "pending";
  /** audioWorklet が無い環境（セキュアでない文脈）の疑似 */
  readonly withoutAudioWorklet?: boolean;
}

/** AudioContext の疑似。 */
export class FakeAudioContext extends EventTarget {
  state: AudioContextState;
  readonly sampleRate: number;
  readonly destination = new FakeAudioNode();
  readonly audioWorklet: { addModule(url: string): Promise<void> } | undefined;
  readonly callLog: string[] = [];
  readonly sources: FakeSourceNode[] = [];
  readonly sinks: FakeSinkNode[] = [];
  readonly addModuleControl: Deferred<void> = deferred<void>();
  closeCount = 0;
  private readonly behavior: FakeContextBehavior;

  constructor(options: AudioContextOptions, behavior: FakeContextBehavior = {}) {
    super();
    this.behavior = behavior;
    this.sampleRate = behavior.sampleRate ?? options.sampleRate ?? 48_000;
    this.state = behavior.initialState ?? "suspended";
    this.audioWorklet = behavior.withoutAudioWorklet === true ? undefined : { addModule: (url) => this.addModule(url) };
  }

  /** 状態を変えて、statechange を起こす（端末の休止・音声出力の中断・再開の疑似）。 */
  setState(state: AudioContextState): void {
    this.state = state;
    this.dispatchEvent(new Event("statechange"));
  }

  createMediaStreamSource(stream: FakeStream): FakeSourceNode {
    const node = new FakeSourceNode(stream);
    this.sources.push(node);
    return node;
  }

  createMediaStreamDestination(): FakeSinkNode {
    const node = new FakeSinkNode();
    this.sinks.push(node);
    return node;
  }

  resume(): Promise<void> {
    this.callLog.push("resume");
    switch (this.behavior.resume ?? "run") {
      case "run":
        this.setState("running");
        return Promise.resolve();
      case "blocked":
        return new Promise<void>(() => undefined);
      case "reject":
        return Promise.reject(new DOMException("closed", "InvalidStateError"));
      case "stay_suspended":
        return Promise.resolve();
    }
  }

  close(): Promise<void> {
    this.callLog.push("close");
    this.closeCount += 1;
    this.setState("closed");
    return Promise.resolve();
  }

  private addModule(url: string): Promise<void> {
    this.callLog.push(`addModule:${url}`);
    switch (this.behavior.addModule ?? "resolve") {
      case "resolve":
        return Promise.resolve();
      case "reject":
        return Promise.reject(new DOMException("failed to load LABEL-SECRET-MODULE", "AbortError"));
      case "pending":
        return this.addModuleControl.promise;
    }
  }
}

interface PendingTimer {
  readonly callback: () => void;
  readonly milliseconds: number;
}

/** AudioEnvironment の疑似。作ったコンテキスト・ノードを記録し、タイマを手で進める。 */
export class FakeAudioEnvironment {
  readonly contexts: FakeAudioContext[] = [];
  readonly contextOptions: AudioContextOptions[] = [];
  readonly workletNodes: FakeWorkletNode[] = [];
  readonly mediaStreams: FakeStream[] = [];
  behavior: FakeContextBehavior = {};
  /** 設定すると、createWorkletNode が、この値を投げる */
  workletNodeError: unknown = null;
  /** 設定すると、createContext が、この値を投げる */
  contextError: unknown = null;
  private readonly timers = new Map<number, PendingTimer>();
  private nextTimer = 1;

  /** 最後に作ったコンテキスト */
  get context(): FakeAudioContext {
    const context = this.contexts[this.contexts.length - 1];
    if (context === undefined) {
      throw new Error("no AudioContext was created");
    }
    return context;
  }

  /** 最後に作った Worklet のノード */
  get node(): FakeWorkletNode {
    const node = this.workletNodes[this.workletNodes.length - 1];
    if (node === undefined) {
      throw new Error("no AudioWorkletNode was created");
    }
    return node;
  }

  createContext(options: AudioContextOptions): FakeAudioContext {
    this.contextOptions.push(options);
    if (this.contextError !== null) {
      throw this.contextError;
    }
    const context = new FakeAudioContext(options, this.behavior);
    this.contexts.push(context);
    return context;
  }

  createWorkletNode(_context: FakeAudioContext, name: string, options: AudioWorkletNodeOptions): FakeWorkletNode {
    if (this.workletNodeError !== null) {
      throw this.workletNodeError;
    }
    const node = new FakeWorkletNode(name, options);
    this.workletNodes.push(node);
    return node;
  }

  createMediaStream(tracks: readonly MediaStreamTrack[]): FakeStream {
    // 疑似のトラック（FakeTrack）は、asTrack() が自分自身を返すので、渡された物は、FakeTrack そのもの
    const stream = new FakeStream(tracks as unknown as FakeTrack[]);
    this.mediaStreams.push(stream);
    return stream;
  }

  setTimeout(callback: () => void, milliseconds: number): number {
    const handle = this.nextTimer;
    this.nextTimer += 1;
    this.timers.set(handle, { callback, milliseconds });
    return handle;
  }

  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number);
  }

  /** 登録されているタイマの数 */
  get pendingTimerCount(): number {
    return this.timers.size;
  }

  /** 登録されているタイマの待ち時間（ミリ秒） */
  get pendingTimerDelays(): number[] {
    return [...this.timers.values()].map((timer) => timer.milliseconds);
  }

  /** 登録されているタイマを、すべて満了させる。 */
  fireTimers(): void {
    const due = [...this.timers.entries()];
    this.timers.clear();
    for (const [, timer] of due) {
      timer.callback();
    }
  }

  asEnvironment(): AudioEnvironment {
    return this as unknown as AudioEnvironment;
  }

  /** どのノードからも、指定のノードへの接続が無い（出力先（destination）へつながっていないことの検査に使う）。 */
  connectionsInto(target: FakeAudioNode): { from: FakeAudioNode; connection: Connection }[] {
    const nodes: FakeAudioNode[] = [...this.workletNodes];
    for (const context of this.contexts) {
      nodes.push(...context.sources, ...context.sinks);
    }
    return nodes.flatMap((node) => node.connections.filter((connection) => connection.destination === target).map((connection) => ({ from: node, connection })));
  }
}
