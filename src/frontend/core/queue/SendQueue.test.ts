/**
 * @jest-environment node
 */
// SendQueue（requirements.md 4・11.5・12・24.1）：エンコード済みのチャンク（映像・音声）の、送信待ち。
//   - 取り出し（dequeue）は到着順（映像と音声が、時刻の順に交互になる）
//   - 映像を 1 枚でも破棄したら、次のキーフレームまでの映像をすべて破棄する（差分フレームは、直前までの全フレームに依存するため）。破棄中の状態を持ち、
//     キーフレームの到着で解除する。音声は、どんな破棄の操作でも、破棄しない
//   - 滞留時間 = 送信済み（dequeue した）の最新メディア時刻 - 中継が受領済みと応答した最新メディア時刻（映像・音声のうち古い方）。
//     受領応答が来る前（その接続の最初の ack を受けるまで）は、評価しない（undefined）
//   - 再接続中は、符号化結果を捨てる（送信待ちに積まない）。メモリの上限（件数・バイト）を持ち、超えれば、映像から破棄する
//
// 表記（テストの読みやすさのため）：チャンクを "Vk0 V33 A23" のように書く。
//   V = 映像・A = 音声。映像の k は、キーフレーム。数字は、メディア時刻（ミリ秒）。映像は 100 バイト、音声は 10 バイト
import { LIMITS } from "../contract";
import { Problems, seededRandom } from "../testing/helpers";
import { DEFAULT_MAX_BYTES, DEFAULT_MAX_CHUNKS, SendQueue, SendQueueOverflowError } from "./SendQueue";
import type { ChunkMeta } from "./SendQueue";

interface LabeledChunk extends ChunkMeta {
  readonly label: string;
}

const VIDEO_BYTES = 100;
const AUDIO_BYTES = 10;

/** "Vk0" "V33" "A23" から、チャンクを作る。 */
function chunk(label: string): LabeledChunk {
  const match = /^([VA])(k?)(\d+)$/.exec(label);
  if (match === null) {
    throw new Error(`bad chunk label: ${label}`);
  }
  const [, kind, key, milliseconds] = match;
  if (kind === "A" && key === "k") {
    throw new Error(`an audio chunk cannot be a keyframe: ${label}`);
  }
  return {
    label,
    kind: kind === "V" ? "video" : "audio",
    keyframe: key === "k",
    timestampUs: Number(milliseconds) * 1000,
    byteLength: kind === "V" ? VIDEO_BYTES : AUDIO_BYTES,
  };
}

function chunks(labels: string): LabeledChunk[] {
  return labels.trim() === "" ? [] : labels.trim().split(/\s+/).map(chunk);
}

/** 待ちの中身を、ラベルの並びにする（読むだけ。dequeue しない）。 */
function contents(queue: SendQueue<LabeledChunk>): string {
  return queue
    .snapshot()
    .map((item) => item.label)
    .join(" ");
}

function queueOf(labels: string, options?: ConstructorParameters<typeof SendQueue>[0]): SendQueue<LabeledChunk> {
  const queue = new SendQueue<LabeledChunk>(options);
  for (const item of chunks(labels)) {
    queue.enqueue(item);
  }
  return queue;
}

/** 全部 dequeue して、ラベルの並びにする。 */
function drain(queue: SendQueue<LabeledChunk>): string {
  const labels: string[] = [];
  for (let item = queue.dequeue(); item !== undefined; item = queue.dequeue()) {
    labels.push(item.label);
  }
  return labels.join(" ");
}

describe("契約との対応（安全弁の既定値は、契約の値から導く）", () => {
  test("件数の既定 = 10 秒分（映像 30 fps + 音声 AAC 1,024 サンプル = 毎秒 44 チャンク）。バイトの既定 = 10 秒分（映像の上限 6,000 + 音声 128 kbps）", () => {
    // 滞留が 4 秒を超えると全破棄（評価は 1 秒ごと）なので、正常な待ちは 5 秒分まで。その 2 倍
    expect(LIMITS.adaptive.conditions.backlog_critical.backlog_over_ms).toBe(4000);
    expect(LIMITS.adaptive.evaluation_interval_ms).toBe(1000);
    expect(DEFAULT_MAX_CHUNKS).toBe((30 + 44) * 10);
    expect(DEFAULT_MAX_BYTES).toBe(((6000 + 128) * 1000 * 10) / 8);
  });
});

