'use strict';
// 回線計測（src/frontend/core/probe の UplinkProbe）が、送信の詰まりで止まらないことを、Jest を使わず、素の Node で確かめる（読み取りのみ）。
// PR #44 のレビュー R1（sendProbe が解決しないと、measure が永久に終わらない）の再発防止。
//
// なぜ Jest ではなく素の Node か：Jest の実行環境（vm のサンドボックス）では、プロセス全体の unhandledRejection・uncaughtException が観測できない。
// 窓の終わりで打ち切った送信が、あとで拒否されても、未処理の拒否にならないことは、Node のイベントループとプロセスのイベントで確かめる。
// 時計は本物（setTimeout・performance.now）。短い窓（300 ms）と短い猶予（200 ms）で、各場面を 1 秒未満で終える。
//
//   1. sendProbe が最初から解決しない      -> 窓 + 猶予（500 ms）で ProbeTimeoutError。止まった送信の番号を持つ
//   2. sendProbe が 5 通目から解決しない    -> 同じ。送れた数は 4
//   3. 打ち切った送信が、あとで拒否・解決される -> 未処理の拒否・未捕捉の例外にならない
//   4. 窓の終わりまでの送信の失敗（拒否・同期の例外）-> ProbeSendError（原因つき）。以後は送らない
//   5. 送信が止まっている間に、結果が届く（窓の途中・猶予の間）-> その値を返す。待ち続けない
//   6. clock.wait は、送信ごとに作らない（期限の 1 本 + ペース配分 + 猶予）
//   7. どの場面でも、結果の受信は解除される
//
// 使い方: node check_probe_stuck.cjs <リポジトリのルート>
// 終了コード: 0 = 問題なし / 1 = 食い違い / 3 = 確認できなかった（TypeScript が無い）

const path = require('path');
const createCoreLoader = require('./ts_loader.cjs');

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_UNAVAILABLE = 3;

if (!process.argv[2]) {
  console.error('使い方: node check_probe_stuck.cjs <リポジトリのルート>');
  process.exit(EXIT_FINDINGS);
}
const repo = path.resolve(process.argv[2]);
const requireCore = createCoreLoader(repo);
if (requireCore === null) {
  console.log('SKIP 確認できなかった: TypeScript（src/frontend/node_modules/typescript）が見つかりません。frontend の依存を導入してください');
  process.exit(EXIT_UNAVAILABLE);
}
const { UplinkProbe, ProbeTimeoutError, ProbeSendError } = requireCore('probe');

const WINDOW_MS = 300;
const GRACE_MS = 200;
const TOTAL_MS = WINDOW_MS + GRACE_MS;
const HANG_LIMIT_MS = 5000; // これを超えても終わらなければ「止まっている」
const SETTLE_MS = 150; // 打ち切った送信の、遅い解決・拒否が、イベントとして現れるのを待つ時間
const TIMER_SLACK_MS = 30; // タイマの粒度
const LATE_LIMIT_MS = 900; // 想定の時間を超えてよい幅（負荷の高い環境でも、止まっていないと言える範囲）

// プロセス全体のイベント（Jest のサンドボックスでは観測できないもの）
const unhandled = [];
const uncaught = [];
process.on('unhandledRejection', (reason) => unhandled.push(reason instanceof Error ? reason.message : String(reason)));
process.on('uncaughtException', (error) => uncaught.push(error instanceof Error ? error.message : String(error)));

const problems = [];
const report = (message) => {
  if (problems.length < 30) problems.push(message);
};
const check = (condition, message) => {
  if (!condition) report(message);
};

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function makeClock() {
  const clock = {
    waitCalls: [],
    nowMs: () => performance.now(),
    wait(milliseconds) {
      clock.waitCalls.push(milliseconds);
      return new Promise((resolve) => setTimeout(resolve, milliseconds));
    },
  };
  return clock;
}

