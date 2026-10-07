// SourceManager の状態の変化を、AudioMixer の混合対象の追加・解除へ伝える（requirements.md 11.2・13.1。issue #26）。
//   - マイク・共有音声が取得済みになったら、混合へ加える。喪失・解除・未取得・拒否・要求中になったら、混合から外す
//     （マイク・共有音声の喪失は、混合対象から外して継続する。皆無になれば、無音を生成し続ける）
//   - 配信中の追加・解除でも、AudioContext・Worklet・ストリームを再生成しない（接続だけを変える）
//   - 結びつけた時点で、すでに取得済みのソースも、加える
// 映像のソース（カメラ・画面共有）は、混合に関係しない（合成が、SourceManager の通知で、レイアウトを解決し直す）。
// 混合へ加えられないトラック（すでに終了しているなど）は、AudioMixer が例外にする。購読者の例外は、SourceManager が隔離して、例外の処理へ渡す。

import { isMixerInputKind, MIXER_INPUT_KINDS } from "./config";
import type { MixerInputKind } from "./config";
import type { ManagedSourceKind, SourceChangeListener, SourceHandle } from "@/lib/sources/types";

/** 結びつける側の、SourceManager の部分（テストで差し替えられる）。 */
export interface SourceBindingSource {
  getHandle(kind: ManagedSourceKind): SourceHandle;
  subscribe(listener: SourceChangeListener): () => void;
}

/** 結びつけられる側の、AudioMixer の部分。 */
export interface SourceBindingTarget {
  addSource(kind: MixerInputKind, track: MediaStreamTrack): void;
  removeSource(kind: MixerInputKind): void;
}

/** 結びつける。結びつけの解除の関数を返す（混合器のソースは、外さない。外すのは、混合器の stop・呼び出し元）。 */
export function bindSourcesToMixer(source: SourceBindingSource, mixer: SourceBindingTarget): () => void {
  const sync = (kind: MixerInputKind, handle: SourceHandle): void => {
    if (handle.state === "active" && handle.track !== null) {
      mixer.addSource(kind, handle.track);
    } else {
      mixer.removeSource(kind);
    }
  };

  for (const kind of MIXER_INPUT_KINDS) {
    sync(kind, source.getHandle(kind));
  }
  return source.subscribe((change) => {
    if (isMixerInputKind(change.kind)) {
      sync(change.kind, change.current);
    }
  });
}