describe("enqueue と dequeue：到着順", () => {
  test("映像と音声が交互に並ぶ到着順のまま、取り出せる。同じオブジェクトを返す（コピーしない）", () => {
    const labels = "Vk0 A0 A23 V33 A46 V66 A69 A92 V100";
    const queue = new SendQueue<LabeledChunk>();
    const items = chunks(labels);
    for (const item of items) {
      expect(queue.enqueue(item)).toEqual({ accepted: true, droppedVideoFrames: 0 });
    }
    expect(queue.length).toBe(9);
    for (const item of items) {
      expect(queue.dequeue()).toBe(item);
    }
    expect(queue.dequeue()).toBeUndefined();
    expect(queue.length).toBe(0);
  });

  test("件数・バイト数・映像と音声の数を、積むたびに、取り出すたびに、数える", () => {
    const queue = queueOf("Vk0 A0 V33 A23");
    expect({ length: queue.length, bytes: queue.byteLength, video: queue.videoLength, audio: queue.audioLength }).toEqual({ length: 4, bytes: 220, video: 2, audio: 2 });
    queue.dequeue();
    expect({ length: queue.length, bytes: queue.byteLength, video: queue.videoLength, audio: queue.audioLength }).toEqual({ length: 3, bytes: 120, video: 1, audio: 2 });
  });

  test("空のとき dequeue は undefined。snapshot は、待ちの中身の複製（書き換えても待ちは変わらない）", () => {
    const queue = new SendQueue<LabeledChunk>();
    expect(queue.dequeue()).toBeUndefined();
    queue.enqueue(chunk("Vk0"));
    const copy = queue.snapshot() as LabeledChunk[];
    copy.length = 0;
    expect(queue.length).toBe(1);
  });

  test("大量に積んで取り出しても、順序が保たれる（先頭の取り出しの積み重ねで、遅くならない）", () => {
    const queue = new SendQueue<LabeledChunk>({ maxChunks: 1_000_000, maxBytes: 1_000_000_000 });
    const total = 50_000;
    for (let index = 0; index < total; index += 1) {
      queue.enqueue({ label: String(index), kind: index % 2 === 0 ? "video" : "audio", keyframe: index === 0, timestampUs: index, byteLength: 1 });
    }
    const problems = new Problems();
    for (let index = 0; index < total; index += 1) {
      const item = queue.dequeue();
      if (item === undefined || item.label !== String(index)) {
        problems.report(`position ${index}: ${String(item?.label)}`);
      }
    }
    expect(problems.list()).toEqual([]);
    expect(queue.length).toBe(0);
  });
});

describe("enqueue：入力の検査（不正なチャンクは RangeError。状態は変わらない）", () => {
  const valid: ChunkMeta = { kind: "video", keyframe: true, timestampUs: 0, byteLength: 10 };

  test.each([
    ["種別が未知", { kind: "text" }],
    ["種別が無い", { kind: undefined }],
    ["時刻が負", { timestampUs: -1 }],
    ["時刻が小数", { timestampUs: 1.5 }],
    ["時刻が NaN", { timestampUs: Number.NaN }],
    ["時刻が無限大", { timestampUs: Number.POSITIVE_INFINITY }],
    ["時刻が安全整数を超える", { timestampUs: Number.MAX_SAFE_INTEGER + 1 }],
    ["時刻が文字列", { timestampUs: "0" }],
    ["バイト数が負", { byteLength: -1 }],
    ["バイト数が小数", { byteLength: 0.5 }],
    ["バイト数が NaN", { byteLength: Number.NaN }],
    ["キーフレームの指定が真偽値でない", { keyframe: 1 }],
    ["音声がキーフレーム", { kind: "audio", keyframe: true }],
  ])("%s", (_label, override) => {
    const queue = queueOf("A0");
    expect(() => queue.enqueue({ ...valid, ...override, label: "invalid" } as LabeledChunk)).toThrow(RangeError);
    expect(queue.length).toBe(1);
  });

  test("チャンクがオブジェクトでなければ RangeError", () => {
    expect(() => new SendQueue().enqueue(null as unknown as ChunkMeta)).toThrow(RangeError);
    expect(() => new SendQueue().enqueue(undefined as unknown as ChunkMeta)).toThrow(RangeError);
  });

  test("バイト数 0 は正しい（空のチャンク）", () => {
    expect(new SendQueue().enqueue({ ...valid, byteLength: 0 })).toEqual({ accepted: true, droppedVideoFrames: 0 });
  });

  test("同じ種別の時刻が逆行すれば RangeError（中継が破棄する。ブラウザで先に見つける）。同じ時刻は正しい。別の種別の時刻とは独立", () => {
    const queue = queueOf("Vk0 V33 A100");
    expect(() => queue.enqueue(chunk("V32"))).toThrow(RangeError);
    expect(() => queue.enqueue(chunk("A99"))).toThrow(RangeError);
    expect(queue.enqueue(chunk("V33"))).toEqual({ accepted: true, droppedVideoFrames: 0 });
    expect(queue.enqueue(chunk("A100"))).toEqual({ accepted: true, droppedVideoFrames: 0 });
    // 映像の時刻 33 は、音声の時刻 100 より小さいが、別の種別
    expect(queue.enqueue(chunk("V66"))).toEqual({ accepted: true, droppedVideoFrames: 0 });
    expect(contents(queue)).toBe("Vk0 V33 A100 V33 A100 V66");
  });

  test("破棄されたチャンクの時刻も、逆行の検査に使う（破棄しても、時刻の列は続く）", () => {
    const queue = queueOf("V0");
    queue.discardAllVideo();
    expect(queue.enqueue(chunk("V33"))).toMatchObject({ accepted: false });
    expect(() => queue.enqueue(chunk("V32"))).toThrow(RangeError);
  });
});

