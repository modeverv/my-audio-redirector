# 64 samples目標と遅延予算

更新日: 2026-09-28。現行実装はPC出力の非mixdown device/stream tapとRME物理入力を別々に取得する構成。SRC／mixのオフライン単体計測に加え、Fireface UCX II・Discrete4 USB・PC tapを使った実機I/O試験まで実施した。本書のFIFO／SRC予算、全Muteでの運転確認、信号を用いた遅延測定は、それぞれ異なる証拠として扱う。

## 1. 現時点の判断

**現在の比較基準は48 kHz、I/O64 frames、3系統のFIFO目標64 frames、Fastest。** RME・Discrete4・PC tapの実callback長64を確認し、全42chのGate OFF／ONそれぞれで、設定値を連続更新しながら60秒間の全Mute運転に成功した。両試験ともfault・underrun・overflowは0で、停止後のtap／aggregate解放も確認した。[GUI・Gate・実機I/Oの検証](measurements/2026-09-28-gui-gate/README.md)

これは長時間安定や信号内容、実遅延の証明ではない。別の64／FIFO64試験ではPC underrunが発生し、GUI試用中にはcallback遅着を伴う時刻不連続も記録している。64を無条件に安定する推奨値とは扱わない。機器I/Oとtap captureの要求値・読み戻し・実callback長は、測定ごとに確認する。

ただし **I/O64＝片道または往復全体64 samplesではない**。48 kHzで64 samplesは1.333 msだが、実信号による2回の測定ではPC Tap→D4が約6.9〜7.3 ms、D4戻り→RMEが約6.6〜7.6 msだった。D4のミックスを通した全体は、相関の成立した窓で約14.8〜15.3 ms。HAL timestampで定義した端点の値であり、物理端子全体の外部測定とは異なる。[条件・測定結果・測定後のPC FIFO不足](measurements/2026-09-28-signal-latency/README.md)を、以下の部分予算と区別する。

現行の基準設計は最低3 callback、stereo FIFO×3、stereo ASRC×3。PC tap→D4のP系統、RME物理入力→D4のR系統、D4処理後→設定したRME出力のD系統を分ける。D4 callbackでSRC_PとSRC_Rを実行して最終加算し、RME callbackでSRC_Dを実行する。複数tap streamを独立取得する場合はcallback数や整列処理が増える。

各音源が通るSRCはP→DまたはR→Dの2段であり、3段直列ではない。Mediumなら各経路の先読みだけで約94 samplesになる。Fastestを第一候補に、3 FIFOそれぞれの32/64/128-frame待ち量を実機比較する。PC tapがRME出力を対象としていても、RME物理入力と同一時系列であると未検証のまま扱わない。共通クロックを使う最適化はtimestampと長時間のrate差を検証した後に行う。

## 2. 設定で分ける数値

stereoの64 samplesは、各channel64 samples＝64 framesという意味。左右合計128 scalar samplesという数え方を設定値には使わない。

| 項目 | 設定・表示の仕様 |
| --- | --- |
| I/O buffer | DAWと同様の機器callback単位。初期要求64。16/32/64/128/256/512から、各driverが受け付ける値を選択 |
| 取得系統別I/O | RME、D4、tap captureを別々に確認。要求値、HAL読み戻し、実callback長を表示。tapが機器と同じ64で届くとは仮定しない |
| ブリッジの追加待ち | SRC内部先読みを除くFIFO_P、FIFO_R、FIFO_Dの目標。個別に32/64/128等を調整。初期評価64/系統 |
| SRC品質 | 低遅延Fastestと音質比較Medium。先読みの単体測定値を説明。名前だけで音質・安定性を保証しない |
| 実測遅延 | 測定境界と条件を記録し、samplesとmsで評価する。現行の専用CLIはPC往路・D4内部往復・共通復路が対象で、RME物理入力往路とGUIでの自動実測表示は別途実装が必要。未測定は未測定とする |
| 異常 | underrun、overflow、ゼロ補完、clip、補正比率、停止理由。小さい値が安定したかを判断する材料 |