function makeChannel(sendProbe) {
  const channel = {
    calls: 0,
    listeners: new Set(),
    sendProbe(bytes) {
      const index = channel.calls;
      channel.calls += 1;
      return sendProbe(index, bytes);
    },
    onProbeResult(callback) {
      channel.listeners.add(callback);
      return () => {
        channel.listeners.delete(callback);
      };
    },
    deliver(throughputKbps) {
      for (const callback of [...channel.listeners]) callback(throughputKbps);
    },
  };
  return channel;
}

/** measure を実行し、結果（値・エラー・止まった）と、かかった時間を返す。止まったときは、HANG_LIMIT_MS で見切る。 */
async function runMeasure(channel, clock) {
  const startedAt = performance.now();
  let timer;
  const hang = new Promise((resolve) => {
    timer = setTimeout(() => resolve({ hung: true }), HANG_LIMIT_MS);
  });
  const settled = new UplinkProbe({ durationMs: WINDOW_MS, resultGraceMs: GRACE_MS }).measure(channel, clock).then(
    (value) => ({ value }),
    (error) => ({ error }),
  );
  const outcome = await Promise.race([settled, hang]);
  clearTimeout(timer);
  return { ...outcome, elapsedMs: performance.now() - startedAt };
}

function describeOutcome(outcome) {
  if (outcome.hung) return `${HANG_LIMIT_MS} ms たっても終わりません（止まっている）`;
  if (outcome.error !== undefined) return `${outcome.error.name || 'Error'}: ${outcome.error.message}`;
  return `値 ${outcome.value}`;
}

function expectTimeout(outcome, expected, label, clock, channel) {
  if (!(outcome.error instanceof ProbeTimeoutError)) {
    report(`${label}: ProbeTimeoutError になりませんでした（${describeOutcome(outcome)}）`);
    return;
  }
  const error = outcome.error;
  check(error.code === 'probe_timeout', `${label}: code が probe_timeout ではありません: ${error.code}`);
  check(error.waitedMs === TOTAL_MS, `${label}: waitedMs が ${TOTAL_MS} ではありません: ${error.waitedMs}`);
  check(error.sentMessages === expected.sentMessages, `${label}: sentMessages が ${expected.sentMessages} ではありません: ${error.sentMessages}`);
  check(error.stalledMessageIndex === expected.stalledMessageIndex, `${label}: stalledMessageIndex が ${expected.stalledMessageIndex} ではありません: ${error.stalledMessageIndex}`);
  check(
    outcome.elapsedMs >= TOTAL_MS - TIMER_SLACK_MS && outcome.elapsedMs <= TOTAL_MS + LATE_LIMIT_MS,
    `${label}: かかった時間が ${Math.round(outcome.elapsedMs)} ms です（想定は窓 + 猶予の約 ${TOTAL_MS} ms）`,
  );
  // clock.wait は、送信ごとに作らない：期限（1）+ 猶予（1）+ ペース配分（送信の試みごとに最大 1）
  check(clock.waitCalls.length <= channel.calls + 2, `${label}: clock.wait の呼び出しが多すぎます（${clock.waitCalls.length} 回。送信の試み ${channel.calls} 回。送信ごとに期限を作っている疑い）`);
  check(channel.listeners.size === 0, `${label}: 結果の受信が解除されていません`);
}

/** 場面を実行し、打ち切った送信の遅い解決・拒否が出るのを待って、未処理の拒否・未捕捉の例外が増えていないことを確かめる。 */
async function scenario(name, body) {
  const before = { problems: problems.length, unhandled: unhandled.length, uncaught: uncaught.length };
  await body();
  await sleep(SETTLE_MS);
  if (unhandled.length !== before.unhandled) report(`${name}: 未処理の拒否（unhandledRejection）が ${unhandled.length - before.unhandled} 件あります: ${unhandled.slice(before.unhandled).join(' / ')}`);
  if (uncaught.length !== before.uncaught) report(`${name}: 未捕捉の例外が ${uncaught.length - before.uncaught} 件あります: ${uncaught.slice(before.uncaught).join(' / ')}`);
  console.log(`${problems.length === before.problems ? 'ok  ' : 'FAIL'} ${name}`);
}