describe("dropVideoUntilNextKey：先頭の映像（破棄する映像）から、次のキーフレームの手前まで", () => {
  // [待ちの中身, 呼んだあとの待ち, 破棄した映像の数, 破棄中か]
  const table: ReadonlyArray<readonly [string, string, string, number, boolean]> = [
    ["空", "", "", 0, true],
    ["音声だけ（破棄する映像が無い）", "A0 A23", "A0 A23", 0, true],
    ["キーフレームと差分（次のキーフレームが無い）", "Vk0 V33 V66", "", 3, true],
    ["差分だけ（次のキーフレームが無い）", "V0 V33", "", 2, true],
    ["先頭がキーフレーム。続く差分と、次のキーフレームの手前まで", "Vk0 V33 V66 Vk100 V133", "Vk100 V133", 3, false],
    ["先頭が差分。次のキーフレームの手前まで", "V0 V33 Vk66 V100", "Vk66 V100", 2, false],
    ["音声は、破棄せず、元の順で残る", "A0 Vk0 A23 V33 A46 Vk66 A69 V100", "A0 A23 A46 Vk66 A69 V100", 2, false],
    ["キーフレームだけ（破棄すれば、続きが無い）", "Vk0", "", 1, true],
    ["キーフレームが 2 つ続く（先頭だけ）", "Vk0 Vk33", "Vk33", 1, false],
    ["破棄したあとに、音声だけが残る", "Vk0 A0 V33 A23", "A0 A23", 2, true],
  ];

  test.each(table)("%s", (_label, before, after, dropped, dropping) => {
    const queue = queueOf(before);
    expect(queue.dropVideoUntilNextKey()).toBe(dropped);
    expect(contents(queue)).toBe(after);
    expect(queue.droppingVideo).toBe(dropping);
    expect(queue.droppedVideoFrames).toBe(dropped);
  });

  test("破棄中は、キーフレームが来るまで、映像（差分）を積まず、数える。音声は積む。キーフレームの到着で解除する", () => {
    const queue = queueOf("Vk0 V33");
    queue.dropVideoUntilNextKey();
    expect(queue.droppingVideo).toBe(true);
    expect(queue.enqueue(chunk("V66"))).toEqual({ accepted: false, reason: "waiting_for_keyframe", droppedVideoFrames: 1 });
    expect(queue.enqueue(chunk("A0"))).toEqual({ accepted: true, droppedVideoFrames: 0 });
    expect(queue.enqueue(chunk("V100"))).toEqual({ accepted: false, reason: "waiting_for_keyframe", droppedVideoFrames: 1 });
    expect(queue.droppedVideoFrames).toBe(2 + 2);
    expect(queue.enqueue(chunk("Vk133"))).toEqual({ accepted: true, droppedVideoFrames: 0 });
    expect(queue.droppingVideo).toBe(false);
    expect(queue.enqueue(chunk("V166"))).toEqual({ accepted: true, droppedVideoFrames: 0 });
    expect(contents(queue)).toBe("A0 Vk133 V166");
  });

  test("破棄中の状態は、dequeue では変わらない（待ちを取り出しても、キーフレームが来るまで続く）", () => {
    const queue = queueOf("A0 Vk0 V33");
    queue.dropVideoUntilNextKey();
    expect(drain(queue)).toBe("A0");
    expect(queue.droppingVideo).toBe(true);
    expect(queue.enqueue(chunk("V66")).accepted).toBe(false);
  });

  test("次のキーフレームが待ちにあれば、破棄中にならない（そのキーフレームから先は、つながっている）。そのあとの差分は積める", () => {
    const queue = queueOf("Vk0 V33 Vk66");
    queue.dropVideoUntilNextKey();
    expect(queue.droppingVideo).toBe(false);
    expect(queue.enqueue(chunk("V100"))).toEqual({ accepted: true, droppedVideoFrames: 0 });
    expect(contents(queue)).toBe("Vk66 V100");
  });

  test("続けて呼ぶと、次の先頭の映像から、さらに破棄する", () => {
    const queue = queueOf("Vk0 V33 Vk66 V100 Vk133 V166");
    expect(queue.dropVideoUntilNextKey()).toBe(2);
    expect(contents(queue)).toBe("Vk66 V100 Vk133 V166");
    expect(queue.dropVideoUntilNextKey()).toBe(2);
    expect(contents(queue)).toBe("Vk133 V166");
    expect(queue.dropVideoUntilNextKey()).toBe(2);
    expect(contents(queue)).toBe("");
    expect(queue.droppingVideo).toBe(true);
    expect(queue.droppedVideoFrames).toBe(6);
  });
});

