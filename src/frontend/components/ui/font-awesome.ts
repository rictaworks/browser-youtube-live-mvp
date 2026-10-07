import { config } from "@fortawesome/fontawesome-svg-core";
// FontAwesome の CSS（.svg-inline--fa など）は、ここで読み込む。ランタイムの <style> 注入（autoAddCss）は止める。
// 注入のままだと、サーバーが描画した直後は CSS が無く、アイコンが巨大に表示される（一瞬）ため。
import "@fortawesome/fontawesome-svg-core/styles.css";

/** FontAwesome の CSS の自動注入を止める。CSS は、上の import でビルドに含める。 */
export function disableFontAwesomeAutoCss(): void {
  config.autoAddCss = false;
}
