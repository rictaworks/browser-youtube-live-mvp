// レイアウトの解決（requirements.md 11.3）。レイアウトは利用者が編集せず、有効な映像ソースの組から一意に決まる。
//
//   画面共有 | カメラ | レイアウト
//   あり     | あり   | 画面共有を主映像、カメラをワイプ（screen_with_wipe）
//   あり     | なし   | 画面共有のみ（screen_only）
//   なし     | あり   | カメラのみ（camera_only）
//   なし     | なし   | 代替スレート（slate）
//
// 「あり」は、ソースの状態が取得済み（active）のときだけ。喪失（lost）・拒否（denied）・要求中・未取得は、有効な映像ソースとして数えない。

import { isSourceState } from "../contract";
import type { Layout, SourceState } from "../contract";

/** 映像ソース（画面共有・カメラ）の状態。 */
export interface VideoSourceStates {
  readonly screen: SourceState;
  readonly camera: SourceState;
}

function assertSourceState(value: unknown, name: string): asserts value is SourceState {
  if (!isSourceState(value)) {
    throw new RangeError(`${name} is not a source state: ${String(value)}`);
  }
}

/** 映像ソースの状態の組から、レイアウトを一意に決める。未知の状態は、推測せず RangeError。 */
export function resolveLayout(sources: VideoSourceStates): Layout {
  const { screen, camera } = sources;
  assertSourceState(screen, "screen");
  assertSourceState(camera, "camera");

  const hasScreen = screen === "active";
  const hasCamera = camera === "active";
  if (hasScreen && hasCamera) {
    return "screen_with_wipe";
  }
  if (hasScreen) {
    return "screen_only";
  }
  if (hasCamera) {
    return "camera_only";
  }
  return "slate";
}