describe("discardAllVideo：待ちの映像を、すべて破棄する（滞留が 4 秒を超えたとき。キーフレームの発行は、呼び出し側が指示する）", () => {
  const table: ReadonlyArray<readonly [string, string, string, number]> = [
    ["空", "", "", 0],
    ["音声だけ", "A0 A23", "A0 A23", 0],
    ["映像だけ", "Vk0 V33 Vk66", "", 3],
    ["映像と音声の混在（音声は残る）", "Vk0 A0 V33 A23 Vk66 A46 V100", "A0 A23 A46", 4],
  ];

  test.each(table)("%s", (_label, before, after, dropped) => {
    const queue = queueOf(before);
    expect(queue.discardAllVideo()).toBe(dropped);
    expect(contents(queue)).toBe(after);
    expect(queue.droppedVideoFrames).toBe(dropped);
  });

  test("あとは、破棄中になり、次のキーフレームから積む（呼び出し側が、直ちにキーフレームを発行する）", () => {
    const queue = queueOf("Vk0 V33 A0");
    queue.discardAllVideo();
    expect(queue.droppingVideo).toBe(true);
    expect(queue.enqueue(chunk("V66")).accepted).toBe(false);
    expect(queue.enqueue(chunk("Vk100")).accepted).toBe(true);
    expect(queue.droppingVideo).toBe(false);
    expect(queue.enqueue(chunk("V133")).accepted).toBe(true);
    expect(contents(queue)).toBe("A0 Vk100 V133");
  });

  test("映像が待ちに無くても、破棄中になる（次に積む映像が、必ずキーフレームから始まる）", () => {
    const queue = queueOf("A0 A23");
    queue.discardAllVideo();
    expect(queue.droppingVideo).toBe(true);
  });

  test("破棄した数は、累計に加わる（dropVideoUntilNextKey と、破棄中に捨てた分も含む）", () => {
    const queue = queueOf("Vk0 V33");
    queue.discardAllVideo();
    queue.enqueue(chunk("V66"));
    queue.enqueue(chunk("Vk100"));
    queue.enqueue(chunk("V133"));
    queue.discardAllVideo();
    expect(queue.droppedVideoFrames).toBe(2 + 1 + 2);
  });
});

describe("音声は、どんな破棄の操作でも、破棄しない", () => {
  test.each([
    ["dropVideoUntilNextKey", (queue: SendQueue<LabeledChunk>) => queue.dropVideoUntilNextKey()],
    ["discardAllVideo", (queue: SendQueue<LabeledChunk>) => queue.discardAllVideo()],
  ])("%s のあとも、音声がすべて残る（順序も）", (_name, operation) => {
    const queue = queueOf("A0 Vk0 A23 V33 A46 V66 A69 Vk100 A92");
    operation(queue);
    expect(contents(queue).split(" ").filter((label) => label.startsWith("A"))).toEqual(["A0", "A23", "A46", "A69", "A92"]);
  });

  test("破棄中に積む音声も、すべて積まれる", () => {
    const queue = queueOf("Vk0");
    queue.discardAllVideo();
    for (let index = 0; index < 50; index += 1) {
      expect(queue.enqueue(chunk(`A${index * 23}`)).accepted).toBe(true);
    }
    expect(queue.audioLength).toBe(50);
  });
});

describe("再接続中は、符号化結果を捨てる（送信待ちに積まない。requirements.md 12 章）", () => {
  test("suspend は、待ちを空にし（映像・音声の数を返す）、以後の enqueue は積まない。数は、破棄フレーム数とは別に数える", () => {
    const queue = queueOf("Vk0 A0 V33 A23");
    expect(queue.suspend()).toEqual({ video: 2, audio: 2 });
    expect(queue.suspended).toBe(true);
    expect(queue.length).toBe(0);
    expect(queue.enqueue(chunk("V66"))).toEqual({ accepted: false, reason: "suspended", droppedVideoFrames: 0 });
    expect(queue.enqueue(chunk("A46"))).toEqual({ accepted: false, reason: "suspended", droppedVideoFrames: 0 });
    expect(queue.length).toBe(0);
    expect(queue.suspendedDiscards).toEqual({ video: 2 + 1, audio: 2 + 1 });
    expect(queue.droppedVideoFrames).toBe(0);
  });

  test("resume すると、積むのを再開する。映像は、次のキーフレームから（再開の直後は、破棄中）。音声は、すぐ積む", () => {
    const queue = queueOf("Vk0 A0");
    queue.suspend();
    queue.resume();
    expect(queue.suspended).toBe(false);
    expect(queue.droppingVideo).toBe(true);
    expect(queue.enqueue(chunk("A23")).accepted).toBe(true);
    expect(queue.enqueue(chunk("V33"))).toEqual({ accepted: false, reason: "waiting_for_keyframe", droppedVideoFrames: 1 });
    expect(queue.enqueue(chunk("Vk66")).accepted).toBe(true);
    expect(queue.enqueue(chunk("V100")).accepted).toBe(true);
    expect(contents(queue)).toBe("A23 Vk66 V100");
  });

  test("suspend は冪等（2 回目は、数を 0 で返す）。suspend していない resume は、何もしない（破棄中にしない）", () => {
    const queue = queueOf("Vk0");
    queue.suspend();
    expect(queue.suspend()).toEqual({ video: 0, audio: 0 });
    const fresh = new SendQueue<LabeledChunk>();
    fresh.resume();
    expect(fresh.droppingVideo).toBe(false);
    expect(fresh.suspended).toBe(false);
  });

  test("再接続のあいだも、送信済みの最新時刻は保たれる（時計は続く）", () => {
    const queue = queueOf("Vk0 A0");
    queue.dequeue();
    queue.dequeue();
    queue.suspend();
    queue.resume();
    queue.enqueue(chunk("A23"));
    queue.dequeue();
    expect(queue.latestSentUs).toBe(23_000);
  });
});