async function main() {
  await scenario('1. sendProbe が最初から解決しない -> 窓 + 猶予で ProbeTimeoutError（終わる）', async () => {
    const clock = makeClock();
    const channel = makeChannel(() => new Promise(() => {}));
    const outcome = await runMeasure(channel, clock);
    expectTimeout(outcome, { sentMessages: 0, stalledMessageIndex: 0 }, 'stuck-from-first', clock, channel);
    check(channel.calls === 1, `stuck-from-first: 止まった送信のあとに、次の送信をしています（${channel.calls} 回）`);
  });

  await scenario('2. sendProbe が 5 通目から解決しない -> 窓 + 猶予で ProbeTimeoutError（送れた数 4・止まった番号 4）', async () => {
    const clock = makeClock();
    const channel = makeChannel((index) => (index < 4 ? Promise.resolve() : new Promise(() => {})));
    const outcome = await runMeasure(channel, clock);
    expectTimeout(outcome, { sentMessages: 4, stalledMessageIndex: 4 }, 'stuck-from-fifth', clock, channel);
    check(channel.calls === 5, `stuck-from-fifth: 送信の試みが 5 回ではありません（${channel.calls} 回）`);
  });

  await scenario('3a. 打ち切った送信が、あとで拒否される -> 未処理の拒否にならない', async () => {
    let rejectLate;
    const clock = makeClock();
    const channel = makeChannel((index) =>
      index < 2
        ? Promise.resolve()
        : new Promise((_resolve, reject) => {
            rejectLate = reject;
          }),
    );
    const outcome = await runMeasure(channel, clock);
    expectTimeout(outcome, { sentMessages: 2, stalledMessageIndex: 2 }, 'late-reject', clock, channel);
    check(typeof rejectLate === 'function', 'late-reject: 止まった送信が作られていません');
    if (typeof rejectLate === 'function') rejectLate(new Error('late socket failure after the abort'));
  });

  await scenario('3b. 打ち切った送信が、あとで解決される -> 何も起きない', async () => {
    let resolveLate;
    const clock = makeClock();
    const channel = makeChannel((index) =>
      index < 2
        ? Promise.resolve()
        : new Promise((resolve) => {
            resolveLate = resolve;
          }),
    );
    const outcome = await runMeasure(channel, clock);
    expectTimeout(outcome, { sentMessages: 2, stalledMessageIndex: 2 }, 'late-resolve', clock, channel);
    if (typeof resolveLate === 'function') resolveLate();
    else report('late-resolve: 止まった送信が作られていません');
  });

  await scenario('4a. 窓の途中の送信の失敗（拒否）-> ProbeSendError（原因つき・番号つき）。以後は送らない', async () => {
    const cause = new Error('socket closed');
    const channel = makeChannel((index) => (index === 2 ? Promise.reject(cause) : Promise.resolve()));
    const outcome = await runMeasure(channel, makeClock());
    check(outcome.error instanceof ProbeSendError, `send-reject: ProbeSendError になりませんでした（${describeOutcome(outcome)}）`);
    if (outcome.error instanceof ProbeSendError) {
      check(outcome.error.code === 'probe_send_failed', `send-reject: code が probe_send_failed ではありません: ${outcome.error.code}`);
      check(outcome.error.messageIndex === 2, `send-reject: messageIndex が 2 ではありません: ${outcome.error.messageIndex}`);
      check(outcome.error.cause === cause, 'send-reject: 原因（cause）が、元のエラーではありません');
    }
    check(channel.calls === 3, `send-reject: 失敗のあとに送っています（送信の試み ${channel.calls} 回。想定は 3 回）`);
    check(outcome.elapsedMs < WINDOW_MS, `send-reject: 失敗を、すぐに知らせていません（${Math.round(outcome.elapsedMs)} ms）`);
    check(channel.listeners.size === 0, 'send-reject: 結果の受信が解除されていません');
  });

  await scenario('4b. 窓の途中の送信の失敗（同期の例外）-> ProbeSendError', async () => {
    const cause = new Error('synchronous failure');
    const channel = makeChannel((index) => {
      if (index === 1) throw cause;
      return undefined;
    });
    const outcome = await runMeasure(channel, makeClock());
    check(outcome.error instanceof ProbeSendError, `send-throw: ProbeSendError になりませんでした（${describeOutcome(outcome)}）`);
    if (outcome.error instanceof ProbeSendError) {
      check(outcome.error.messageIndex === 1, `send-throw: messageIndex が 1 ではありません: ${outcome.error.messageIndex}`);
      check(outcome.error.cause === cause, 'send-throw: 原因（cause）が、元のエラーではありません');
    }
    check(channel.calls === 2, `send-throw: 失敗のあとに送っています（送信の試み ${channel.calls} 回。想定は 2 回）`);
    check(channel.listeners.size === 0, 'send-throw: 結果の受信が解除されていません');
  });

  await scenario('5a. 送信が止まっている間（窓の途中）に結果が届く -> その値を返す（待ち続けない）', async () => {
    const channel = makeChannel((index) => (index < 1 ? Promise.resolve() : new Promise(() => {})));
    setTimeout(() => channel.deliver(4321), 100);
    const outcome = await runMeasure(channel, makeClock());
    check(outcome.value === 4321, `result-in-window: 値 4321 を返しませんでした（${describeOutcome(outcome)}）`);
    check(outcome.elapsedMs < WINDOW_MS, `result-in-window: 結果を受けてすぐに終わっていません（${Math.round(outcome.elapsedMs)} ms）`);
    check(channel.listeners.size === 0, 'result-in-window: 結果の受信が解除されていません');
  });

  await scenario('5b. 送信が止まったまま、猶予の間に結果が届く -> その値を返す', async () => {
    const channel = makeChannel((index) => (index < 2 ? Promise.resolve() : new Promise(() => {})));
    setTimeout(() => channel.deliver(7777), WINDOW_MS + 100);
    const outcome = await runMeasure(channel, makeClock());
    check(outcome.value === 7777, `result-in-grace: 値 7777 を返しませんでした（${describeOutcome(outcome)}）`);
    check(outcome.elapsedMs >= WINDOW_MS && outcome.elapsedMs < TOTAL_MS + LATE_LIMIT_MS, `result-in-grace: かかった時間が想定の範囲外です（${Math.round(outcome.elapsedMs)} ms）`);
    check(channel.listeners.size === 0, 'result-in-grace: 結果の受信が解除されていません');
  });

  await scenario('6. 送信が詰まらない通常の計測は、窓の終わりまでペース配分して送り、結果で終わる（回帰）', async () => {
    const clock = makeClock();
    const channel = makeChannel(() => undefined);
    setTimeout(() => channel.deliver(5555), WINDOW_MS + 20);
    const outcome = await runMeasure(channel, clock);
    check(outcome.value === 5555, `normal: 値 5555 を返しませんでした（${describeOutcome(outcome)}）`);
    check(channel.calls >= 5, `normal: 窓の間に送った数が少なすぎます（${channel.calls} 回）`);
    check(clock.waitCalls.length <= channel.calls + 2, `normal: clock.wait の呼び出しが多すぎます（${clock.waitCalls.length} 回。送信 ${channel.calls} 回）`);
    check(channel.listeners.size === 0, 'normal: 結果の受信が解除されていません');
  });

  if (problems.length > 0) {
    console.log('食い違い:');
    problems.forEach((item) => console.log(`  - ${item}`));
    return EXIT_FINDINGS;
  }
  console.log(`ok   プロセス全体で、未処理の拒否 ${unhandled.length} 件・未捕捉の例外 ${uncaught.length} 件（0 件であること）`);
  return EXIT_OK;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.log(`FAIL 検査そのものが失敗しました: ${error && error.stack ? error.stack : error}`);
    process.exit(EXIT_FINDINGS);
  },
);
