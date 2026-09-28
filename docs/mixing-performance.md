# 個別ミックスの性能とPC音声取得経路

更新日: 2026-09-28。現行案は **PC出力のdevice/stream tapとRME物理入力を別々に取得し、アプリで個別gainを調整する方式**。PC音声の取得にRME Loopbackを使わない。複雑さではなく、取得できる信号、遅延、CPU、実機での安定性で評価する。

## 1. 現時点の判断

20 mono入力のgain/pan/rampを含むstereo合算は、このMacのオフライン測定で約1.054 μs／64 frames。混合済みstereoのgain/copyとの差は約1.007 μsだった。加算演算の負荷を理由に個別gainを諦める必要は薄い。

ただしこの測定は、従来の「RME物理入力とLoopbackを同じcallbackで得る」案を検討したときの演算単体データ。**新しいPC tapの取得待ち、追加callback、最大20 PC channels＋20 RME物理channels、3系統のASRCを測ったものではない。** 数値は演算コストの参考として保存し、新経路の総遅延・安定性の証明にしない。

## 2. 現行の取得・ミックス構成

PC音声は、現在のPC出力デバイスを指定する非mixdownのdevice/stream tapから取得する案を検証する。設定画面はプロセス単位ではなく、PC出力の論理channelとRME物理入力を別々のstripとして表示する。PCの1/2だけにstereo mixdownすると、3/4以降の独立gainという要件を満たせない。

```text
PC出力device/stream tap（isMixdown=false）
  → tap専用private aggregateのcapture callback
  → PC各channelのgain/pan・stereo合算 → FIFO_P ── SRC_P ─┐
                                                       │
RME物理I/O callback                                     ├→ D4 callbackで最終加算
  → RME各物理入力のgain/pan・stereo合算 → FIFO_R ─ SRC_R ─┘   → Computer 1/2

D4 callbackの処理後ホスト入力 → FIFO_D
  → RME callbackのSRC_D → RME選択出力
```

単一のtap capture群を前提とする基準設計は、**最低3つのcallback、stereo FIFO×3、stereo ASRC×3**。`SRC_P`と`SRC_R`はD4の出力callbackが消費し、`SRC_D`はRMEの出力callbackが消費する。3個のSRCを1本の音声が直列に通るわけではなく、PC由来の信号はP→D、RME由来の信号はR→Dという各2段を通る。