describe("滞留時間 backlogMs(ackedVideoUs, ackedAudioUs)", () => {
  /** 送信済み（dequeue した）チャンクの、最新のメディア時刻が sentLatestMs のキューを作る。 */
  function sentQueue(labels: string): SendQueue<LabeledChunk> {
    const queue = queueOf(labels);
    drain(queue);
    return queue;
  }

  test("= 送信済みの最新メディア時刻 - 受領済みと応答された最新メディア時刻（映像・音声のうち古い方）。ミリ秒", () => {
    // 送信済みの最新は 2,000 ms（音声）。受領済みは、映像 500 ms・音声 1,000 ms。古い方（映像）との差 = 1,500 ms
    const queue = sentQueue("Vk0 V1500 A2000");
    expect(queue.backlogMs(500_000, 1_000_000)).toBe(1500);
    // 古い方が音声のとき
    expect(queue.backlogMs(1_800_000, 600_000)).toBe(1400);
  });

  test.each([
    ["ちょうど 1,500 ms（1.5 秒を超えない）", 3_500_000, 2_000_000, 1500],
    ["1,500.001 ms（1 マイクロ秒だけ超える）", 3_500_001, 2_000_000, 1500.001],
    ["1,499.999 ms", 3_499_999, 2_000_000, 1499.999],
    ["ちょうど 300 ms", 2_300_000, 2_000_000, 300],
    ["299.999 ms", 2_299_999, 2_000_000, 299.999],
    ["ちょうど 4,000 ms", 6_000_000, 2_000_000, 4000],
    ["4,000.001 ms", 6_000_001, 2_000_000, 4000.001],
    ["ちょうど 8,000 ms", 10_000_000, 2_000_000, 8000],
    ["差が 0（受領済みが送信済みに追いついた）", 2_000_000, 2_000_000, 0],
  ])("境界：%s", (_label, sentUs, ackedUs, expectedMs) => {
    const queue = new SendQueue<ChunkMeta>();
    queue.enqueue({ kind: "audio", keyframe: false, timestampUs: sentUs, byteLength: 1 });
    queue.dequeue();
    expect(queue.backlogMs(ackedUs, ackedUs)).toBe(expectedMs);
  });

  test("受領済みが、送信済みより新しい（応答が、後から積んだ分を含む）ときは 0（負にしない）", () => {
    const queue = sentQueue("Vk0 A23");
    expect(queue.backlogMs(900_000, 900_000)).toBe(0);
  });

  test("送信済みの最新は、映像・音声のうち新しい方（dequeue したものだけ）。待ちのまま（未送信）のチャンクは、数えない", () => {
    const queue = queueOf("Vk0 A23 V3000 A5000");
    queue.dequeue(); // Vk0
    queue.dequeue(); // A23
    expect(queue.latestSentUs).toBe(23_000);
    expect(queue.backlogMs(10_000, 10_000)).toBe(13);
    queue.dequeue(); // V3000
    expect(queue.latestSentUs).toBe(3_000_000);
    expect(queue.backlogMs(1_000_000, 1_000_000)).toBe(2000);
  });

  test("破棄したチャンクは、送信済みに数えない", () => {
    const queue = queueOf("Vk0 A0 V5000");
    queue.dequeue();
    queue.dequeue();
    queue.discardAllVideo();
    expect(queue.latestSentUs).toBe(0);
    expect(queue.dequeue()).toBeUndefined();
  });

  describe("受領応答が来る前の初期値（その接続の最初の ack を受けるまで、評価しない）", () => {
    test("映像・音声のどちらかの受領応答が無い（undefined）とき、滞留時間は評価できない（undefined）。0 を返さない", () => {
      const queue = sentQueue("Vk0 A5000");
      expect(queue.backlogMs(undefined, undefined)).toBeUndefined();
      expect(queue.backlogMs(1_000_000, undefined)).toBeUndefined();
      expect(queue.backlogMs(undefined, 1_000_000)).toBeUndefined();
    });

    test("受領応答の値が 0 の種別は、中継がまだ 1 つも受けていない（契約の 5.10）ので、評価できない（undefined）", () => {
      const queue = sentQueue("Vk0 A120000");
      expect(queue.backlogMs(0, 100_000_000)).toBeUndefined();
      expect(queue.backlogMs(100_000_000, 0)).toBeUndefined();
      expect(queue.backlogMs(0, 0)).toBeUndefined();
    });

    test("何も送信していない（dequeue していない）ときは、受領応答があっても、滞留は 0（未処理のものが無い）。受領応答が無ければ undefined", () => {
      const queue = queueOf("Vk0 A0");
      expect(queue.backlogMs(1_000_000, 1_000_000)).toBe(0);
      expect(queue.backlogMs(undefined, undefined)).toBeUndefined();
    });

    test("ページの再読み込み・再接続の直後：新しい接続の最初の ack まで undefined。最初の ack で、その接続の値から評価が始まる", () => {
      const queue = new SendQueue<LabeledChunk>();
      // 接続が成立し、送り始める（メディア時刻は、0 から数え直し）
      for (const item of chunks("Vk0 A0 V33 A23 V66 A46")) {
        queue.enqueue(item);
      }
      drain(queue);
      expect(queue.backlogMs(undefined, undefined)).toBeUndefined();
      // その接続の最初の ack（中継が受けた最新の時刻）
      expect(queue.backlogMs(66_000, 46_000)).toBe(20);
    });
  });

  test.each([
    ["映像が負", [-1, 1]],
    ["音声が負", [1, -1]],
    ["映像が小数", [1.5, 1]],
    ["音声が NaN", [1, Number.NaN]],
    ["映像が無限大", [Number.POSITIVE_INFINITY, 1]],
    ["音声が安全整数を超える", [1, Number.MAX_SAFE_INTEGER + 1]],
    ["映像が文字列", ["1", 1]],
    ["音声が null", [1, null]],
  ])("不正な受領応答（%s）は、推測せず RangeError", (_label, [video, audio]) => {
    const queue = sentQueue("Vk0 A1000");
    expect(() => queue.backlogMs(video as number, audio as number)).toThrow(RangeError);
  });

  test("backlogMs は、状態を変えない（呼び出しても、待ちも、最新の送信済みの時刻も変わらない）", () => {
    const queue = queueOf("Vk0 A1000 V2000");
    queue.dequeue();
    queue.dequeue();
    const before = { length: queue.length, latest: queue.latestSentUs };
    queue.backlogMs(1_000, 1_000);
    expect({ length: queue.length, latest: queue.latestSentUs }).toEqual(before);
  });
});

