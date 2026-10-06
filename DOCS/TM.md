# TM（テストメソッドとフレームワーク概要）

# 🧪 テストメソッド（Test Method）

最終更新: 2025-11-10

---

テストメソッドとは、ソフトウェアを検証するための**具体的な手法**を指します。目的や対象に応じて複数のアプローチがあります。

### 主なテストメソッド

| 種類 | 内容 | 目的 |
| --- | --- | --- |
| **ブラックボックステスト** | 内部構造を考慮せず、入力と出力の関係を確認 | 機能要件の確認 |
| **ホワイトボックステスト** | 内部構造・コードの分岐を基にテスト設計 | 実装の正確性検証 |
| **グレーボックステスト** | 一部構造を理解した上で実施 | 複雑な連携部分の確認 |
| **単体テスト（Unit Test）** | 関数やメソッドなど最小単位の検証 | コード単体の品質担保 |
| **結合テスト（Integration Test）** | 複数モジュールの連携動作を検証 | モジュール間の整合性確認 |
| **システムテスト（System Test）** | システム全体としての動作検証 | 仕様・要件通りに動くか確認 |
| **受け入れテスト（Acceptance Test）** | 実際の利用者視点での検証 | ビジネス要件・ユーザ体験の確認 |

---

## 🧰 テストフレームワーク（Test Framework）

テストを効率化・自動化するための仕組みやライブラリ。

各プログラミング言語・環境に合わせた代表的なものがあります。

| 言語 | フレームワーク例 | 説明 |
| --- | --- | --- |
| **Java** | JUnit, TestNG | 最も有名なユニットテストフレームワーク。CIツールと統合しやすい。 |
| **Python** | pytest, unittest | シンプルで柔軟な記法が特徴。pytestは特に人気。 |
| **JavaScript** | Jest, Mocha, Jasmine | フロントエンドやNode.js環境で使用。Jestは設定不要で強力。 |
| **C# (.NET)** | xUnit, NUnit | Microsoft環境向け。xUnitはモダン設計。 |
| **Ruby** | RSpec, Minitest | 自然言語に近い構文で読みやすい。 |
| **PHP** | PHPUnit | PHPにおける定番。LaravelやSymfonyと統合可能。 |
| **E2E / UIテスト** | Playwright, Cypress | ブラウザ操作を自動化し、実際のユーザー体験を再現して検証できる。 |

---

## ⚙️ テストメソッド × フレームワークの関係

例：**JUnit（Java）** の場合

```java
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class CalculatorTest {
    @Test
    void add_returnsCorrectSum() {
        Calculator calc = new Calculator();
        assertEquals(5, calc.add(2, 3));
    }
}

```

- `@Test` ：テストメソッドを示すアノテーション
- **JUnit** ：テストフレームワーク

---

## 🎭 Playwright とは？

**Playwright** は、Microsoft が開発した**ブラウザ自動操作・E2Eテスト**用のフレームワークです。Chromium / Firefox / WebKit の 3 大エンジンを同一APIで操作でき、**マルチブラウザ対応**と**安定性**に優れています。

### 特徴

- 複数ブラウザでの自動テストを一元的に実行可能
- ユーザー操作（クリック・入力・キー操作）を正確に再現
- スクリーンショット比較や動画保存に対応
- 並列実行が可能で高速
- TypeScript/JavaScript/Java/Python/C# に対応

### 例：E2Eテストコード

```tsx
import { test, expect } from '@playwright/test';

test('ユーザーがログインできること', async ({ page }) => {
  await page.goto('https://example.com/login');
  await page.fill('#username', 'testuser');
  await page.fill('#password', 'secret');
  await page.click('button[type="submit"]');
  await expect(page.locator('h1')).toHaveText('Welcome, testuser');
});

```

### 活用用途

- SPA / PWA の統合・回帰テスト
- ゲームライクなUIの操作テスト（キー操作・アニメーション確認）
- 主要導線（ログイン、スコア送信、ページ遷移など）の自動チェック

---

## 💡 まとめ

- テストメソッドは「**どのようにテストするか**」の考え方。
- テストフレームワークは「**どうやって自動化・効率化するか**」のツール。
- **Playwright** は実ブラウザでの動作を再現し、E2Eレベルの品質を担保するための強力な補完ツール。