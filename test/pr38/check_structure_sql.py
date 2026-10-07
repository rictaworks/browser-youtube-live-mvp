#!/usr/bin/env python3
"""db/structure.sql を、ファイルとして検査する（DB へ接続しない。読み取りのみ）。

使い方: python3 -I check_structure_sql.py <リポジトリのルート>
終了コード: 0 = すべて成功 / 1 = 失敗がある

RSpec（src/backend/spec/models/schema/）は、structure.sql から作ったテスト用 DB のカタログを検査する。
これは、コミットされるファイルそのものを、別の実装（Python）で、独立に検査する。

  1. 15 テーブルの、列の名前・型・NULL 可否・既定値・主キー（requirements.md 21 章の ER 図から書き起こした表）
  2. 列挙の CHECK 制約の符号が、契約（src/contracts/enums.json・http-api.md）と一致する
  3. 件数・量の CHECK 制約・月の形・タイトルの寿命の CHECK 制約
  4. 索引（部分一意索引を含む）
  5. 外部キーと、削除時の動作（連鎖・NULL 化・既定）
  6. schema_migrations の版が、db/migrate のファイルと一致する。データの INSERT は、それだけ
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1])
STRUCTURE = os.path.join(ROOT, "src/backend/db/structure.sql")
MIGRATE_DIR = os.path.join(ROOT, "src/backend/db/migrate")
ENUMS_JSON = os.path.join(ROOT, "src/contracts/enums.json")
HTTP_API_MD = os.path.join(ROOT, "src/contracts/http-api.md")

UUID, STRING, TEXT, INTEGER, BIGINT, BOOLEAN, DATE = "uuid", "character varying", "text", "integer", "bigint", "boolean", "date"
DATETIME = "timestamp(6) without time zone"
INTERNAL_TABLES = {"schema_migrations", "ar_internal_metadata"}

failures = []
checks = 0


def ok(message):
    global checks
    checks += 1
    print(f"ok   {message}")


def ng(message):
    global checks
    checks += 1
    failures.append(message)
    print(f"FAIL {message}")


def check(condition, message):
    ok(message) if condition else ng(message)


def required(type_, default=None):
    return (type_, False, default)


def optional(type_):
    return (type_, True, None)


PRIMARY_UUID = required(UUID, "gen_random_uuid()")

# requirements.md 21 章の ER 図。列 => (型, NULL 可, 既定値)。NULL 可否の規則は、src/backend/spec/support/expected_schema.rb の冒頭
ER = {
    "users": {"id": PRIMARY_UUID, "google_sub": required(STRING), "created_at": required(DATETIME), "last_login_at": required(DATETIME)},
    "sessions": {
        "id": PRIMARY_UUID, "user_id": required(UUID), "token_digest": required(STRING), "created_at": required(DATETIME),
        "last_used_at": required(DATETIME), "expires_at": required(DATETIME),
    },
    "youtube_connections": {
        "id": PRIMARY_UUID, "user_id": required(UUID), "state": required(STRING), "refresh_token_ciphertext": required(TEXT),
        "youtube_stream_id": optional(STRING), "stream_verified_at": optional(DATETIME), "connected_at": required(DATETIME),
        "last_verified_at": required(DATETIME),
    },
    "broadcasts": {
        "id": PRIMARY_UUID, "user_id": required(UUID), "daily_usage_id": required(UUID), "state": required(STRING, "reserved"),
        "end_reason": optional(STRING), "settlement_state": required(STRING, "none"), "settlement_attempts": required(INTEGER, "0"),
        "usage_date": required(DATE), "quota_date": required(DATE), "prep_reserved_units": required(INTEGER, "0"),
        "settle_reserved_units": required(INTEGER, "0"), "attempt_counted": required(BOOLEAN, "false"),
        "resume_count": required(INTEGER, "0"), "sent_bytes": required(BIGINT, "0"), "profile": optional(STRING),
        "publisher_epoch": required(INTEGER, "0"), "pending_title": optional(STRING), "scheduled_start_at": optional(DATETIME),
        "privacy_status": required(STRING), "made_for_kids": required(BOOLEAN), "youtube_broadcast_id": optional(STRING),
        "youtube_stream_id": optional(STRING), "bound": required(BOOLEAN, "false"), "allowance_consumed": required(BOOLEAN, "false"),
        "accepted_at": required(DATETIME), "provisioned_at": optional(DATETIME), "publish_started_at": optional(DATETIME),
        "live_at": optional(DATETIME), "interrupted_at": optional(DATETIME), "last_heartbeat_at": optional(DATETIME),
        "last_checked_at": optional(DATETIME), "ended_at": optional(DATETIME),
    },
    "daily_usages": {
        "id": PRIMARY_UUID, "user_id": required(UUID), "usage_date": required(DATE), "consumed_count": required(INTEGER, "0"),
        "attempt_count": required(INTEGER, "0"), "extra_grants": required(INTEGER, "0"),
    },
    "relay_tickets": {
        "id": PRIMARY_UUID, "user_id": required(UUID), "broadcast_id": required(UUID), "token_digest": required(STRING),
        "epoch": required(INTEGER), "expires_at": required(DATETIME), "used_at": optional(DATETIME),
    },
    "health_samples": {
        "id": PRIMARY_UUID, "user_id": required(UUID), "broadcast_id": required(UUID), "sampled_at": required(DATETIME),
        "sent_kbps": optional(INTEGER), "target_kbps": optional(INTEGER), "backlog_ms": optional(INTEGER),
        "dropped_video_frames": optional(INTEGER), "relay_out_kbps": optional(INTEGER), "state": optional(STRING),
    },
    "broadcast_events": {
        "id": PRIMARY_UUID, "user_id": required(UUID), "broadcast_id": required(UUID), "occurred_at": required(DATETIME),
        "event_type": required(STRING), "detail": optional(STRING),
    },
    "usage_events": {
        "id": PRIMARY_UUID, "user_id": optional(UUID), "occurred_at": required(DATETIME), "event_type": required(STRING),
        "reason_code": optional(STRING), "bucket": optional(STRING), "browser_class": optional(STRING),
    },
    "quota_days": {
        "quota_date": required(DATE), "used_units": required(INTEGER, "0"), "reserved_units": required(INTEGER, "0"),
        "common_used_units": required(INTEGER, "0"), "exhausted": required(BOOLEAN, "false"),
    },
    "quota_entries": {
        "id": PRIMARY_UUID, "quota_date": required(DATE), "broadcast_id": optional(UUID), "method": required(STRING),
        "units": required(INTEGER), "result": required(STRING), "bucket": required(STRING), "called_at": required(DATETIME),
    },
    "transfer_months": {"month": required(STRING), "sent_bytes": required(BIGINT, "0")},
    "deletion_holds": {"sub_digest": required(STRING), "hold_usage_date": required(DATE)},
    "system_settings": {"key": required(STRING), "value": required(STRING), "updated_at": required(DATETIME)},
    "admin_actions": {
        "id": PRIMARY_UUID, "action": required(STRING), "target": optional(STRING), "detail": optional(STRING),
        "occurred_at": required(DATETIME),
    },
}

PRIMARY_KEYS = {table: "id" for table in ER}
PRIMARY_KEYS.update({"quota_days": "quota_date", "transfer_months": "month", "deletion_holds": "sub_digest", "system_settings": "key"})

# 列挙の列。(テーブル, 列) => 符号の出どころ。契約の列挙は enums.json、公開範囲は http-api.md、台帳の 2 列は ER 図（21 章）
ENUMERATED = {
    ("broadcasts", "state"): ("enum", "broadcast_state"),
    ("broadcasts", "end_reason"): ("enum", "end_reason"),
    ("broadcasts", "settlement_state"): ("enum", "settlement_state"),
    ("broadcasts", "profile"): ("enum", "profile"),
    ("broadcasts", "privacy_status"): ("privacy", None),
    ("youtube_connections", "state"): ("enum_without_not_connected", "youtube_connection_state"),
    ("broadcast_events", "event_type"): ("enum", "broadcast_event_type"),
    ("usage_events", "event_type"): ("enum", "usage_event_type"),
    ("quota_entries", "bucket"): ("literal", ["prep", "settle", "common"]),
    ("quota_entries", "result"): ("literal", ["ok", "error"]),
}

NON_NEGATIVE = {
    "daily_usages": ["consumed_count", "attempt_count", "extra_grants"],
    "broadcasts": ["settlement_attempts", "prep_reserved_units", "settle_reserved_units", "resume_count", "sent_bytes", "publisher_epoch"],
    "relay_tickets": ["epoch"],
    "quota_days": ["used_units", "reserved_units", "common_used_units"],
    "quota_entries": ["units"],
    "transfer_months": ["sent_bytes"],
}

# 索引の名前 => (テーブル, 列, 一意か, 部分索引の条件の正規表現)
INDEXES = {
    "idx_users_google_sub": ("users", ["google_sub"], True, None),
    "idx_sessions_token_digest": ("sessions", ["token_digest"], True, None),
    "idx_sessions_user_id": ("sessions", ["user_id"], False, None),
    "idx_sessions_expires_at": ("sessions", ["expires_at"], False, None),
    "idx_youtube_connections_user_id": ("youtube_connections", ["user_id"], True, None),
    "idx_broadcasts_one_unended_per_user": ("broadcasts", ["user_id"], True, r"\(\(state\)::text <> 'ended'::text\)"),
    "idx_broadcasts_state_accepted_at": ("broadcasts", ["state", "accepted_at"], False, None),
    "idx_broadcasts_settlement_state": ("broadcasts", ["settlement_state"], False, None),
    "idx_broadcasts_ended_at": ("broadcasts", ["ended_at"], False, None),
    "idx_broadcasts_user_id_accepted_at": ("broadcasts", ["user_id", "accepted_at"], False, None),
    "idx_broadcasts_daily_usage_id": ("broadcasts", ["daily_usage_id"], False, None),
    "idx_daily_usages_user_id_usage_date": ("daily_usages", ["user_id", "usage_date"], True, None),
    "idx_relay_tickets_token_digest": ("relay_tickets", ["token_digest"], True, None),
    "idx_relay_tickets_expires_at": ("relay_tickets", ["expires_at"], False, None),
    "idx_relay_tickets_broadcast_id": ("relay_tickets", ["broadcast_id"], False, None),
    "idx_relay_tickets_user_id": ("relay_tickets", ["user_id"], False, None),
    "idx_health_samples_sampled_at": ("health_samples", ["sampled_at"], False, None),
    "idx_health_samples_broadcast_id_sampled_at": ("health_samples", ["broadcast_id", "sampled_at"], False, None),
    "idx_health_samples_user_id": ("health_samples", ["user_id"], False, None),
    "idx_broadcast_events_occurred_at": ("broadcast_events", ["occurred_at"], False, None),
    "idx_broadcast_events_broadcast_id_occurred_at": ("broadcast_events", ["broadcast_id", "occurred_at"], False, None),
    "idx_broadcast_events_user_id": ("broadcast_events", ["user_id"], False, None),
    "idx_usage_events_user_id": ("usage_events", ["user_id"], False, None),
    "idx_quota_entries_quota_date": ("quota_entries", ["quota_date"], False, None),
    "idx_quota_entries_broadcast_id": ("quota_entries", ["broadcast_id"], False, None),
    "idx_admin_actions_occurred_at": ("admin_actions", ["occurred_at"], False, None),
}

# 外部キーの名前 => (子テーブル, 列, 親テーブル, 親の列, 親の削除時の動作)。None は既定（参照されている間は、親を削除できない）
CASCADE, SET_NULL = "CASCADE", "SET NULL"
FOREIGN_KEYS = {
    "fk_sessions_user_id": ("sessions", "user_id", "users", "id", CASCADE),
    "fk_youtube_connections_user_id": ("youtube_connections", "user_id", "users", "id", CASCADE),
    "fk_broadcasts_user_id": ("broadcasts", "user_id", "users", "id", CASCADE),
    "fk_broadcasts_daily_usage_id": ("broadcasts", "daily_usage_id", "daily_usages", "id", None),
    "fk_daily_usages_user_id": ("daily_usages", "user_id", "users", "id", CASCADE),
    "fk_relay_tickets_user_id": ("relay_tickets", "user_id", "users", "id", CASCADE),
    "fk_relay_tickets_broadcast_id": ("relay_tickets", "broadcast_id", "broadcasts", "id", CASCADE),
    "fk_health_samples_user_id": ("health_samples", "user_id", "users", "id", CASCADE),
    "fk_health_samples_broadcast_id": ("health_samples", "broadcast_id", "broadcasts", "id", CASCADE),
    "fk_broadcast_events_user_id": ("broadcast_events", "user_id", "users", "id", CASCADE),
    "fk_broadcast_events_broadcast_id": ("broadcast_events", "broadcast_id", "broadcasts", "id", CASCADE),
    "fk_usage_events_user_id": ("usage_events", "user_id", "users", "id", SET_NULL),
    "fk_quota_entries_quota_date": ("quota_entries", "quota_date", "quota_days", "quota_date", None),
    "fk_quota_entries_broadcast_id": ("quota_entries", "broadcast_id", "broadcasts", "id", SET_NULL),
}


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def table_blocks(sql):
    return {name: body for name, body in re.findall(r"^CREATE TABLE public\.(\w+) \(\n(.*?)\n\);$", sql, re.S | re.M)}


COLUMN = re.compile(
    r"^    (?P<name>\w+) (?P<type>[a-z][a-z0-9 ()]*?)(?: DEFAULT (?P<default>.+?))?(?P<notnull> NOT NULL)?,?$"
)


def parse_columns(body):
    columns = {}
    constraints = {}
    for line in body.split("\n"):
        if line.startswith("    CONSTRAINT "):
            match = re.match(r"^    CONSTRAINT (\w+) CHECK (.*?),?$", line)
            if match:
                constraints[match.group(1)] = match.group(2)
            continue
        match = COLUMN.match(line)
        if not match:
            ng(f"列の定義を読み取れない行: {line.strip()[:80]}")
            continue
        default = match.group("default")
        if default is not None:
            default = re.sub(r"::character varying$", "", default).strip("'")
        columns[match.group("name")] = (match.group("type"), match.group("notnull") is None, default)
    return columns, constraints


def literals(text):
    return re.findall(r"'((?:[^']|'')*)'::(?:character varying|text)", text)


def expected_values(kind, argument, enums, privacy):
    if kind == "enum":
        return enums[argument]["values"]
    if kind == "enum_without_not_connected":
        return [value for value in enums[argument]["values"] if value != "not_connected"]
    if kind == "privacy":
        return privacy
    return argument


def privacy_statuses():
    for line in read(HTTP_API_MD).split("\n"):
        if line.startswith("| `privacy_status` | 文字列 |"):
            return re.findall(r"`([a-z_]+)`", line.split("|")[3])
    return []


def main():
    sql = read(STRUCTURE)
    enums = json.loads(read(ENUMS_JSON))["enums"]
    privacy = privacy_statuses()
    check(len(privacy) == 3, f"契約 http-api.md の privacy_status の符号を読み取れた（{privacy}）")

    blocks = table_blocks(sql)
    tables = set(blocks) - INTERNAL_TABLES
    check(tables == set(ER) and len(tables) == 15, f"CREATE TABLE は、20.1 の 15 テーブルだけ（{len(tables)} 件）")

    all_constraints = {}
    for table, expected_columns in ER.items():
        if table not in blocks:
            ng(f"{table} の CREATE TABLE が無い")
            continue
        columns, constraints = parse_columns(blocks[table])
        all_constraints[table] = constraints
        check(set(columns) == set(expected_columns), f"{table}: 列の名前が ER 図と一致する（{len(columns)} 列）")
        for name, expectation in expected_columns.items():
            if name in columns and columns[name] != expectation:
                ng(f"{table}.{name}: [型, NULL 可, 既定値] が ER 図の期待 {expectation} と違う（実際: {columns[name]}）")
        check(
            all(columns.get(name) == expectation for name, expectation in expected_columns.items()),
            f"{table}: 列の型・NULL 可否・既定値が ER 図のとおり",
        )

    for table, key in PRIMARY_KEYS.items():
        pattern = rf"ALTER TABLE ONLY public\.{table}\n    ADD CONSTRAINT {table}_pkey PRIMARY KEY \({key}\);"
        check(re.search(pattern, sql) is not None, f"{table}: 主キーは {key}")

    for (table, column), (kind, argument) in ENUMERATED.items():
        name = f"chk_{table}_{column}"
        text = all_constraints.get(table, {}).get(name)
        if text is None:
            ng(f"{table}: CHECK 制約 {name} が無い")
            continue
        expected = expected_values(kind, argument, enums, privacy)
        actual = literals(text)
        check(sorted(actual) == sorted(expected) and len(actual) == len(set(actual)), f"{name}: 符号が契約（{kind}）と一致する（{len(actual)} 件）")
        check(f"({column})::text = ANY" in text or f"{column}" in text, f"{name}: 対象の列は {column}")

    for table, columns in NON_NEGATIVE.items():
        for column in columns:
            name = f"chk_{table}_{column}_non_negative"
            text = all_constraints.get(table, {}).get(name)
            check(text is not None and f"({column} >= 0)" in text, f"{name}: {column} は 0 以上")

    month = all_constraints.get("transfer_months", {}).get("chk_transfer_months_month_format", "")
    check("^[0-9]{4}-(0[1-9]|1[0-2])$" in month, "chk_transfer_months_month_format: 月の文字列は YYYY-MM")

    title = all_constraints.get("broadcasts", {}).get("chk_broadcasts_pending_title_lifecycle", "")
    check(
        "pending_title IS NULL" in title and "youtube_broadcast_id IS NULL" in title and "<> 'ended'" in title,
        "chk_broadcasts_pending_title_lifecycle: タイトルは、識別子の保存前の、終了していない配信だけが持つ",
    )

    expected_check_names = (
        {f"chk_{table}_{column}" for table, column in ENUMERATED}
        | {f"chk_{table}_{column}_non_negative" for table, columns in NON_NEGATIVE.items() for column in columns}
        | {"chk_transfer_months_month_format", "chk_broadcasts_pending_title_lifecycle"}
    )
    actual_check_names = {name for constraints in all_constraints.values() for name in constraints}
    check(actual_check_names == expected_check_names, f"CHECK 制約は、表のとおり {len(expected_check_names)} 本（過不足なし）")

    index_pattern = re.compile(r"^CREATE (UNIQUE )?INDEX (\w+) ON public\.(\w+) USING btree \(([^)]*)\)(?: WHERE (.*))?;$", re.M)
    found_indexes = {m.group(2): (m.group(3), [c.strip() for c in m.group(4).split(",")], m.group(1) is not None, m.group(5)) for m in index_pattern.finditer(sql)}
    check(set(found_indexes) == set(INDEXES), f"索引は、表のとおり {len(INDEXES)} 本（過不足なし）")
    for name, (table, columns, unique, where) in INDEXES.items():
        actual = found_indexes.get(name)
        if actual is None:
            ng(f"索引 {name} が無い")
            continue
        same = actual[0] == table and actual[1] == columns and actual[2] == unique
        same = same and ((where is None and actual[3] is None) or (where is not None and actual[3] is not None and re.fullmatch(where, actual[3]) is not None))
        check(same, f"索引 {name}: {table} ({', '.join(columns)}){' 一意' if unique else ''}{' 部分索引' if where else ''}")

    fk_pattern = re.compile(
        r"ALTER TABLE ONLY public\.(\w+)\n    ADD CONSTRAINT (fk_\w+) FOREIGN KEY \((\w+)\) REFERENCES public\.(\w+)\((\w+)\)(?: ON DELETE (CASCADE|SET NULL))?;"
    )
    found_keys = {m.group(2): (m.group(1), m.group(3), m.group(4), m.group(5), m.group(6)) for m in fk_pattern.finditer(sql)}
    check(set(found_keys) == set(FOREIGN_KEYS), f"外部キーは、表のとおり {len(FOREIGN_KEYS)} 本（過不足なし）")
    for name, expectation in FOREIGN_KEYS.items():
        check(found_keys.get(name) == expectation, f"外部キー {name}: {expectation[0]}.{expectation[1]} -> {expectation[2]}.{expectation[3]}（削除時: {expectation[4] or '既定'}）")

    versions = re.findall(r"\('(\d+)'\)", sql.split('INSERT INTO "schema_migrations"')[-1]) if 'INSERT INTO "schema_migrations"' in sql else []
    files = sorted(re.match(r"\d+", name).group(0) for name in os.listdir(MIGRATE_DIR) if name.endswith(".rb"))
    check(sorted(versions) == files and len(files) == 16, f"schema_migrations の版が db/migrate の 16 ファイルと一致する（{len(versions)} 件）")

    inserts = re.findall(r"^INSERT INTO (\S+)", sql, re.M)
    check(inserts == ['"schema_migrations"'], "データの INSERT は schema_migrations だけ（初期値を DB に入れない）")

    check("gen_random_uuid()" in sql and "uuid_generate_v4" not in sql, "uuid の既定値は gen_random_uuid()（拡張に依存しない）")

    print(f"\n検査 {checks} 件、失敗 {len(failures)} 件")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