describe("メモリの上限（安全弁）：件数・バイト。超えたら、映像から破棄する", () => {
  test("件数の上限：映像（最も古い映像と、続く次のキーフレームの手前まで）から破棄し、音声は破棄しない", () => {
    const queue = new SendQueue<LabeledChunk>({ maxChunks: 6, maxBytes: 1_000_000 });
    for (const item of chunks("Vk0 A0 V33 A23 V66 A46")) {
      queue.enqueue(item);
    }
    expect(queue.length).toBe(6);
    // 7 件目（音声）が来る。映像の先頭（Vk0）から、次のキーフレームの手前まで（V33・V66 も。次のキーフレームが無い）を破棄する
    expect(queue.enqueue(chunk("A69"))).toEqual({ accepted: true, droppedVideoFrames: 3 });
    expect(contents(queue)).toBe("A0 A23 A46 A69");
    expect(queue.droppingVideo).toBe(true);
    expect(queue.droppedVideoFrames).toBe(3);
  });

  test("バイトの上限：超えれば、映像から破棄する", () => {
    const queue = new SendQueue<LabeledChunk>({ maxChunks: 1_000, maxBytes: 250 });
    for (const item of chunks("Vk0 V33")) {
      queue.enqueue(item);
    }
    // 200 バイト。映像 100 バイトを足すと 300 バイトになり、上限（250）を超える
    const result = queue.enqueue(chunk("V66"));
    expect(queue.byteLength).toBeLessThanOrEqual(250);
    expect(result.droppedVideoFrames).toBeGreaterThanOrEqual(1);
  });

  test("次のキーフレームが待ちにあれば、そこから先を残す（破棄中にならない）。到着した差分は、積める", () => {
    const queue = new SendQueue<LabeledChunk>({ maxChunks: 5, maxBytes: 1_000_000 });
    for (const item of chunks("Vk0 V33 Vk66 V100 V133")) {
      queue.enqueue(item);
    }
    // 6 件目の映像（差分）：先頭の Vk0 と V33（次のキーフレーム Vk66 の手前まで）を破棄し、V166 を積む
    expect(queue.enqueue(chunk("V166"))).toEqual({ accepted: true, droppedVideoFrames: 2 });
    expect(contents(queue)).toBe("Vk66 V100 V133 V166");
    expect(queue.droppingVideo).toBe(false);
  });

  test("映像が待ちに無く、音声だけで上限に達しているとき、新しい映像は積まずに破棄し（破棄中になる）、音声は SendQueueOverflowError", () => {
    const queue = new SendQueue<LabeledChunk>({ maxChunks: 3, maxBytes: 1_000_000 });
    for (const item of chunks("A0 A23 A46")) {
      queue.enqueue(item);
    }
    expect(queue.enqueue(chunk("Vk0"))).toEqual({ accepted: false, reason: "over_capacity", droppedVideoFrames: 1 });
    expect(queue.droppingVideo).toBe(true);
    expect(queue.length).toBe(3);
    // 音声は、破棄しない。積めないので、エラー（呼び出し側が、接続の不調として扱う）。待ちは変わらない
    expect(() => queue.enqueue(chunk("A69"))).toThrow(SendQueueOverflowError);
    expect(contents(queue)).toBe("A0 A23 A46");
  });

  test("1 チャンクだけで、バイトの上限を超える映像は、積めない（破棄して、破棄中になる）。音声なら SendQueueOverflowError", () => {
    const queue = new SendQueue<LabeledChunk>({ maxChunks: 100, maxBytes: 50 });
    const big = { label: "big", kind: "video", keyframe: true, timestampUs: 0, byteLength: 51 } as const;
    expect(queue.enqueue(big)).toEqual({ accepted: false, reason: "over_capacity", droppedVideoFrames: 1 });
    expect(queue.droppingVideo).toBe(true);
    const bigAudio = { label: "bigA", kind: "audio", keyframe: false, timestampUs: 0, byteLength: 51 } as const;
    expect(() => queue.enqueue(bigAudio)).toThrow(SendQueueOverflowError);
  });

  test("SendQueueOverflowError は、符号と、件数・バイトの数値だけを持つ（チャンクの中身を含めない）", () => {
    const queue = new SendQueue<LabeledChunk>({ maxChunks: 1, maxBytes: 1_000 });
    queue.enqueue(chunk("A0"));
    try {
      queue.enqueue(chunk("A23"));
      throw new Error("expected an overflow");
    } catch (error) {
      expect(error).toBeInstanceOf(SendQueueOverflowError);
      expect((error as SendQueueOverflowError).code).toBe("send_queue_overflow");
      expect((error as Error).message).toMatch(/chunks|bytes/);
    }
  });

  test.each([
    ["maxChunks が 0", { maxChunks: 0 }],
    ["maxChunks が負", { maxChunks: -1 }],
    ["maxChunks が小数", { maxChunks: 1.5 }],
    ["maxBytes が 0", { maxBytes: 0 }],
    ["maxBytes が NaN", { maxBytes: Number.NaN }],
    ["maxDropHistory が 0", { maxDropHistory: 0 }],
  ])("上限の指定が不正（%s）は RangeError", (_label, options) => {
    expect(() => new SendQueue(options)).toThrow(RangeError);
  });

  test("上限を指定しなければ、契約から導いた既定（件数・バイト）を使う", () => {
    const queue = new SendQueue<ChunkMeta>();
    expect(queue.maxChunks).toBe(DEFAULT_MAX_CHUNKS);
    expect(queue.maxBytes).toBe(DEFAULT_MAX_BYTES);
  });
});

