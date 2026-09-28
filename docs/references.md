# 参考資料

確認日: 2026-09-28。以下はベンダー・Appleの一次資料。具体的な経路、バッファ、復旧方針、GUIは本プロジェクトの設計判断であり、メーカーの性能保証ではない。

## RME

- [Fireface UCX II User's Guide](https://rme-audio.de/downloads/fface_ucx2_e.pdf)
  - 27.6 Loopback: Hardware Outputのサブミックスをホスト録音入力へ返す。対応する物理入力はホスト録音から置換され、TotalMix内には残る。旧案と既存設定を理解するための資料であり、最新設計はRME Loopbackを使用しない。
  - 41.1 channel/block diagram: SPDIF9/10、AES11/12、ADAT13–20。今回のCore Audio実列挙でも一致した。

## Antelope

- [Discrete 4 User Manual](https://support.antelopeaudio.com/en/support/solutions/articles/42000016944-discrete-4-user-manual)
  - Computer Play1–16はDAWからの再生チャンネル。ミキサーsource、digital I/O、clock sourceを確認するための資料。
  - 初代のBNCはWord Clock出力。RME WC Out → Discrete4 WC Inという未確認の接続を設計しない。
- [Discrete 4 / 8 Routing Guide](https://testsupport.antelopeaudio.com/en/support/solutions/articles/42000067759-discrete-4-8-routing-guide)
  - Computer PlayとDAW Recordの方向、source別ミキサー／AFXの扱い。
- [How to Use Loopback with Discrete and Zen Go/Q Interfaces](https://support.antelopeaudio.com/en/support/solutions/articles/42000096671-how-to-use-loopback-with-discrete-and-zen-go-q-interfaces)
  - Monitor/HP1等のミックスをDAW Recordへ割り当てる。SCを例に全Discrete向けと説明。
  - 物理Monitorノブ後と同じ信号か、全FXのtap位置が要件に合うかは別途実測する。
- [Using Antelope Interfaces with Streamer Software](https://support.antelopeaudio.com/en/support/solutions/articles/42000099254-using-antelope-interfaces-with-streamer-software)
  - Discrete4、SC、Proを対象に含むLoopback利用例。世代差は実機のメニューで確認する。

## Apple

- [Set aggregate device settings in Audio MIDI Setup](https://support.apple.com/en-sa/guide/audio-midi-setup/ams094c7edb4/mac)
  - 機器間のサンプルレート、ハードウェア同期、ドリフト補正の関係。RMEとDiscrete4を一つのAggregateへ結合する方式は不採用。Tap取得用コンテナとは区別する。
- [AudioHardwareAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice)
- [AudioHardwareCreateAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- [kAudioAggregateDeviceIsPrivateKey](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedeviceisprivatekey)
- [AudioDeviceIOProc](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc)
- [CAPlayThrough](https://developer.apple.com/library/archive/samplecode/CAPlayThrough/Introduction/Intro.html)
  - 独立した入力・出力のAUHALとring buffer、Varispeedで微小なレート差を補償する先例。2013年のアーカイブ資料で、現行OS・ドライバーの性能保証ではない。
- [Analyzing audio performance with Instruments](https://developer.apple.com/documentation/audiotoolbox/analyzing-audio-performance-with-instruments)
- [Understanding audio workgroups](https://developer.apple.com/documentation/audiotoolbox/understanding-audio-workgroups)
- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  - 現在の第一評価候補。processの出力取得、mixdown指定、private Tap、元出力のmute、TapをAggregateの入力として使用する公式手順を確認。
  - `NSAudioCaptureUsageDescription`とシステム音声録音許可が必要。記事内の実行要件はmacOS 14.2以降。Tapだけのコンテナ構成や64-frame動作を保証する資料ではない。
- [CATapDescription: device/streamを指定した除外型Tap](https://developer.apple.com/documentation/coreaudio/catapdescription/initexcludingprocesses%3Aanddeviceuid%3Awithstream%3A?language=objc)
  - 指定した出力deviceのstreamへ向かうprocess音声を取得し、Tap形式はそのstream形式に一致する。自アプリを除外し、non-mixdownでPC出力チャンネルを維持する設計の根拠。
  - stream indexはユーザー向けchannel番号とは別。既存Aggregate経由の音声を物理RMEのUID指定で取得できるか、各channelがどう対応するかは実測する。
- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
  - `deviceUID`、`stream`、`isMixdown`、`isExclusive`、`muteBehavior`等の設定。global stereo取得だけに限定したAPIではない。
- [Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
  - 仮想出力方式を採る場合の一次資料。標準Cによる仮想デバイスの公式サンプルは2ch Float32 I/O、44.1/48 kHz。
  - サンプルは`.driver`を`/Library/Audio/Plug-Ins/HAL`へ導入して再起動する手順。独自の多chデバイス、配布・更新、低遅延は別途設計・検証が必要。今回インストールしない。

APIページに加え、このMacのXcode SDKの`CoreAudio.framework/Headers/AudioHardware.h`、`AudioHardwareBase.h`、`CATapDescription.h`、`AudioHardwareTapping.h`を確認した。private aggregateの公開範囲・寿命、main subdeviceとclock deviceの意味、drift compensation、IOProcの入出力時刻、NULL stream、buffer/latency/safety offsetに加え、device/stream Tap、mute動作、`kAudioTapPropertyFormat`、Tap構成キーとsubtapの遅延／ドリフト補正を参照した。`AudioHardwareCreateProcessTap`のAPI availabilityはmacOS 14.2。private Tapとprivate Aggregateは別の設定である。

Tap取得にAggregateコンテナを用いることは公開仕様に基づく。一方、物理subdeviceなしのTap-only稼働、時刻基準に必要なデバイスの選択、現在の5.1ch／DTMを含むチャンネル対応、複数Tapの混合時刻、実遅延は未検証。これらを公式に成立保証された構成として扱わない。

## SRC

- [libsamplerate Full API](https://libsndfile.github.io/libsamplerate/api_full.html)
  - 連続ストリーム、可変比率、実消費／生成frame数。src_ratioはoutput/input。src_set_ratioは通常の比率変更の平滑化を飛ばす。
- [libsamplerate converter types](https://libsndfile.github.io/libsamplerate/api_misc.html)
- [libsamplerate License](https://libsndfile.github.io/libsamplerate/license.html)
  - BSD 2-Clauseへ再ライセンスされたことを確認。採用versionの表記を同梱する。
- [libsamplerate 0.2.2 sinc実装](https://github.com/libsndfile/libsamplerate/blob/0.2.2/src/src_sinc.c)
  - 候補versionの内部バッファ確認に使用。全versionのRT性を保証する資料ではない。
- [SpeexDSP resampler実装](https://github.com/xiph/speexdsp/blob/master/libspeexdsp/resample.c)
  - 比率変更時のfilter更新・再確保経路が評価対象。masterは可変なので、採用検討時にはcommitを固定する。

公式0.2.2を一時領域で静的ビルドし、このMacでオフラインの先読み・処理時間を測定した。[方法・再現手順](measurements/2026-09-28-src/README.md)と[遅延予算](latency-budget.md)を参照。システムへのインストール、音声I/Oの開始、RME/Discrete4を使った性能試験は行っていない。

## 隣接プロジェクト

- [my-lan-audio2 README](../../my-lan-audio2/README.md): I/O frame数とネットワーク受信バッファの区別。
- [macOS receiver実装資料](../../my-lan-audio2/docs/macos-receiver.md): 小I/Oサイズの試験と制約。
- [receiver wakeup測定](../../my-lan-audio2/docs/receiver-wakeup.md): CPUと受信待ちの測定条件。

MCP graphでCore Audio buffer設定、AUHAL callback、Rustの線形ASRC・レート推定を確認し、保存ログと照合した。新アプリの小バッファ実装の参考であり、Discrete4やSinc往復の性能保証としては使わない。

## ローカル観測の根拠

個別ミックスとTotalMix premixの演算比較は[性能比較](mixing-performance.md)、[計測方法・ソース・結果](measurements/2026-09-28-mix/README.md)を参照。Apple M4 Max上で合成信号を使ったオフライン試験で、機器の音声I/Oは開始していない。最新案のPC Tapや仮想デバイスの取得負荷・遅延を含む試験ではない。

- `system_profiler SPAudioDataType SPSoftwareDataType`
- `AudioObjectGetPropertyData`等による読み取り専用の一時的なCore Audio列挙（機器名、rate、buffer、チャンネル名、active subdevices）
- Fireface USB Settingsのアクセシビリティ表示
- LadioCastのインストール情報とprocess一覧。設定plistの一部は参考閲覧したが、現在のブリッジ設定や性能の根拠には採用していない。

一時診断コードはアプリ実装には含めていない。観測はその時点のスナップショットであり、次回実装開始時に再取得する。