I/OやFIFOの変更はOFF中に適用する。選択値を無言で増やさない。未対応・SRCの必要入力量不足なら開始前に理由を表示し、値を戻せるようにする。64は短時間の実機成功記録がある比較基準であり、あらゆる負荷での安定性を保証する値ではない。

## 3. このMacでのSRC単体測定

[方法・再現手順](measurements/2026-09-28-src/README.md)、[生データ](measurements/2026-09-28-src/results.json)、[測定ソース](measurements/2026-09-28-src/bench.c)を保存した。

- Apple M4 Max / arm64、公式libsamplerate tag 0.2.2、clang Release / -O3。
- Float32 stereo、EOFを与えない連続ストリーム、比率1.0と±100 ppm。
- 1 frameずつ入力し、出力が実際に生成可能になるまでに必要な未来の入力を測った。
- インパルスの出力配列上の位置は等速で元と同じでも、それを生成できる時刻は遅れる。配列のピーク位置を見てゼロ遅延とは判定しない。

| 品質 | オンライン先読み／1方向 | 48 kHz換算 | 最初の64出力を生成するための入力 |
| --- | ---: | ---: | ---: |
| Fastest | 20 frames | 0.417 ms | 84 frames |
| Medium | 47 frames | 0.979 ms | 111 frames |
| Best | 144 frames | 3.000 ms | 208 frames |

比率1.0の値。±100 ppmではサンプル位相で約1 frame前後し、最初の64出力に必要な入力はFastest83–84、Medium110–111 framesだった。初回64入力から返る出力はFastest44、Medium17 frames。固定64出力を開始時から要求するにはprimeが必要。

この先読みはSRC内部の待ちであり、CPU計算時間ではない。64-inputブロック単位の開始時の丸めも、定常時の実往復遅延とは別に扱う。

| 64-frame stereo処理時間 | p50 | p99 | 観測最大 |
| --- | ---: | ---: | ---: |
| Fastest | 3.333 μs | 3.458 μs | 35.667 μs |
| Medium | 6.083 μs | 6.375 μs | 12.750 μs |

20,000回、3,000回warmup、微小な可変比率、通常のスレッドでの短い測定。I/O、mix、PI制御、UI、負荷変動は含まない。RTの最大実行時間や24時間安定性の保証には使わない。1個のSRCの演算時間であり、現行のD4 callback内の2個同時処理や、システム全体の3個＋mix＋tap取得のdeadlineを測った値ではない。先読み・FIFO・tap取得・driver周期を含む試験が必要。

## 4. 音源経路ごとの暫定予算