describe("破棄の履歴（適応制御の「直近 10 秒に破棄がない」の入力。メディアクロック由来の秒）", () => {
  test("破棄の操作・破棄中に捨てた映像・上限による破棄の時刻（その時点の、最新のメディア時刻）を、秒で返す", () => {
    const queue = queueOf("Vk0 A0 V33 A23 V66");
    expect(queue.dropHistorySec()).toEqual([]);
    queue.discardAllVideo(); // この時点の最新は 66 ms
    queue.enqueue(chunk("V100")); // 破棄中に捨てる（そのチャンクの時刻）
    queue.enqueue(chunk("V133"));
    expect(queue.dropHistorySec()).toEqual([0.066, 0.1, 0.133]);
  });

  test("映像を破棄しなかった dropVideoUntilNextKey は、履歴に残さない。全破棄の指示（discardAllVideo）は、待ちが空でも残す（破棄フレーム数は増えない）", () => {
    const queue = queueOf("A0 A23");
    expect(queue.dropVideoUntilNextKey()).toBe(0);
    expect(queue.dropHistorySec()).toEqual([]);
    expect(queue.discardAllVideo()).toBe(0);
    expect(queue.dropHistorySec()).toEqual([0.023]);
    expect(queue.droppedVideoFrames).toBe(0);
  });

  test("再接続中に捨てた分は、履歴に残さない（輻輳による破棄ではない）", () => {
    const queue = queueOf("Vk0");
    queue.suspend();
    queue.enqueue(chunk("V33"));
    expect(queue.dropHistorySec()).toEqual([]);
  });

  test("履歴の長さには上限がある（最新のものを残す。積み上がり続けない）", () => {
    const queue = new SendQueue<LabeledChunk>({ maxDropHistory: 3 });
    queue.enqueue(chunk("Vk0"));
    queue.discardAllVideo();
    for (let index = 1; index <= 10; index += 1) {
      queue.enqueue(chunk(`V${index * 33}`));
    }
    expect(queue.dropHistorySec()).toEqual([0.264, 0.297, 0.33]);
  });

  test("履歴は複製（書き換えても、キューの履歴は変わらない）", () => {
    const queue = queueOf("Vk0 V33");
    queue.discardAllVideo();
    const history = queue.dropHistorySec() as number[];
    history.length = 0;
    expect(queue.dropHistorySec()).toHaveLength(1);
  });
});

