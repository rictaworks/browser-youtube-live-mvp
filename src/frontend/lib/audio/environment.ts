// AudioEnvironment（issue #26）。AudioMixer が使う、ブラウザの AudioContext・AudioWorkletNode・MediaStream・タイマを、注入できる形にしたもの。
// テストでは、疑似の環境（test-support.ts）を渡す。ブラウザでは、createBrowserAudioEnvironment(window) で作る。
// 大域（window など）を、AudioMixer が直接参照しない（実時計・タイマも、この環境から受け取る）。

import { AudioMixerError } from "./errors";

export interface AudioEnvironment {
  createContext(options: AudioContextOptions): AudioContext;
  createWorkletNode(context: AudioContext, name: string, options: AudioWorkletNodeOptions): AudioWorkletNode;
  createMediaStream(tracks: readonly MediaStreamTrack[]): MediaStream;
  /** 期限の監視（start の待ち時間）だけに使う。音声の時刻の採番には使わない（累積サンプル数だけ） */
  setTimeout(callback: () => void, milliseconds: number): unknown;
  clearTimeout(handle: unknown): void;
}

/** window に当たるオブジェクト。各機能が無い環境は、undefined。 */
export interface BrowserAudioScope {
  readonly AudioContext?: typeof AudioContext;
  readonly AudioWorkletNode?: typeof AudioWorkletNode;
  readonly MediaStream?: typeof MediaStream;
  setTimeout(callback: () => void, milliseconds: number): number;
  clearTimeout(handle: number): void;
}

/** ブラウザの環境を作る。AudioContext・AudioWorkletNode・MediaStream のどれかが無ければ、使えない環境として、型付きのエラー（unsupported）。 */
export function createBrowserAudioEnvironment(scope: BrowserAudioScope): AudioEnvironment {
  const ContextConstructor = scope.AudioContext;
  const NodeConstructor = scope.AudioWorkletNode;
  const StreamConstructor = scope.MediaStream;
  if (typeof ContextConstructor !== "function" || typeof NodeConstructor !== "function" || typeof StreamConstructor !== "function") {
    throw new AudioMixerError("unsupported");
  }
  return {
    createContext: (options) => new ContextConstructor(options),
    createWorkletNode: (context, name, options) => new NodeConstructor(context, name, options),
    createMediaStream: (tracks) => new StreamConstructor([...tracks]),
    setTimeout: (callback, milliseconds) => scope.setTimeout(callback, milliseconds),
    clearTimeout: (handle) => {
      scope.clearTimeout(handle as number);
    },
  };
}
