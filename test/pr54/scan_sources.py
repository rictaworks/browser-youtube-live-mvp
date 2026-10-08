#!/usr/bin/env python3
"""PR 54（issue #11 YouTube 接続: 段階的な認可・接続時の確認・再確認・チャンネル名のメモリ保持）のソースの走査。

走査の対象: この issue が作った・変更したファイル（アプリケーション・config・スペック）と、このディレクトリ。
確かめること（CI の hygiene と同じ規則を、コメントも含めて適用する）
  1. UTF-8 として読める
  2. 絵文字・不可視の書式文字（ゼロ幅スペース・異体字選択子・双方向制御文字・BOM）が無い
  3. 削除系コマンド・ファイルを消す呼び出しが無い（コメントを含む。語は、部品から組み立てて書く。このファイル自身も、素の語を持たない）
  4. 機密らしい値（秘密鍵・長い 16 進数の秘密値の代入・クラウドの鍵・Google のトークンの実物の形）が、直書きされていない
     （テストの値は、明らかなダミー）
  5. 秘密鍵のファイル（*.pem・*.key）が、リポジトリ（src/backend）に無い

--self-test: 合成した小さなソースで、走査器が、違反を見逃さず、違反でないものを誤検知しないことを確かめる。
使い方: scan_sources.py <リポジトリのルート> / scan_sources.py --self-test
終了コード: 0 = 問題なし / 1 = 違反あり / 2 = 引数・前提の誤り
"""
import re
import sys
import unicodedata
from pathlib import Path

BACKEND = "src/backend"

# --- 走査の対象（リポジトリのルートからの相対パス） ---
TARGET_FILES = [
    f"{BACKEND}/config/external_services.yml",
    f"{BACKEND}/config/youtube_connect.yml",
    f"{BACKEND}/config/routes.rb",
    f"{BACKEND}/config/initializers/filter_parameter_logging.rb",
    f"{BACKEND}/config/initializers/token_encryption_key.rb",
    f"{BACKEND}/config/initializers/zeitwerk_inflections.rb",
    f"{BACKEND}/app/controllers/api/youtube_controller.rb",
    f"{BACKEND}/app/controllers/api/error/broadcast_in_progress.rb",
    f"{BACKEND}/app/controllers/api/error/not_connected.rb",
    f"{BACKEND}/app/controllers/api/error/unverifiable.rb",
    f"{BACKEND}/app/controllers/dev/google_connect_controller.rb",
    f"{BACKEND}/app/gateways/oauth_grant.rb",
    f"{BACKEND}/app/gateways/google_oidc_client.rb",
    f"{BACKEND}/app/gateways/fake_google_oidc.rb",
    f"{BACKEND}/app/services/channel_name_cache.rb",
    f"{BACKEND}/app/services/rate_limiter.rb",
    f"{BACKEND}/app/services/recheck_gate.rb",
    f"{BACKEND}/app/services/youtube_connect_service.rb",
    f"{BACKEND}/spec/config/login_hint_filter_spec.rb",
    f"{BACKEND}/spec/config/token_encryption_key_spec.rb",
    f"{BACKEND}/spec/gateways/external_services_spec.rb",
    f"{BACKEND}/spec/gateways/fake_google_oidc_youtube_spec.rb",
    f"{BACKEND}/spec/gateways/google_oidc_client_youtube_spec.rb",
    f"{BACKEND}/spec/gateways/oauth_grant_spec.rb",
    f"{BACKEND}/spec/requests/api/youtube_connect_callback_spec.rb",
    f"{BACKEND}/spec/requests/api/youtube_connect_live_spec.rb",
    f"{BACKEND}/spec/requests/api/youtube_connect_start_spec.rb",
    f"{BACKEND}/spec/requests/api/youtube_login_policy_spec.rb",
    f"{BACKEND}/spec/requests/api/youtube_recheck_spec.rb",
    f"{BACKEND}/spec/requests/dev/google_connect_spec.rb",
    f"{BACKEND}/spec/services/channel_name_cache_spec.rb",
    f"{BACKEND}/spec/services/rate_limiter_peek_spec.rb",
    f"{BACKEND}/spec/services/recheck_gate_spec.rb",
    f"{BACKEND}/spec/services/youtube_connect_service_complete_spec.rb",
    f"{BACKEND}/spec/services/youtube_connect_service_concurrency_spec.rb",
    f"{BACKEND}/spec/services/youtube_connect_service_recheck_spec.rb",
    f"{BACKEND}/spec/services/youtube_connect_service_start_spec.rb",
    f"{BACKEND}/spec/sources/youtube_connect_sources_spec.rb",
    f"{BACKEND}/spec/support/youtube_connect_support.rb",
]
TARGET_DIRS = [
    f"{BACKEND}/app/views/dev/google_connect",
]

