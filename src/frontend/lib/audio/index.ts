// 音声の混合（requirements.md 11.5・11.6。issue #26）の公開 API。
// 配信の制御（#28）・エンコード（#27）は、ここから import する。テストの道具（test-support.ts・worklet-harness.ts）は、公開しない。
//
// 使い方（開始の操作（利用者のクリック）のハンドラの中で）
//   const mixer = new AudioMixer({ environment: createBrowserAudioEnvironment(window) });
//   const unbind = bindSourcesToMixer(sourceManager, mixer);        // マイク・共有音声の取得・喪失を、混合の対象へ反映する
//   mixer.subscribe(new AudioClockDriver(clock, (tick) => { ... })); // または、MessageChannel の片方を start({sink}) へ渡し、ワーカーで AudioClockDriver を使う
//   mixer.subscribe({ onStall, onResume });                         // 停止・再開（メディアクロックの onAudioStall・onAudioResume）
//   await mixer.start();                                            // 呼び出しの中で、AudioContext を resume する

export { AudioMixer } from "./AudioMixer";
export type { AudioMixerFault, AudioMixerFaultCode, AudioMixerListener, AudioMixerOptions, AudioMixerStartOptions, AudioMixerStatus } from "./AudioMixer";
export { AudioClockDriver } from "./AudioClockDriver";
export type { AudioTick, AudioTickHandler } from "./AudioClockDriver";
export { bindSourcesToMixer } from "./bindSourcesToMixer";
export type { SourceBindingSource, SourceBindingTarget } from "./bindSourcesToMixer";
export { createBrowserAudioEnvironment } from "./environment";
export type { AudioEnvironment, BrowserAudioScope } from "./environment";
export { AUDIO_MIXER_ERROR_CODES, AudioContinuityError, AudioMixerError, WorkletProtocolError } from "./errors";
export type { AudioMixerErrorCode, WorkletProtocolErrorReason } from "./errors";
export { DEFAULT_MIXER_GAINS, MIXER_GAIN_MAX, MIXER_INPUT_KINDS, MIXER_SAMPLE_RATE_HZ, isMixerInputKind } from "./config";
export type { MixerInputKind } from "./config";
export { createMixerParameters, createMixerState, deinterleave, interleave, mixBlock, setTargetGain } from "./MixerCore";
export type { MixerParameters, MixerState, PlanarBlock } from "./MixerCore";
export type { MixedAudioBlock } from "./workletProtocol";
