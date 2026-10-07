// 実ブラウザの中で動く、検査のスクリプト（probe_codec_in_browser.cjs が、ローカルのサーバーから配る。Node では実行しない）。
// core の TypeScript は、probe_codec_in_browser.cjs が CommonJS にして、window.__core として読み込める形で配る。
// ここでは、本物の WebSocket（Chromium）・本物のタイマ・本物の TextDecoder・DataView で、送信まわりの Domain Core を動かす。
// 相手の中継は、Playwright の routeWebSocket による代役（Node 側。独立した参照実装でフレームを読み書きする）。
'use strict';

(function () {
  var results = [];
  var problems = [];

  function ok(label) {
    results.push('ok   ' + label);
  }
  function check(condition, label, detail) {
    if (condition) {
      ok(label);
    } else {
      results.push('FAIL ' + label + (detail === undefined ? '' : '：' + detail));
      problems.push(label);
    }
  }
  function hex(bytes) {
    var text = '';
    for (var index = 0; index < bytes.length; index += 1) {
      text += (bytes[index] < 16 ? '0' : '') + bytes[index].toString(16);
    }
    return text;
  }
  function fromHex(text) {
    var bytes = new Uint8Array(text.length / 2);
    for (var index = 0; index < bytes.length; index += 1) {
      bytes[index] = parseInt(text.substr(index * 2, 2), 16);
    }
    return bytes;
  }
  function errorCode(action) {
    try {
      action();
    } catch (error) {
      return error && error.name === 'FrameError' ? error.code : 'unexpected: ' + String(error);
    }
    return 'no error';
  }

  // -------------------------------------------------------------------------
  // 1. 共有ベクタを、実ブラウザの TextEncoder・TextDecoder・DataView（BigInt）で通す
  // -------------------------------------------------------------------------
  function runVectors(vectors) {
    var transport = window.__core.load('transport');
    var codec = new transport.FrameCodec();
    var directions = { relay: 'browser_to_relay', browser: 'relay_to_browser' };
    var bad = [];
    vectors.valid.forEach(function (vector) {
      var bytes = fromHex(vector.hex);
      ['browser_to_relay', 'relay_to_browser'].forEach(function (accepts) {
        if (accepts === vector.direction) {
          var frame = transport.decodeRawFrame(bytes, accepts);
          if (frame.type !== vector.decoded.type || frame.keyframe !== vector.decoded.keyframe || frame.timestampUs.toString() !== vector.decoded.timestamp_us || hex(frame.body) !== vector.decoded.body_hex) {
            bad.push('decode ' + vector.name);
          }
        } else if (errorCode(function () { transport.decodeRawFrame(bytes, accepts); }) !== 'wrong_direction') {
          bad.push('direction ' + vector.name);
        }
      });
      if (vector.decode_only !== true) {
        var encoded = transport.encodeRawFrame({ type: vector.decoded.type, keyframe: vector.decoded.keyframe, timestampUs: BigInt(vector.decoded.timestamp_us), body: fromHex(vector.decoded.body_hex) });
        if (hex(encoded) !== vector.hex) bad.push('encode ' + vector.name);
      }
      if (vector.direction === 'relay_to_browser') {
        var message = codec.decode(bytes);
        if (message.type !== vector.decoded.type) bad.push('typed decode ' + vector.name);
      }
    });
    vectors.invalid.forEach(function (vector) {
      var bytes = fromHex(vector.hex);
      vector.receivers.forEach(function (receiver) {
        if (errorCode(function () { transport.decodeRawFrame(bytes, directions[receiver]); }) !== vector.error) bad.push('invalid ' + vector.name + ' (' + receiver + ')');
        if (receiver === 'browser' && errorCode(function () { codec.decode(bytes); }) !== vector.error) bad.push('invalid typed ' + vector.name);
      });
    });
    check(bad.length === 0, '共有ベクタ（valid ' + vectors.valid.length + ' 件・invalid ' + vectors.invalid.length + ' 件）が、実ブラウザでも、復号・符号化・型付きの復号で一致する', bad.slice(0, 5).join(', '));
  }

  // -------------------------------------------------------------------------
  // 2. 実ブラウザの API の振る舞い（Domain Core が、環境に頼る部分）
  // -------------------------------------------------------------------------
  function runPlatformChecks() {
    var transport = window.__core.load('transport');
    var codec = new transport.FrameCodec();
    var max64 = (BigInt(1) << BigInt(64)) - BigInt(1);
    var frame = transport.decodeRawFrame(transport.encodeRawFrame({ type: 'audio', timestampUs: max64, body: new Uint8Array(0) }), 'browser_to_relay');
    check(frame.timestampUs === max64, '64 ビットの時刻（2^64 - 1）が、DataView の BigInt で、丸めずに往復する');
    var twoPow53Plus1 = (BigInt(1) << BigInt(53)) + BigInt(1);
    var big = transport.decodeRawFrame(transport.encodeRawFrame({ type: 'video', keyframe: true, timestampUs: twoPow53Plus1, body: new Uint8Array(1) }), 'browser_to_relay');
    check(big.timestampUs === twoPow53Plus1 && big.keyframe === true, '2^53 + 1 の時刻が、Number を経由せず、厳密に往復する');
    // 本文が UTF-8 として不正（TextDecoder の fatal）
    var invalidUtf8 = transport.encodeRawFrame({ type: 'status', body: Uint8Array.from([0x7b, 0xff, 0xfe, 0x7d]) });
    check(errorCode(function () { codec.decode(invalidUtf8); }) === 'invalid_body', '不正な UTF-8 の本文を、TextDecoder の fatal で、invalid_body として拒否する');
    var withBom = transport.encodeRawFrame({ type: 'status', body: Uint8Array.from([0xef, 0xbb, 0xbf, 0x7b, 0x7d]) });
    check(errorCode(function () { codec.decode(withBom); }) === 'invalid_body', 'BOM 付きの本文を拒否する（BOM を黙って取り除かない）');
    // 日本語を含む本文は、バイト数で数える
    var text = JSON.stringify({ video_us: 1, audio_us: 2, x_note: String.fromCodePoint(0x65e5, 0x672c, 0x8a9e) });
    var bytes = new TextEncoder().encode(text);
    var encoded = transport.encodeRawFrame({ type: 'ack', body: bytes });
    var declared = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength).getUint32(13);
    check(declared === bytes.length && bytes.length > text.length, '日本語を含む本文の本文長は、文字数ではなく UTF-8 のバイト数');
    check(codec.decode(encoded).type === 'ack', '日本語を含む未知のキーを持つ本文も、復号できる（未知のキーは無視する）');
    // WebSocket の既定（binaryType が blob）で届く Blob は、そのままでは復号しない（アダプターが arraybuffer にする）
    check(errorCode(function () { codec.decode(new Blob([encoded])); }) === 'invalid_message', 'Blob は復号しない（invalid_message）。WebSocket は binaryType = arraybuffer にして使う');
    check(errorCode(function () { codec.decode('{"video_us":1}'); }) === 'invalid_message', 'テキストのメッセージは復号しない（invalid_message）');
  }

  // -------------------------------------------------------------------------
  // 3. 本物の WebSocket・タイマで、一連の流れ（接続 -> 計測 -> 開始 -> 映像・音声 -> 受領応答 -> 状態報告 -> 終了）を通す
  // -------------------------------------------------------------------------
  async function runSession() {
    var transport = window.__core.load('transport');
    var queueModule = window.__core.load('queue');
    var governorModule = window.__core.load('governor');
    var probeModule = window.__core.load('probe');
    var reportModule = window.__core.load('report');
    var profileModule = window.__core.load('profile');
    var clockModule = window.__core.load('clock');
    var contract = window.__core.load('contract');
    var codec = new transport.FrameCodec();

    var inbox = [];
    var notifiers = [];
    var probeCallbacks = [];
    var socket = new WebSocket('ws://relay.test/ws');
    socket.binaryType = 'arraybuffer';
    socket.onmessage = function (event) {
      var entry;
      try {
        entry = { message: codec.decode(event.data) };
      } catch (error) {
        entry = { error: error && error.code ? error.code : String(error), dataType: typeof event.data };
      }
      inbox.push(entry);
      if (entry.message && entry.message.type === 'probe_result') {
        probeCallbacks.slice().forEach(function (callback) {
          callback(entry.message.body.throughput_kbps);
        });
      }
      notifiers.splice(0).forEach(function (notify) {
        notify();
      });
    };
    function waitFor(predicate, label, timeoutMs) {
      return new Promise(function (resolve, reject) {
        var deadline = performance.now() + (timeoutMs || 10000);
        function attempt() {
          var found = inbox.find(predicate);
          if (found) {
            resolve(found);
          } else if (performance.now() > deadline) {
            reject(new Error('timed out waiting for ' + label));
          } else {
            notifiers.push(attempt);
            setTimeout(attempt, 250);
          }
        }
        attempt();
      });
    }
    var opened = new Promise(function (resolve, reject) {
      socket.onopen = resolve;
      socket.onerror = function () {
        reject(new Error('the WebSocket failed to open'));
      };
    });
    await opened;

    // 接続通知（チケットは、UTF-8 の文字列そのもの）-> 接続受理
    socket.send(codec.encode({ type: 'hello', ticket: 'dummy-ticket-0123456789abcdef' }));
    var accepted = await waitFor(function (entry) { return entry.message && entry.message.type === 'accepted'; }, 'accepted');
    var summary = { accepted: accepted.message.body };

    // 回線計測：本物のタイマで、3 秒間、ペース配分して送る
    var sentProbes = [];
    var channel = {
      sendProbe: function (bytes) {
        sentProbes.push({ at: performance.now(), bytes: bytes.length });
        socket.send(codec.encode({ type: 'probe', payload: bytes }));
      },
      onProbeResult: function (callback) {
        probeCallbacks.push(callback);
        return function () {
          probeCallbacks.splice(probeCallbacks.indexOf(callback), 1);
        };
      },
    };
    var clock = {
      nowMs: function () {
        return performance.now();
      },
      wait: function (milliseconds) {
        return new Promise(function (resolve) {
          setTimeout(resolve, milliseconds);
        });
      },
    };
    var measureStartedAt = performance.now();
    var throughputKbps = await new probeModule.UplinkProbe().measure(channel, clock);
    var measureElapsedMs = performance.now() - measureStartedAt;
    summary.probe = { throughputKbps: throughputKbps, sent: sentProbes.length, elapsedMs: measureElapsedMs, firstOffsetMs: sentProbes[0].at - measureStartedAt, lastOffsetMs: sentProbes[sentProbes.length - 1].at - measureStartedAt, listenersLeft: probeCallbacks.length };

    // プロファイルの選定 -> 開始通知（設定の再送と同じ形）
    var decision = profileModule.selectProfile(throughputKbps);
    summary.decision = decision;
    var startBody = transport.buildStartBody({
      profile: decision.profile,
      videoCodec: contract.LIMITS.video.codec_main,
      videoBitrateKbps: decision.startBitrateKbps,
      videoDescription: Uint8Array.from([1, 0x4d, 0x40, 0x1f, 0xff, 0xe1, 0x00, 0x0a, 0x67, 0x4d, 0x40, 0x1f, 0x96, 0x54, 0x05, 0x01, 0xed, 0x80, 0x01, 0x00, 0x04, 0x68, 0xee, 0x3c, 0x80]),
      audioDescription: Uint8Array.from([0x12, 0x10]),
    });
    socket.send(codec.encode({ type: 'start', body: startBody }));
    await waitFor(function (entry) { return entry.message && entry.message.type === 'status' && entry.message.body.state === 'confirming'; }, 'status confirming');

    // 映像・音声（2 秒分。メディアクロックの時刻）を、SendQueue を通して送る
    var queue = new queueModule.SendQueue();
    var sentMedia = [];
    var framesPerSecond = 30;
    var videoFrames = 2 * framesPerSecond;
    var nextVideo = 0;
    var nextAudio = 0;
    var samplesPerVideo = contract.LIMITS.audio.samples_per_video_frame;
    while (nextVideo < videoFrames) {
      var videoDue = nextVideo * samplesPerVideo;
      var audioDue = nextAudio * 1024;
      if (videoDue <= audioDue) {
        var videoPayload = Uint8Array.from([0, 0, 0, 4, nextVideo % 60 === 0 ? 0x65 : 0x41, nextVideo & 255, 0xaa, 0xbb]);
        queue.enqueue({ kind: 'video', keyframe: nextVideo % 60 === 0, timestampUs: clockModule.videoTimeUs(nextVideo), byteLength: videoPayload.length, data: videoPayload });
        nextVideo += 1;
      } else {
        var audioPayload = Uint8Array.from([0x21, 0x10, 0x04, nextAudio & 255]);
        queue.enqueue({ kind: 'audio', keyframe: false, timestampUs: clockModule.audioTimeUs(audioDue), byteLength: audioPayload.length, data: audioPayload });
        nextAudio += 1;
      }
      for (var chunk = queue.dequeue(); chunk !== undefined; chunk = queue.dequeue()) {
        var message = chunk.kind === 'video' ? { type: 'video', timestampUs: chunk.timestampUs, keyframe: chunk.keyframe, payload: chunk.data } : { type: 'audio', timestampUs: chunk.timestampUs, payload: chunk.data };
        var frame = codec.encode(message);
        sentMedia.push({ type: chunk.kind, timestamp: String(chunk.timestampUs), keyframe: chunk.keyframe, hex: hex(frame) });
        socket.send(frame);
      }
    }
    summary.media = sentMedia;

    // 受領応答を受けて、滞留時間を評価し、適応制御と状態報告を通す
    var ack = await waitFor(function (entry) { return entry.message && entry.message.type === 'ack' && entry.message.body.video_us > 0 && entry.message.body.audio_us > 0; }, 'ack');
    var backlogMs = queue.backlogMs(ack.message.body.video_us, ack.message.body.audio_us);
    var profileLimits = contract.LIMITS.profiles[decision.profile];
    var governor = new governorModule.BitrateGovernor();
    var governorDecision = governor.evaluate({
      nowSec: 2,
      backlogMs: backlogMs,
      dropTimesSec: queue.dropHistorySec(),
      targetKbps: decision.startBitrateKbps,
      minKbps: profileLimits.video_bitrate_min_kbps,
      maxKbps: profileLimits.video_bitrate_max_kbps,
      ackedVideoUs: ack.message.body.video_us,
      degraded: false,
    });
    var builder = new reportModule.ReportBuilder();
    governorDecision.events.forEach(function (event) {
      builder.record(event);
    });
    var prepared = builder.prepare({ backlogMs: backlogMs, droppedVideoFrames: queue.droppedVideoFrames, targetKbps: governorDecision.targetKbps, state: 'live' });
    socket.send(codec.encode({ type: 'report', body: prepared.body }));
    builder.commit(prepared);
    summary.governor = { ack: ack.message.body, backlogMs: backlogMs, targetKbps: governorDecision.targetKbps, events: governorDecision.events, reconnect: governorDecision.reconnect, report: prepared.body };

    // 中継からの制御メッセージ（抑制指示・キーフレーム要求・状態通知・致命通知）と、テキストのメッセージ
    await waitFor(function (entry) { return entry.message && entry.message.type === 'fatal'; }, 'fatal');
    await waitFor(function (entry) { return entry.error === 'invalid_message'; }, 'text message error');
    summary.received = inbox.map(function (entry) {
      return entry.message ? entry.message.type : 'error:' + entry.error + ':' + entry.dataType;
    });
    summary.throttle = inbox.find(function (entry) { return entry.message && entry.message.type === 'throttle'; }).message.body;
    summary.keyframeRequest = inbox.find(function (entry) { return entry.message && entry.message.type === 'keyframe_request'; }).message;
    summary.fatal = inbox.find(function (entry) { return entry.message && entry.message.type === 'fatal'; }).message.body;

    // 終了通知
    socket.send(codec.encode({ type: 'end', body: { reason: 'user_stop' } }));
    await new Promise(function (resolve) {
      setTimeout(resolve, 300);
    });
    socket.close();
    return summary;
  }

  window.runChecks = async function (vectors) {
    runVectors(vectors);
    runPlatformChecks();
    var session = await runSession();
    return { results: results, problems: problems, session: session };
  };
})();