# --- 禁止する文字 ---
EMOJI_RANGES = [
    (0x1F000, 0x1FAFF),  # 麻雀牌・トランプ・国旗・絵文字・記号と絵
    (0x2600, 0x27BF),  # その他の記号・装飾記号
    (0x2B00, 0x2BFF),  # その他の記号と矢印（星・四角など）
    (0x2300, 0x23FF),  # その他の技術用記号
    (0x2900, 0x297F),  # 補助矢印
]
VARIATION_SELECTORS = (0xFE00, 0xFE0F)
TAG_CHARACTERS = (0xE0000, 0xE007F)


def forbidden_character(char):
    """禁止する文字なら、理由を返す。そうでなければ None"""
    code = ord(char)
    if any(low <= code <= high for low, high in EMOJI_RANGES):
        return "絵文字"
    if VARIATION_SELECTORS[0] <= code <= VARIATION_SELECTORS[1]:
        return "異体字選択子"
    if TAG_CHARACTERS[0] <= code <= TAG_CHARACTERS[1]:
        return "タグ文字"
    if code == 0x20E3:
        return "囲みキーキャップ"
    if unicodedata.category(char) == "Cf":
        return "不可視の書式文字"
    return None


# --- 削除系の語（部品から組み立てる。このファイルに、素の語を、識別子・文字列として書かない） ---
RM = "r" + "m"
RMDIR = "r" + "m" + "dir"
UNLINK = "un" + "link"
SHRED = "sh" + "red"
DELETE = "de" + "lete"
CLEAN = "cl" + "ean"
PRUNE = "pr" + "une"
DOWN = "do" + "wn"
RIMRAF = "rim" + "raf"
REMOVE = "re" + "move"
CLEAR = "cl" + "ear"
CLOBBER = "cl" + "obber"
DELETION_PATTERNS = [
    ("ファイル・ディレクトリを消すコマンド", re.compile(r"(?<![A-Za-z0-9_.-])(?:%s|%s|%s|%s)(?![A-Za-z0-9_./-])" % (RM, RMDIR, UNLINK, SHRED))),
    ("削除のオプション", re.compile(r"(?<![A-Za-z0-9_-])--?%s(?:-[a-z]+)?(?![A-Za-z0-9_-])" % DELETE)),
    ("git の削除系", re.compile(r"git\s+(?:%s|worktree\s+%s|branch\s+-[A-Za-z]*[dD])" % (CLEAN, REMOVE))),
    ("docker の削除系", re.compile(r"docker[^#\n]*\s%s(?![A-Za-z0-9_-])|(?<![A-Za-z0-9_-])--%s(?![A-Za-z0-9_-])" % (DOWN, RM))),
    ("不要な資源の一括削除", re.compile(r"(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])" % PRUNE)),
    (
        "言語・道具のファイル削除の呼び出し",
        re.compile(
            r"(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\.(?:%s\w*|[Rr]%s\w*|%s\w*|%s\w*)|%s"
            % (RM, REMOVE[1:], DELETE, UNLINK, RIMRAF)
        ),
    ),
    ("Rails のファイル削除タスク", re.compile(r"(?<![A-Za-z0-9_-])(?:(?:log|tmp):%s|assets:%s)(?![A-Za-z0-9_-])" % (CLEAR, CLOBBER))),
]