Q_P、Q_R、Q_Dは **SRC内部先読みを除く各アプリFIFOの未読frame数の目標**、L_P、L_R、L_Dは各SRCの先読み。現行制御はrender直後の未読量を平滑化してQへ近づけるため、Qは常時確保される最小量ではない。PCアプリによる音声生成からtap取得までの待ちはQ_Pに含まれず、まだ測定していない。private aggregateはtap capture用のみとし、RMEとD4の物理デバイスを結合しない。物理I/Oは独立させる。[tap取得のApple公式例](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

| 音源から選択したRME出力まで | FIFO/SRC部分 | 別途確認する主な待ち |
| --- | --- | --- |
| PC音声 | Q_P＋L_P＋Q_D＋L_D | PC device/stream tap取得、capture callbackの配送・位相、D4出力→FX→処理後ホスト入力、RMEの選択した出力 |
| RME物理入力 | Q_R＋L_R＋Q_D＋L_D | RME入力取得、callback位相、D4出力→FX→処理後ホスト入力、RMEの選択した出力 |

PC信号とRME信号はD4で並列に加算する。片方の音源の遅延へ、もう片方のFIFO/SRCを直列加算しない。必要な音源間の整列delayを設ける場合は別項として表示する。取得時刻、callback受取時刻、出力sample timeの定義を揃えて実測し、プロパティと実測値を重ねて二重計上しない。

以下は選んだ音源の往路と共通復路を同じQ・SRC品質にした場合の計算。全系統が48 kHz付近で動作する条件で、tap取得・driver・USB・DSP・callback位相を除いた部分予算である。異なるrateでは各系統のframesをその系統のrateで秒へ換算する。

| 往路・復路それぞれのQ | SRC | 1系統のQ＋L | 音源往路＋共通復路の合計 |
| --- | --- | ---: | ---: |
| 32 frames | Fastest | 52 frames / 1.083 ms | 104 frames / 2.167 ms |
| 64 frames | Fastest | 84 frames / 1.750 ms | 168 frames / 3.500 ms |
| 32 frames | Medium | 79 frames / 1.646 ms | 158 frames / 3.292 ms |
| 64 frames | Medium | 111 frames / 2.313 ms | 222 frames / 4.625 ms |

これをPC経路の実遅延や予測総遅延として表示しない。tap取得の追加待ちが未測定なので、旧Loopback案の待ち量と同じとは言えない。実FIFO量もcallback位相で揺れ、設定Qが常時その待ち時間になるとは限らない。SRCへのprefetchを含む全pipeline蓄積量をQとして測った場合はLを再加算しない。

従来案の「64-frame I/OならFIFOを2周期＝128 frames」は固定しない。FastestでもQ128＋L20は148 frames／3.083 msになる。3 FIFOを独立評価し、tapの最低必要量が異なる場合も無言で値を増やさず、要求と実測を示す。

もし **FIFO/SRC部分だけの片道追加待ちを64 samples以下** にするなら、FastestでQ≦44、MediumでQ≦17が必要。ただしPC tap取得を含めて64以下にする十分条件ではない。ブロック到着、ジッター余裕、SRCへの必要入力量を満たせるかは実機で決まる。全経路64はFastestの2段だけで40 samplesを使い、残り24 samplesでFIFO、tap取得、全I/O、DSPを賄う必要があるため約束できない。

**現在の比較条件はRME/D4のI/O64、tap captureも64、Q_P＝Q_R＝Q_D＝64、Fastest。** 小さいI/OやFIFOとの比較は個別の運転記録で判断する。表の約2.2〜3.5 msは各音源経路のFIFO/SRC部分に限った予算であり、現行PC tap構成の安定性・総遅延の予測ではない。

## 5. ドライバーの観測

復路のRME出力はAES固定ではない。選択したhost出力とTotalMixから物理端子までの実経路を記録し、変更後の経路で遅延を測る。AES、アナログ等で同じ物理遅延になるとは仮定しない。

以下は**設計時に読み取った過去のsnapshotで、現在値ではない**。その時点ではRME48 kHz、Discrete4のHAL報告44.1 kHz、buffer512 framesだった。当時のユーザー申告48 kHzとの不一致を含む履歴として保存する。後の48 kHz／64-frame実機試験とは異なる状態であり、現在の遅延計算へこの値をそのまま流用しない。

| 機器 | input latency / safety offset | output latency / safety offset |
| --- | ---: | ---: |
| RME | 13 / 24 frames | 18 / 24 frames |
| Discrete4 | 46 / 68 frames | 42 / 57 frames |

これらは物理デバイスについてSDKが定義するプロパティで、stream latencyとPC tap／capture aggregateの遅延はこの表に含めていない。PC tapがRME出力を対象としていても、RME物理出力latencyをそのままtap取得遅延に使わない。rate・bufferを変えた後も同じとは仮定せず、単純合計を実往復遅延にしない。全経路64 samplesと設定64は明確に分ける必要がある。

## 6. my-lan-audio2で確認できたこと

隣接repoは読み取りのみ。MCP graphで実装を調べ、ドキュメントと保存ログを照合した。

- [audio.c:109](../../my-lan-audio2/apps/receiver-macos/native/audio.c#L109)でCore Audioのbuffer frame sizeを設定し、126行で読み戻す。32は実機I/Oサイズである。
- [GUI](../../my-lan-audio2/apps/receiver-gui/main.swift#L142)もI/O framesと受信バッファmsを別に持つ。この設定の分離を踏襲する。
- [receiver-core](../../my-lan-audio2/crates/receiver-core/src/lib.rs#L371)は線形補間ASRC。レート推定は10秒回帰、平滑化、±1000 ppm等を持つ。今回のSincフィルター・方向別FIFO制御とは違う。
- [macOS receiver資料](../../my-lan-audio2/docs/macos-receiver.md)には16-frame callback処理最大0.020167 msの試験もある。小さいI/OをこのMacで処理できる根拠になる。

32-frameの保存ログ（2026-09-12）では次を確認した。

| 条件・指標 | 保存値 |
| --- | --- |
| ログ | receiver-1789202959-F67C90BD.jsonl（Library/Logs/LAN-Audio-Receiver） |
| I/O / 受信目標 | 32 frames / 10 ms |
| 期間・packet | 21.3205秒 / 8,440 |
| missing / underrun / late / callback discontinuity | 全て0 |
| callback処理時間 | p99 0.005 ms、最大0.029375 ms |
| receive→render | 平均15.2983 ms、最大20.9444 ms |
| 物理片道遅延 | 未測定（null） |

32-frame I/Oの余裕は確認できるが、これは10 ms受信バッファを持つ約21秒の保存測定である。現在のユーザー申告の安定動作を否定するものではなく、長時間32や物理遅延32 samplesを証明するデータでもない。

ネットワーク受信を除けることは今回の利点。一方でPC tap／capture aggregate、独立したRME/D4 I/O、3系統のSinc ASRC、FX後録音という追加条件がある。再利用するのはbuffer設定・読み戻し、事前確保、telemetry、レート推定の考え方。ネットワーク用の大きな待ち量やsample skipの復旧方針はそのまま移植しない。

## 7. 個別mix測定と旧TotalMix比較

現行案はPC tapとRME物理入力を別々に個別mixする。各blockの加算演算自体は先読みを要しないが、別callbackから来るPC音声の取得待ちを省略できるという意味ではない。旧案の「同じRME callback内なので経路待ちは同じ」という前提は現行案へ移さない。[演算測定と取得経路](mixing-performance.md)

TotalMix前段mix→専用Hardware Out Loopback→アプリという構成は旧案の比較履歴として残す。現行のPC取得用にLoopbackの出力ペアや録音slotを予約しない。RMEの既存Loopback設定が有効なら物理入力の対応slotはなお置き換わるため、設定状態を別途確認する。

復路のRME出力は設定可能で、AESは初期候補。PC tapにはブリッジengineの出力processを含めず、選んだチャンネルにかかわらず復路音声を再度往路へ入れる循環を防ぐ。device/streamの全channelが取得できること、除外が再起動後も維持されること、tapのmuteで必要な音が消えたり二重再生されたりしないことは実信号で検証する。[ルーティング](routing-and-observations.md)

## 8. 信号を用いた遅延測定

専用CLI `--measure-latency CONFIG --output CAPTURE.json --seconds 1...8` は、保存設定の音声経路を動かし、PC tap入力1/2、D4 Computer出力1/2、選択したD4処理後USB入力、選択したRME出力の4境界を記録する。全Mute試験とは別の診断である。記録領域はI/O開始前に確保し、primed／running確認から2秒待って収録を開始する。収録を停止fade前に終了し、音声I/Oの停止・解放確認後にJSONへ書き出す。設定ファイルは書き換えない。

入力はGate前のraw PCM、出力は実際のHAL出力bufferへコピーしたPCMを保存する。各blockの先頭sampleTime／hostTime／frame数を用い、独立機器のsampleTimeの絶対値を直接引かず、対応した信号位置を共通hostTime上で比較する。ASRCによる微小な伸縮、Gate・FXによる波形変化、左右チャンネルと極性を考慮し、無音や弱い相関から遅延を確定しない。fault・不足・超過・非有限値・clipとtimestamp連続性を確認する。収録成功と相関による測定成立も別に判定する。

この方法で得るのはHAL timestampで定義した境界間の信号遅延である。PCアプリの音声生成からtap取得前の待ち、RMEのHAL出力からTotalMix・物理端子・DAC・スピーカーまでの待ちは含めて測れない。D4出力→処理後USB入力の区間には、その経路を実際に通ったUSB／DSP／FXの遅延が含まれるため、同じ区間の推測値を重ねて足さない。RME物理入力往路は今回の4境界に含まれず、別収録が必要。結果・信号条件・解析上の限界は[信号遅延の測定記録](measurements/2026-09-28-signal-latency/README.md)へ保存する。
