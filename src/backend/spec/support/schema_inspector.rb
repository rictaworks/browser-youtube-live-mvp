# DB のカタログ（information_schema・pg_catalog）を読む、スペック用の部品。
# テスト用 DB は、db/structure.sql から作られる（scripts/test_backend.sh が db:prepare で読み込む）。
# したがって、ここで読むカタログは、structure.sql が再現した DB の姿である。
module SchemaInspector
  # Rails が自動で作る内部のテーブル。20.1 の 15 テーブルには数えない
  INTERNAL_TABLES = %w[ schema_migrations ar_internal_metadata ].freeze

  module_function

  def connection
    ActiveRecord::Base.connection
  end

  # public スキーマの、基底のテーブルの名前（Rails の内部テーブルを除く）。information_schema を走査する。
  def table_names
    sql = <<~SQL
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name
    SQL
    connection.select_values(sql) - INTERNAL_TABLES
  end

  # テーブルの列。列名 => [ SQL の型, NULL 可, 既定値 ]。
  # 既定値は、関数なら関数の式（"gen_random_uuid()"）、リテラルなら文字列（"0"・"false"・"reserved"）、無ければ nil。
  def columns(table)
    connection.columns(table).to_h do |column|
      [ column.name, [ column.sql_type, column.null, column.default_function || column.default ] ]
    end
  end

  # information_schema から読んだ、列の情報。列名 => { data_type:, nullable: }
  def information_schema_columns(table)
    sql = <<~SQL
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = #{connection.quote(table)}
      ORDER BY ordinal_position
    SQL
    connection.select_rows(sql).to_h do |name, data_type, is_nullable|
      [ name, { data_type: data_type, nullable: is_nullable == "YES" } ]
    end
  end

  # 指定の名前の列を持つテーブルの名前（Rails の内部テーブルを除く）。information_schema を走査する。
  def tables_with_column(column_name)
    sql = <<~SQL
      SELECT table_name
      FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = #{connection.quote(column_name)}
      ORDER BY table_name
    SQL
    connection.select_values(sql) & table_names
  end

  # テーブルの CHECK 制約。制約の名前 => pg_get_constraintdef の文字列
  def check_constraints(table)
    sql = <<~SQL
      SELECT conname, pg_get_constraintdef(oid)
      FROM pg_constraint
      WHERE conrelid = #{connection.quote("public.#{table}")}::regclass AND contype = 'c'
      ORDER BY conname
    SQL
    connection.select_rows(sql).to_h
  end

  # CHECK 制約の中の、文字列のリテラル（列挙の符号）。制約の名前で引く。無ければ失敗する。
  # pg_get_constraintdef は、IN (...) を ((state)::text = ANY ((ARRAY['a'::character varying, ...])::text[])) の形で返す。
  def check_literals(table, constraint_name)
    definition = check_constraints(table).fetch(constraint_name) do
      raise "#{table} に CHECK 制約 #{constraint_name} が無い（ある制約: #{check_constraints(table).keys.join(', ')}）"
    end
    definition.scan(/'((?:[^']|'')*)'::(?:character varying|text)/).flatten
  end
end