private aggregateはtapを読み出すcapture用コンテナだけに使用する。RMEとD4の物理デバイスを結合するaggregateは作らず、物理I/Oはそれぞれ独立して開く。tap取得にaggregateを使う事実は隠さない。複数の出力streamから独立したtap/callbackを取得する場合はcallback数が増え、timestampの整列やFIFO/SRCの数を再検討する。3系統という数を無条件に固定しない。[Appleのtap取得例](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

PC tapがRME出力を対象としていても、tap callbackとRME入力callbackが同じ周期・sample timeで届くとは決めつけない。初期実装では別の時系列として扱う。共通クロックとしてSRCを省く最適化は、両者のtimestamp対応、長時間のrate差、開始・再開時の位置関係を検証した後に限定する。

## 3. このMacで保存した演算単体測定

Apple M4 Max / arm64、clang -O3、Float32、合成入力、gain rampあり。音声機器は開いていない。[方法・再現手順](measurements/2026-09-28-mix/README.md)、[生データ](measurements/2026-09-28-mix/results.json)、[測定ソース](measurements/2026-09-28-mix/mix_bench.c)。付属READMEの同一RME callbackに関する考察は旧案の前提であり、現行tap経路は本資料の構成を優先する。

| 1 blockの処理 | 32 frames平均 | 64 frames平均 |
| --- | ---: | ---: |
| 混合済みstereoのgain/copy | 0.035 μs | 0.047 μs |
| 2 mono → stereo | 0.105 μs | 0.128 μs |
| 8 mono → stereo | 0.230 μs | 0.436 μs |
| 16 mono → stereo | 0.380 μs | 0.848 μs |
| 20 mono → stereo | 0.471 μs | 1.054 μs |
| interleaved20chから抽出＋mix | 0.472 μs | 1.057 μs |

64-frame／48 kHzの周期は1,333 μs。20 monoとpremixの差約1.007 μs／blockは、750 callbacks/秒なら1コア時間の約0.076%相当。これは1つの加算処理の差から計算した目安で、tapとRMEの両方を処理する現行アプリ全体のCPU使用率ではない。

20 monoの左右係数・乗算加算・ramp更新を数えると、概算5.76 MFLOP/s。入力読出し量はFloat32×20ch×48 kHzで3.84 MB/s。後者はメモリ上の入力データ量であり、USBやtap取得の実転送量ではない。20＋20 channelsの実取得・合算性能は別途測る。

測定は4,096回warmup、256 calls×200 batches。表はバッチを1回分へ換算した平均。付属データのp99もバッチ平均のp99であり、単発RT callbackのp99・最大値ではない。小さいcache-hot配列を使い、Core Audio、FIFO、ASRC、meter集計、UIを含まない。

noinline、compiler barrier、変化するgain、出力checksumにより処理の消去を防止。倍精度参照との最大絶対誤差は5×10⁻⁸未満だった。入力ごとのgain数が違うので、全ケースが同一のDSP意味を持つわけではない。

## 4. CPU処理時間と経路の待ち時間

既に届いている1つのblockをgainで乗算・加算する演算自体は、先読みや追加blockを必要としない。gain rampも振幅の平滑化であり、音声を保持する処理ではない。

一方、現行案ではPC tapとRME入力は別callbackから来る。**旧案の「全入力を同じcallbackで混ぜるので経路待ちも同じ」という説明は適用しない。** PC側には未測定のtap取得待ち、private aggregateの周期・位相、FIFO_P・SRC_Pがあり、RME側には物理入力取得とFIFO_R・SRC_Rがある。D4で最終加算するときは宛先のsample timeに整列させ、RT callbackで相手の到着をブロックして待たない。

SRCの20／47-frame先読みという単体測定は各SRC段の参考になるが、PC取得まで含めた往路遅延ではない。現行はSRCがシステム全体で3個になり、D4出力callbackでは2個を処理する。既存の1個単体CPU値を、3個同時運転のdeadline実測値に置き換えない。[遅延予算](latency-budget.md)

I/O64は引き続き試験目標。tapが64-frame callbackを受け付けるか、要求値と実callback長が一致するかも別々に確認する。48 kHz表示や同じI/O指定値だけを、同一クロック・同一位相の根拠にしない。

## 5. 安定性の確認

- PC tap内とRME物理入力内では、それぞれ事前確保したstereo領域へ各channelを加算する。channelごとのthreadやFIFOは作らない。
- FIFO_P、FIFO_R、FIFO_Dのproducer/consumer、SRC状態、sample timeの所有権を分離する。複数tapを扱う場合は同じFIFOへ無調停で書かない。
- route構造はOFF中に確定。gain/panはcallback境界で取り込み、muteも含めてrampする。
- tapはブリッジ音声を出すengine processを除外し、RME選択出力へ戻した処理済み信号を再取得しない。別helperが出力する構成ならそのprocessも対象。
- tapの対象device/stream、channel format、mute状態、permission、デバイス再接続、rate変更を監視。PC直音とブリッジ音の二重再生を実際の信号で確認する。
- 入力peakと合算後peakを分け、clipの余裕を確保する。先読みlimiterで隠して遅延を増やさない。
- meter表示は5〜10 Hz程度とし、UI更新を音声周期で行わない。RT内のメモリ確保・mutex・ファイルI/O・ログ整形を排除する。
- 最大channel数、全gain操作、設定画面、通常のバックグラウンド負荷で32/64-frame運転を比較する。
- 各callbackの処理時間、3 FIFOの水位、補正比率、underrun/overflow、無音補完、実録音のクリック、PC/RMEそれぞれの経路遅延を記録し、8時間→24時間の試験を行う。

同一音源をPCと物理入力へ並列に送る用途では、取得開始点からの経路差を測る。ASRCでレートが合っても信号の時間位置が自動で一致するわけではない。必要な整列delayは別の待ち量として表示する。

## 6. 論理channelと機器入力枠

deviceUID＋streamを指定するtapは、対象出力streamのformatに一致する。`stream`はchannel番号ではなくstreamのindexである。非mixdown設定、tapの実format、streamの開始channelを照合してPC出力stripへ対応付け、各channelへの個別テスト信号で確認する。複数アプリが同じPC出力channelへ送った音は、そのchannelで混合された信号として扱う。[Apple CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)、[device/stream指定](https://developer.apple.com/documentation/coreaudio/catapdescription/init(processes:deviceuid:stream:))

PC出力streamが20chを保持し、RMEの物理入力20chも取得できれば、設定画面で20＋20の論理sourceを扱う構成を検討できる。**計40chの取得確認はまだ行っていない。** PC側のformat・channel分離、物理側の使用可能入力、同時起動、他アプリとの共存を確認してから有効にする。PC tapのchannelをRMEの20ch録音枠へ押し込める設計ではない。

現行案ではPC取得のためにRME Loopbackの出力ペア・録音slotを予約しない。既存のLoopback設定が有効なら対応入力は依然として置き換わるため、物理入力の取得試験ではその状態を確認する。アプリから無断で機器の共有ルーティングを変更しない。

## 7. TotalMix／Loopback比較の位置付け

旧案の履歴と現行案を比較する。最初の2行は現在の必要slot数ではない。

| 構成 | 往路取得 | Loopbackで置換される録音入力 |
| --- | --- | --- |
| TotalMix premix | 全音源を混ぜた専用1ペア | 2ch |
| RME同一callback内の個別mix | PC Playbackだけの専用1ペア＋物理入力 | 同じ2ch |
| 現行device/stream tap | PC出力tap＋別のRME物理入力 | PC取得のための予約は0ch |

RME出力Loopbackが対応入力slotを置換する制約は旧方式には残る。現行はPC信号をhost側で取得してその依存をなくすが、代わりにtap取得経路を検証する必要がある。[RME Loopback仕様](https://rme-audio.de/downloads/fface_ucx2_e.pdf)

復路のRME出力は設定で選択し、AESは初期候補とする。自アプリが返す音は選択チャンネルにかかわらず往路から除外する。他アプリのPC出力はchannel mappingに従って扱い、復路と同じ番号のPC channelを隠すことを自己音声除外の代わりにはしない。物理入力を読むだけで排他占有する設計ではないが、共有機器のrate/buffer変更や他アプリとの同時利用は共存試験が必要。アプリのgain合算はTotalMixのEQ・Dynamics等を自動で再現しないため、旧方式と音を比較するときはDSP条件を揃える。