# 機密らしい値の直書き
SECRET_PATTERNS = [
    ("秘密鍵", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("クラウドの鍵", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Google の API キー", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    # 実物の形（ya29.・1//）でも、dummy を含む明らかなダミーは、テストの値として許す
    ("Google のアクセストークンの実物の形", re.compile(r"\bya29\.(?![0-9A-Za-z_-]*dummy)[0-9A-Za-z_-]{20,}")),
    ("Google の更新トークンの実物の形", re.compile(r"\b1//(?![0-9A-Za-z_-]*dummy)[0-9A-Za-z_-]{40,}")),
    ("GitHub のトークン", re.compile(r"\bgh[pousr]_[0-9A-Za-z]{30,}\b")),
    ("秘密値の代入", re.compile(r"(?i)\b(?:secret|password|token)\w*\s*[:=]\s*[\"'][0-9a-f]{40,}[\"']")),
]


def scan_text(text, label):
    """テキストの違反の一覧 [(位置, 分類, 内容)] を返す"""
    violations = []
    for number, line in enumerate(text.split("\n"), start=1):
        for index, char in enumerate(line):
            reason = forbidden_character(char)
            if reason:
                violations.append((f"{label}:{number}:{index + 1}", reason, f"U+{ord(char):04X}"))
        for name, pattern in DELETION_PATTERNS + SECRET_PATTERNS:
            if pattern.search(line):
                violations.append((f"{label}:{number}", name, line.strip()[:80]))
    return violations


def scan_file(path, root):
    label = str(path.relative_to(root))
    data = path.read_bytes()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        return [(label, "UTF-8 として読めない", str(error))]
    return scan_text(text, label)


def this_directory(root):
    """このスクリプトのあるディレクトリ（リポジトリのルートからの相対パス）。番号の置換・改名のあとでも、同じように解決する"""
    return Path(__file__).resolve().parent.relative_to(root)


def collect(root):
    files = [root / name for name in TARGET_FILES]
    for directory in TARGET_DIRS:
        files += sorted(path for path in (root / directory).rglob("*") if path.is_file())
    files += sorted(path for path in (root / this_directory(root)).rglob("*") if path.is_file() and "__pycache__" not in path.parts)
    return files


def key_files(root):
    """リポジトリの src/backend にある、秘密鍵のファイル（*.pem・*.key。依存・生成物・一時領域を除く）"""
    found = []
    for pattern in ("*.pem", "*.key"):
        for path in (root / BACKEND).rglob(pattern):
            relative = path.relative_to(root / BACKEND).parts
            if relative[0] in ("vendor", ".cache", "tmp", "log"):
                continue
            found.append(str(path.relative_to(root)))
    return found


def run(root):
    files = collect(root)
    missing = [str(path.relative_to(root)) for path in files if not path.is_file()]
    if missing:
        print("FAIL 走査の対象のファイルが無い（ファイル名の取り違えで、走査が空にならないための検査）:")
        for name in missing:
            print(f"  {name}")
        return 1

    violations = []
    for path in files:
        violations += scan_file(path, root)
    for name in key_files(root):
        violations.append((name, "秘密鍵のファイル", "リポジトリに置かない"))
    if violations:
        for location, kind, detail in violations:
            print(f"FAIL {location}: {kind}: {detail}")
        print(f"違反 {len(violations)} 件")
        return 1
    print(f"問題ありません（{len(files)} ファイルを走査しました。秘密鍵のファイルはありません）")
    return 0


# --- 自己検査 ---
def self_test():
    """合成したソースで、走査器が、違反を見逃さず、違反でないものを誤検知しないことを確かめる"""
    failures = []
    counts = {"違反": 0, "違反でないもの": 0}

    def expect(label, text, expected_kinds):
        counts["違反" if expected_kinds else "違反でないもの"] += 1
        found = {kind for _, kind, _ in scan_text(text, "synthetic")}
        if set(expected_kinds) != found:
            failures.append(f"{label}: 期待 {sorted(expected_kinds)} / 実際 {sorted(found)}")

    # 違反（見逃さない）
    expect("絵文字（1F600）", "x = '" + chr(0x1F600) + "'", ["絵文字"])
    expect("絵文字（2705）", "x = '" + chr(0x2705) + "'", ["絵文字"])
    expect("ゼロ幅スペース", "x = 'a" + chr(0x200B) + "b'", ["不可視の書式文字"])
    expect("BOM", chr(0xFEFF) + "x = 1", ["不可視の書式文字"])
    expect("異体字選択子", "x = 'a" + chr(0xFE0F) + "'", ["異体字選択子"])
    expect("双方向制御文字", "x = 'a" + chr(0x202E) + "b'", ["不可視の書式文字"])
    expect("削除のコマンド", f"{RM} -f x", ["ファイル・ディレクトリを消すコマンド"])
    expect("ディレクトリを消すコマンド", f"{RMDIR} x", ["ファイル・ディレクトリを消すコマンド"])
    expect("削除のオプション", f"find . --{DELETE}", ["削除のオプション"])
    expect("git の削除系", f"git {CLEAN} -fd", ["git の削除系"])
    expect("docker の削除系（down）", f"docker compose {DOWN}", ["docker の削除系"])
    expect("docker の削除系（実行後に消すオプション）", f"docker run --{RM} image", ["docker の削除系"])
    expect("一括削除", f"docker system {PRUNE}", ["不要な資源の一括削除"])
    expect("言語の呼び出し（Ruby）", f"FileUtils.{RM}_rf(path)", ["言語・道具のファイル削除の呼び出し"])
    expect("言語の呼び出し（File の削除メソッド）", f"File.{DELETE}(path)", ["言語・道具のファイル削除の呼び出し"])
    expect("Rails のファイル削除タスク（ログ）", f"bin/rails log:{CLEAR}", ["Rails のファイル削除タスク"])
    expect("Rails のファイル削除タスク（アセット）", f"bin/rails assets:{CLOBBER}", ["Rails のファイル削除タスク"])
    expect("秘密鍵", "-----BEGIN " + "RSA PRIVATE " + "KEY-----", ["秘密鍵"])
    expect("クラウドの鍵", "key = 'AKIA" + "A" * 16 + "'", ["クラウドの鍵"])
    expect("Google の API キー", "key = 'AIza" + "a" * 35 + "'", ["Google の API キー"])
    expect("Google のアクセストークンの実物の形", "token = 'ya" + "29." + "a" * 30 + "'", ["Google のアクセストークンの実物の形"])
    expect("Google の更新トークンの実物の形", "token = '1/" + "/" + "a" * 50 + "'", ["Google の更新トークンの実物の形"])
    expect("秘密値の代入", 'secret = "' + "a1" * 24 + '"', ["秘密値の代入"])

    # 違反でない（誤検知しない）
    expect("日本語・全角記号・矢印・点", "# 認可 URL → 確認・検査（接続）の順に評価する。…", [])
    expect("ダミーの秘密値（短い・明らかなダミー）", 'secret = "dummy-bff-shared-secret-for-specs-0001"', [])
    expect("ダミーのトークン（明らかなダミー）", "token = 'dummy-refresh-token-0001'", [])
    expect("実物の形のダミー（ya29.・1// で始まり、dummy を含む）", "a = 'ya" + "29.dummy-access-token-" + "a" * 30 + "'; r = '1/" + "/dummy-refresh-token-" + "a" * 40 + "'", [])
    expect("別の語に含まれる文字列（format・form・confirm）", "format('x'); form; confirm", [])
    expect("DB の行の削除のメソッド（ファイルではない）", "Connection.where(id: 1).%s_all" % DELETE, [])
    expect("HTTP のメソッド名（シンボル）", "stub_request(:%s, url)" % DELETE, [])
    expect("ハッシュの要素を捨てるメソッド（ファイルではない）", "@entries.%s(key)" % DELETE, [])
    expect("単語の一部（permit・remote・normal）", "remote_ip permit normal", [])
    expect("似た名前の語（Rails のタスクではない）", "log:level tmp:cache cleared_at", [])
    expect("ダミーの鍵の名前（ブロックなし）", "KID = 'dummy-key-id-0001'", [])
    expect("暗号鍵の形式の検査用のダミー（変数名に secret・password・token を含まない）", 'valid_key = "' + "0123456789abcdef" * 4 + '"', [])

    if failures:
        for message in failures:
            print(f"FAIL 自己検査: {message}")
        return 1
    print(f"自己検査: 合成したソース（違反 {counts['違反']} 件・違反でないもの {counts['違反でないもの']} 件）の判定が、すべて期待どおりでした")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 2:
        print("使い方: scan_sources.py <リポジトリのルート> | --self-test", file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    if not (root / "src" / "backend").is_dir():
        print(f"FAIL リポジトリのルートではありません: {root}", file=sys.stderr)
        return 2
    return run(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
