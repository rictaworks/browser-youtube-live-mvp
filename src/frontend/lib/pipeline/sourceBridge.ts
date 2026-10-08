// SourceChange（#26）をパイプラインの映像ソースの追加・解除へ反映する薄い層（requirements.md 11.2・11.3・13.1。issue #27）。
// 配信の制御（#28）・画面（#29）は、SourceManager.subscribe のリスナーの中で、これを呼ぶ。
//
//   取得済み（active）になった映像ソース（カメラ・画面共有）  トラックを追加する（addVideoSource）
//   取得済みでなくなった映像ソース（喪失・解除）            外す（removeVideoSource）。トラックは止めない（止めるのはマネージャ。#26）
//   それ以外の変化（要求中・拒否・取り消し）                何もしない（unchanged）
//   音声のソース（マイク・共有音声）                        何もしない（ignored。音声は、ミキサーが扱う）
//
// レイアウトは、変化のあとの SourceChange.layout を、そのまま返す（ここで解決し直さない。解決の規則は core の resolveLayout で、マネージャが適用済み）。
// ワーカー側の合成が選ぶレイアウトも、同じ規則（有効な映像ソースの組）から決まるので、SourceChange.layout と一致する（loopback.test.ts が確かめる）。
//
// 推測して続けない: 取得済みなのにトラックが無い記録・知らない種別は RangeError。パイプラインが拒否したら（終了したトラックなど）、そのまま伝える。

import type { Layout } from "@/core/contract";
import { isManagedSourceKind } from "@/lib/sources/types";
import type { SourceChange } from "@/lib/sources/types";
import { isVideoSourceKind } from "@/workers/pipeline/FrameStore";
import type { VideoSourceKind } from "@/workers/pipeline/FrameStore";

/** 映像ソースの追加・解除を受ける側（PipelineClient が満たす）。 */
export interface VideoSourceTarget {
  addVideoSource(kind: VideoSourceKind, track: MediaStreamTrack): void;
  removeVideoSource(kind: VideoSourceKind): void;
}

/**
 * 反映の結果。
 *   added      トラックを追加した
 *   removed    パイプラインから外した
 *   unchanged  映像ソースだが、取得済みへの変化でも、取得済みからの変化でもない（何もしない）
 *   ignored    音声のソース（何もしない）
 */
export type BridgeOutcome = "added" | "removed" | "unchanged" | "ignored";

export interface BridgeResult {
  readonly outcome: BridgeOutcome;
  /** 変化のあとのレイアウト（SourceChange.layout） */
  readonly layout: Layout;
}

export function applySourceChange(target: VideoSourceTarget, change: SourceChange): BridgeResult {
  if (!isManagedSourceKind(change.kind)) {
    throw new RangeError(`unknown source kind: ${String(change.kind)}`);
  }
  const layout = change.layout;
  if (!isVideoSourceKind(change.kind)) {
    return { outcome: "ignored", layout };
  }
  const kind = change.kind;
  if (change.current.state === "active") {
    const track = change.current.track;
    if (track === null) {
      throw new RangeError(`an active ${kind} source must have a track`);
    }
    target.addVideoSource(kind, track);
    return { outcome: "added", layout };
  }
  if (change.previous.state === "active") {
    target.removeVideoSource(kind);
    return { outcome: "removed", layout };
  }
  return { outcome: "unchanged", layout };
}
