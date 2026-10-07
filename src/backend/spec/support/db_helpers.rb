# DB の制約・並行処理のスペックの、共通の補助。
module DbHelpers
  # ブロックが、DB の制約の違反（error_class）を起こすことを期待する。
  # スペックは、トランザクションの中で動く（use_transactional_fixtures）。制約に違反した文は、PostgreSQL のトランザクションを
  # 中止させ、その後の文を受け付けなくする。セーブポイント（requires_new）で包み、違反のあとも、同じ例の中で続けられるようにする。
  #   ActiveRecord::RecordNotUnique      一意制約・主キーの違反
  #   ActiveRecord::CheckViolation       CHECK 制約の違反
  #   ActiveRecord::NotNullViolation     NOT NULL 制約の違反
  #   ActiveRecord::InvalidForeignKey    外部キーの違反（参照先が無い・参照されているものを削除）
  def expect_db_violation(error_class, &block)
    expect { ActiveRecord::Base.transaction(requires_new: true, &block) }.to raise_error(error_class)
  end

  # ブロックが、制約に違反しないことを期待する（受理される値の確認）。セーブポイントで包み、結果は巻き戻す。
  def expect_db_accepts(&block)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        block.call
        raise ActiveRecord::Rollback
      end
    end.not_to raise_error
  end

  # 検証（validates）を通さずに保存する。DB の制約そのものを検査するときに使う（モデルの検証が先に拒否しないように）。
  def save_without_validation!(record)
    record.save!(validate: false)
    record
  end

  # ブロックの中で実行された SQL の文（文字列）を、実行順に返す。スキーマの読み取り・トランザクションの制御（SAVEPOINT など）は含めない。
  # 「1 つの UPDATE 文で、2 つの列を同時に更新する」ことなどの確認に使う。
  def capture_sql(&block)
    statements = []
    callback = lambda do |*, payload|
      statements << payload.fetch(:sql) unless %w[ SCHEMA TRANSACTION ].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    statements
  end

  # count 本のスレッドを、同時に開始する。各スレッドは、自分の DB 接続を使い、ブロックの結果 [:ok, 値] または
  # [:error, 例外] を返す。結果は、スレッドの番号の順。
  # 同時の操作を検査するスペックは、トランザクションを使わない（self.use_transactional_tests = false）。
  # 別の接続からは、未コミットの行が見えないため。後片付けは、そのスペックの after で行う。
  def run_concurrently(count)
    ready = Queue.new
    start = Queue.new

    threads = Array.new(count) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << index
          start.pop
          begin
            [ :ok, yield(index) ]
          rescue StandardError => e
            [ :error, e ]
          end
        end
      end
    end

    count.times { ready.pop }
    count.times { start << true }
    threads.map(&:value)
  end
end

RSpec.configure do |config|
  config.include DbHelpers
end