describe("性質の検査（決定的な乱数。操作の列は、毎回同じ）", () => {
  interface Tracked extends ChunkMeta {
    readonly index: number;
  }

  /**
   * 乱数で、積む・取り出す・破棄する操作を繰り返し、毎回、次を確かめる。
   *   1. 受理した音声は、取り出されるか、待ちに残る（破棄されない）
   *   2. 取り出した映像は、その前に破棄された映像があれば、必ずキーフレーム（差分から再開しない）
   *   3. 件数・バイトの上限を超えない。数えた値（件数・バイト・映像と音声の数）が、待ちの中身と一致する
   *   4. 取り出した順は、同じ種別の中で、時刻の順
   *   5. 1 回の操作で破棄した映像の数が、破棄フレーム数（累計）の増分と一致する
   */
  function runSequence(seed: number, problems: Problems): void {
    const random = seededRandom(seed);
    const maxChunks = 4 + Math.floor(random() * 12);
    const maxBytes = 300 + Math.floor(random() * 1_500);
    const queue = new SendQueue<Tracked>({ maxChunks, maxBytes });
    const fail = (step: number, message: string): void => problems.report(`seed ${seed} step ${step}: ${message}`);

    let arrival = 0;
    let videoTime = 0;
    let audioTime = 0;
    let videoCount = 0;
    const videoIndices: number[] = [];
    const acceptedAudio = new Set<number>();
    const dequeuedAudio = new Set<number>();
    let previousVideoDequeued = -1;
    const lastTimeByKind = { video: -1, audio: -1 };
    let droppedTotal = 0;

    const queuedIndices = (): Set<number> => new Set(queue.snapshot().map((item) => item.index));

    for (let step = 0; step < 120; step += 1) {
      const before = queue.snapshot();
      const beforeVideo = before.filter((item) => item.kind === "video").map((item) => item.index);
      let incomingVideoDropped = 0;
      let dequeued: Tracked | undefined;
      const roll = random();

      if (roll < 0.45) {
        const index = arrival;
        arrival += 1;
        if (random() < 0.55) {
          videoTime += 33;
          const keyframe = videoCount % 6 === 0 || random() < 0.05;
          videoCount += 1;
          videoIndices.push(index);
          const result = queue.enqueue({ index, kind: "video", keyframe, timestampUs: videoTime * 1000, byteLength: 50 + Math.floor(random() * 120) });
          if (!result.accepted) {
            incomingVideoDropped = 1;
          }
        } else {
          audioTime += 23;
          try {
            const result = queue.enqueue({ index, kind: "audio", keyframe: false, timestampUs: audioTime * 1000, byteLength: 5 + Math.floor(random() * 20) });
            if (result.accepted) {
              acceptedAudio.add(index);
            }
          } catch (error) {
            if (!(error instanceof SendQueueOverflowError)) {
              throw error;
            }
          }
        }
      } else if (roll < 0.85) {
        dequeued = queue.dequeue();
        if (dequeued !== undefined) {
          if (dequeued.kind === "audio") {
            dequeuedAudio.add(dequeued.index);
          } else {
            const lostBefore = videoIndices.some((index) => index > previousVideoDequeued && index < (dequeued as Tracked).index);
            if (lostBefore && !dequeued.keyframe) {
              fail(step, `video ${dequeued.index} is a delta frame after a dropped frame`);
            }
            previousVideoDequeued = dequeued.index;
          }
          if (dequeued.timestampUs < lastTimeByKind[dequeued.kind]) {
            fail(step, `${dequeued.kind} ${dequeued.index} went back in time`);
          }
          lastTimeByKind[dequeued.kind] = dequeued.timestampUs;
        }
      } else if (roll < 0.93) {
        queue.dropVideoUntilNextKey();
      } else {
        queue.discardAllVideo();
      }

      // 件数・バイト・種別ごとの数が、待ちの中身と一致し、上限を超えない
      const after = queue.snapshot();
      if (queue.length !== after.length || queue.videoLength !== after.filter((item) => item.kind === "video").length || queue.audioLength !== after.filter((item) => item.kind === "audio").length) {
        fail(step, "the counters differ from the contents");
      }
      if (queue.byteLength !== after.reduce((sum, item) => sum + item.byteLength, 0)) {
        fail(step, "the byte counter differs from the contents");
      }
      if (queue.length > maxChunks || queue.byteLength > maxBytes) {
        fail(step, `over the limit (${queue.length} chunks, ${queue.byteLength} bytes)`);
      }
      // この操作で待ちから消えた映像（取り出したものを除く）+ 積まれなかった映像 = 破棄フレーム数の増分
      const afterIndices = queuedIndices();
      const removedVideo = beforeVideo.filter((index) => !afterIndices.has(index) && index !== dequeued?.index).length;
      const lost = removedVideo + incomingVideoDropped;
      if (queue.droppedVideoFrames - droppedTotal !== lost) {
        fail(step, `dropped frames changed by ${queue.droppedVideoFrames - droppedTotal}, but ${lost} video chunks were lost`);
      }
      droppedTotal = queue.droppedVideoFrames;
      // 待ちから音声が消えるのは、取り出したときだけ
      for (const item of before) {
        if (item.kind === "audio" && !afterIndices.has(item.index) && item.index !== dequeued?.index) {
          fail(step, `audio ${item.index} left the queue without being dequeued`);
        }
      }
    }

    const remainingAudio = new Set(queue.snapshot().filter((item) => item.kind === "audio").map((item) => item.index));
    for (const index of acceptedAudio) {
      if (!dequeuedAudio.has(index) && !remainingAudio.has(index)) {
        fail(120, `audio ${index} was lost`);
      }
    }
  }

  test("1,000 通りの操作の列で、上の 5 つの性質が、いつも成り立つ", () => {
    const problems = new Problems();
    for (let seed = 1; seed <= 1_000; seed += 1) {
      runSequence(seed, problems);
    }
    expect(problems.list()).toEqual([]);
  });
});

describe("ジェネリック：チャンクの中身（符号化データ）を、キューは見ない", () => {
  test("追加の項目（data）を持つチャンクを、そのまま扱う", () => {
    interface WithData extends ChunkMeta {
      readonly data: Uint8Array;
    }
    const queue = new SendQueue<WithData>();
    const item: WithData = { kind: "video", keyframe: true, timestampUs: 0, byteLength: 3, data: Uint8Array.from([1, 2, 3]) };
    queue.enqueue(item);
    expect(queue.dequeue()?.data).toBe(item.data);
  });
});
