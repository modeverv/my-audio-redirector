# アーキテクチャ案

更新日: 2026-09-28 / 状態: 設計案。SRC・ミックス演算はオフライン計測済み。PC Tap、音声エンジン、GUI、実機の経路・性能は未検証。

## 1. 結論と確定した制約

**RME物理入力とPC再生出力を個別に取得し、各チャンネルのgainを調整して2mixを作り、Discrete4 Computer Play 1/2へ送る。** PC音声にもRME Loopbackを使わない。

- RME入力とPC出力を設定画面に別グループとして一覧表示する。通常画面はOFF/ONのボタン1個。
- Discrete4内でミックス／FX処理したステレオ音声はUSBで読み、設定で選んだRME出力L/Rへ返す。AESは初期候補で固定しない。
- RMEとDiscrete4を1つのAggregateへ結合しない。2台を結合した際の入出力異常が報告されている。
- 最終運用では両機器間のS/PDIF・ADAT・クロック配線を撤去する。両機器のUSB、RMEの選択した出力から最終出力先への接続は維持する。
- 64 samplesを低遅延化の目標として設定画面で調整する。I/Oサイズ、FIFO待ち、実測遅延を別項目にする。[予算](latency-budget.md)
- プログラムの複雑さを不採用の理由にしない。リアルタイム処理・復旧・長時間試験で安定性を確認する。

SwiftUI + Core Audio HAL + C++リアルタイムエンジンを採用し、C ABIで接続する。対象はこのMacのApple Silicon / macOS 26系。

PC音声の取得は、既存の出力device/streamを対象にする多チャンネルCore Audio Tapを第一検証候補とする。ユーザーの確定事項は「Loopbackなしの個別チャンネルmix」であり、Tapの実機成立はまだ確認していない。PCの出力先を新しい仮想デバイスへ変更する方式も比較可能だが、出力先の変更を前提に確定しない。[PC音声取得の詳細](computer-audio-capture.md)

## 2. 音声経路

```text
RME物理入力 1..N ─ HAL callback ─ 各gain/pan ─ stereo mix R ─ FIFO R ─ ASRC R ─┐
                                                                              │
PC出力 1..M ─ device/stream Tap ─ 各gain/pan ─ stereo mix P ─ FIFO P ─ ASRC P ─┤
                                                                              ▼
                                                           D4 callback: 合算・master
                                                                              │
                                                         Discrete4 Computer Play 1/2
                                                                              │
                                                           Discrete4 ミックス／FX
                                                                              │
                                                           DAW Record Loopback
                                                                              │
RME選択出力L/R ← RME callback: ASRC D ← FIFO D ← D4 callback: 処理後USB入力
```

RMEの物理入力とPC音声は別の入力名前空間。例えば各20chを正しく取得できれば計40chを表示できるが、RMEが40録音chへ増えるわけではない。PC側の実チャンネル数と順序はstream列挙・信号試験で確定し、20chを固定値にしない。

RMEのLoopback用Hardware Outペアを予約しない。PC TapはTotalMixのHardware Outサブミックスのキャプチャではなく、選択した出力streamへ向かうprocess音声の取得。RMEのEQ/Dynamicsやhardware faderを含む最終出力と同一視しない。

自アプリがRMEへ返す音は、出力チャンネルにかかわらずPC Tapの対象processから除外する。復路に選んだチャンネル番号を隠すだけでは自己音声除外の代わりにならない。他アプリ経由の録音・再生による循環は外部経路として別途検証する。

復路の設定はRMEの **host playback出力L/R** を選ぶ。初期候補は今回列挙したAES 11/12だが、現在の出力一覧から任意の有効な2チャンネルを選択できる。TotalMixのSoftware Playbackから物理Hardware Outへのルーティングは別設定であり、host出力を選ぶだけで物理端子への経路が自動設定されたとは扱わない。

既存5.1ch/DTMなどの出力先がAggregateの場合、物理RMEのTapで同じ音が取れるかは未確認。実際の出力device UID・stream・チャンネル対応を確認し、同じ音を複数Tapから二重取得しない。

## 3. 取得方式の選定

| 方式 | 判断 |
| --- | --- |
| RMEの物理HAL input | 採用。RME Loopbackで置換されていない入力を直接取得 |
| device/stream指定・non-mixdown Core Audio Tap | PC音声の第一検証候補。既存の多チャンネル再生先を保てる可能性がある |
| global stereo / process stereo mixdown Tap | PC全チャンネルの個別gain要件には使わない。先に潰した成分は分離できない |
| Tap受信用private Aggregate | PC capture backendに限定して検証。RMEとDiscrete4を結合しない。Tap-only成立・clock anchorの要否はPoCで確定 |
| RME＋Discrete4のpublic/private Aggregate | 不採用。privateという公開範囲の違いで機器結合の不調が解消するとは扱わない |
| 仮想多チャンネルAudioServerPlugIn | Tapが要件を満たさない場合の代案。PCの出力先変更、driver配布、独立した時間軸の扱いを伴う |
| TotalMix premix / Playback専用Loopback | 旧案・比較実験として記録。現行の製品経路と自動fallbackには含めない |
| FIFOのみ／固定比率SRCのみ | 独立クロック差が蓄積するため不採用 |

Tap受信にはAppleのAggregate機構を使うので、「Aggregateを一切作成しない」とは表現しない。Tap-onlyで動くか、単一のclock anchorが必要か、実buffer・ドリフト補正は実機で確定する。2台の物理機器を束ねる構成へ黙って変更しない。

PC Tapの初期評価は元の出力を残すUnmuted。元音声とD4処理後のRME選択出力が二重に聴こえる経路を確認する。MutedWhenTappedは既存出力を変更するため、影響範囲・開始停止・クラッシュ時を確認したうえで明示的な動作設定として検討する。OSのdefault outputを自動変更しない。

## 4. クロック・FIFO・ASRC

### 基準構成

RMEとDiscrete4は独立したInternal 48 kHzを基本にする。PC Tapのformat・rate・timestampは取得時に検証する。公称48 kHzが同じでも、同一callbackや同一時間軸とは仮定しない。

| 経路 | producer | consumerとASRCの所有者 |
| --- | --- | --- |
| FIFO R: RME物理入力mix → D4 | RME callback | D4 callback / ASRC R |
| FIFO P: PC音声mix → D4 | Tap callback | D4 callback / ASRC P |
| FIFO D: D4処理後 → RME選択出力L/R | D4 callback | RME callback / ASRC D |

基準は3つのcallback経路、3本のstereo SPSC FIFO、3つのstereo ASRC。複数Tapが別の時間軸で届く場合は、capture群ごとのFIFO/ASRCを必要に応じて増やす。チャンネルごとにASRCやthreadを作る構成にはしない。

同一capture群内では各gain/panを適用してstereoへ合算し、そのstereoを変換する。D4側で2つのstereoを同じ出力時間軸へ合わせ、最後に加算する。PCをいったんRMEへ変換してから再びD4へ変換する不要な直列経路を作らない。

RMEとTapが同じ物理クロックを参照していても、callbackの到着・sampleTime起点・遅延は同一とは限らない。クロック関係とtimestampを実証できた場合に限り、同一時間軸の入力を先にまとめてASRC数を減らす最適化を検討する。

### レート追従と所有権

- 各FIFOはsingle producer / single consumer。事前確保したFloat32 stereoを単調増加counterとacquire/releaseで共有する。producerがconsumerのread pointerを動かさない。
- 比率を `q = source frames / destination frames` と定義する。占有量が増えればqを上げ、減れば下げる。libsamplerateのoutput/input比率には `1/q` を渡す。
- 有効なsampleTime/hostTimeから実レート比を推定する。CPU上のcallback到着時刻を音声クロックに代用しない。
- レート推定は非RT側、PI積分・比率の滑らかな適用・SRC状態はconsumer callbackが所有する。UIや推定の更新を待たない。
- FIFO量はconsumerの一定の位相で観測し、callbackごとの鋸歯状変動へ過剰追従しない。補正範囲・slew・wind-up防止はsimulationで検証する。
- RME↔D4の基準比率は逆数関係を検証する。PC↔D4は別途推定し、同じ比率を無条件には流用しない。
- timestamp不連続・無効flags・世代違いを推定から除く。推定不能では検証済みの占有量制御へ限定するか開始を拒否し、固定比率へ黙って退化しない。
- 44.1/48 kHzの公称形式差を微小なppm補正で吸収しない。初期運用は対応を確認した48 kHzに限定する。

### 待ち量と開始

I/O64 framesと各FIFO目標64 source framesを初期評価値とする。32/64/128の組合せを比較し、要求値・実値を表示する。Tapの最小bufferや内部待ちは未測定で、同じ値を指定できる保証はない。

容量、目標占有量、SRC内部先読みを分ける。容量全体を埋めてから開始しない。FIFOを2周期分へ固定せず、設定した目標を無断で増やさない。

各入力producerを先に動かし、出力は無音でprimeする。RME・PC・D4戻りの必要経路が成立してからfade inしONにする。互いの出力開始待ちでproducerを止めるdeadlockを作らない。通常の無音やPCアプリの未再生とcapture停止は区別する。

SRCへ大量prefetchせず、供給量をbounded scratchに限定する。input_frames_usedは取り込んだ量として処理し、出力済み量と混同しない。出力不足はゼロ補完し欠落を数える。処理回数には上限を設ける。

### SRC

libsamplerate 0.2.2のSINC_FASTESTを低遅延候補、SINC_MEDIUMを音質比較とする。単体測定の先読みは等速付近で約20 / 47 frames。3つのSRCが全て直列に並ぶ意味ではなく、各入力→D4→RMEの経路では基本的に往路1回・復路1回となる。

通常の比率変更はsrc_processへ渡し、平滑化を飛ばすsrc_set_ratioを毎回呼ばない。version固定、callback内allocation/lock、音質、処理時間を検証する。線形補間やApple Varispeedは比較候補であり、音質・安定性を未検証のまま置換しない。[測定](latency-budget.md)

## 5. モジュール構成

```text
SwiftUI: MainWindow / SettingsWindow / ChannelStripList
                      │
EngineController（直列制御queue）
  ├ DeviceRegistry / StreamChannelMap / DeviceMonitor
  ├ PCCaptureBackend（Tap lifecycle / private aggregate / self exclusion）
  ├ PhysicalDeviceBackend（RME IOProc / D4 IOProc）
  ├ RouteResolver → 検証済みRenderPlan
  ├ ClockEstimator / SettingsStore / Diagnostics
                      │ C ABI・事前確保データ
C++ RealtimeEngine
  ├ RME callback: physical mix → FIFO R / FIFO D → ASRC D → 選択出力L/R
  ├ PC callback : channel mix → FIFO P
  ├ D4 callback : ASRC R + ASRC P → sum → Computer1/2 / input → FIFO D
  └ consumer所有のSRC/PI、producer所有の入力gain ramp、固定サイズ統計
```

Tap方式では単一アプリプロセスを基本とする。音声処理をUI queueや専用DSP workerへ転送しない。HALのcallbackを使う。Quitはcaptureと物理I/Oを停止してから終了。起動時OFF。

## 6. リアルタイム処理

- 入力は実streamの多channel Float32、内部経路はstereo Float32。interleaved/non-interleaved、複数AudioBuffer、NULL stream、異なるcallback長を扱う。
- channel数はRME入力数＋検証済みPC出力数。旧案の「RMEの20録音枠が全sourceの上限」は撤回する。最終的な上限と必要領域はOFF中に確定・事前確保する。
- gain、mute、左右配分を各sourceに持ち、stereo linkを提供する。初期gainはmuteとし、意図しない全入力の加算を避ける。
- route構造の変更はOFF中のみ。動作中のgain/muteはlock-freeパラメータからblock境界で取り込み、callback側でrampする。
- 物理入力、PC再生、別アプリで再生した同じ音の重複を区別する。共通クロックでもADC・OS・DSPの経路遅延が同じとは限らない。
- 合算前後のpeakとclipを診断する。自動正規化・先読みlimiterは初期版に含めない。非有限値処理・最終clampは回数を記録する。
- 自アプリのoutput bufferを毎回ゼロ初期化し、D4 Computer1/2とRMEで選択した復路L/Rだけへ書く。Tap用Aggregateの出力には音声を送らない。他アプリの再生やTotalMix内部の出力を無音化する意味ではない。
- callback内でheap確保、mutex、ファイルI/O、ログ整形、Swift/Objective-Cオブジェクト操作、Actor呼出、HAL再設定を行わない。
- UIへのmeter提供は5〜10 Hz。固定領域またはbounded queueを使い、通知が詰まっても音声を待たせない。

## 7. GUI

メイン画面は `[ OFF / ON ]` の1ボタン。設定はmacOSメニュー「設定…」と⌘,で開く。開始・prime中はOFF表示で一時無効化、成立後ON。異常理由はsheetと設定画面へ表示する。

設定画面のミックスは次のように、RME入力とPC出力を並べる。

```text
RME INPUT             Gain     Mute    Pan / stereo link    Peak
  Mic/Line 1          -∞ dB     ON             ...            ...
  Mic/Line 2          -∞ dB     ON             ...            ...
  ... 実機の全入力
PC OUTPUT（取得元device名）
  Out 1               -∞ dB     ON             ...            ...
  Out 2               -∞ dB     ON             ...            ...
  ... 検証済みstreamの全channel
2MIX → Discrete4 Computer Play 1/2    Master / Peak / Clip
RETURN → RME [出力L] [出力R]          Gain / Mute / Peak
```

PC側はアプリ名一覧ではなく、再生先の出力channel一覧。同じOut1/2へ複数アプリが出す音はそのchannel内で合算される。プロセス別フェーダーは今回の要件に含めない。

| 設定ページ | 内容 |
| --- | --- |
| 入出力 | RME・D4のUID、PC取得device/streamとmapping、D4復路録音ペア、復路RME出力L/R（AESは初期候補）、取得権限・自己音声除外の状態 |
| ミックス | 上記channel strips、stereo link、master、復路gain、peak/clip |
| 動作 | 48 kHz、I/O要求16/32/64/128/256/512、RME/PC capture/D4の実値、各FIFO目標、SRC品質 |
| 診断 | 各経路のrate、timestamp、callback、FIFO量、比率/ppm、欠落、capture状態、ログ書出し |

samplesとms、要求値と実値、未検証と実測を分ける。stereo64 samplesは各channel64 samples＝64 frames。実測総遅延はI/O設定から捏造しない。

復路RME出力はチャンネル番号とラベルを併記して選択する。通常はstereoペア選択、詳細ではL/R個別指定を可能にする。同一チャンネルへのL/R重複や存在しない番号は拒否する。変更はOFF中に適用し、停止・旧buffer破棄・経路再検証後、次のONで新しい出力へ送る。AES以外へ変更してもDiscrete4への往路はComputer Play 1/2のまま。

## 8. 状態と復旧

内部状態はOff / Starting / Priming / Running / Stopping / Unavailable / Fault。要求状態と実状態を分離し、Runningは必要なcaptureと転送が成立した状態を表す。スピーカーの実音の保証とは分ける。

OFFはfade out→全経路停止。部分的な開始失敗時も開始済み資源を回収する。切断・callback停止時はfade完了を待たずに停止へ進む。開始・primeにはtimeoutを設ける。

RME/D4切断、Tap権限取消し、capture消失、rate/stream変更、timestamp断絶、FIFO fault、連続overloadでは出力を無音化し全経路を停止する。一般のPC再生アプリ終了や無音を、Tap消失と混同しない。

全callbackの終了を確認してからFIFO/SRC/PIをreset・解放し、その後Tap用AggregateとTapを依存順に破棄する。古いlistenerとtimestampを世代で捨てる。異常終了後に残った自己所有資源だけを識別して回収し、ユーザーの既存Aggregateを消さない。

同UIDの再発見・再検証までを自動化し、音声再開はON操作とする。RME Loopback、機器間ケーブル、別出力deviceへ黙って切り替えない。

OFFが他アプリの元音声や機器内部直結まで消音するわけではない。管理対象のD4往路・RME復路は止まること、元音声の扱いが設定どおりであることを試験する。

## 9. 設定・権限・共有機器

Application Supportへschema version付きで原子的に保存する。source種別、device UID、stream識別情報、1-based channelとラベル、mapping確認世代、gain/link、buffer要求値、FIFO目標を保存する。AudioObjectIDやprocess PIDは永続IDにしない。

復路設定にもRMEのdevice UID、出力L/Rの1-based番号とラベルを保存する。再起動やrate変更で出力構成が変わり、保存先を照合できなければOFFのまま説明する。AESやAnalog 1/2へ自動で戻さない。

同名device・channel数変更で近似再接続しない。PC出力先変更を検出したら再検証する。buffer/rateは共有設定なので、選択した変更だけを行い前後を読み、他アプリが変えた値を無条件に復元しない。

RME入力用の録音許可・NSMicrophoneUsageDescriptionに加え、Tap用のNSAudioCaptureUsageDescriptionとシステム音声取得権限を扱う。拒否・取消しはOFFで説明する。配布形態に応じたentitlement、安定したbundle identifierと署名を整える。

ログへ通常の音声内容を保存しない。callback時間、FIFO量、SRC比率、clock推定、overload、clip、欠落、停止理由を非RT側で集計・保存する。観測できないdriver内dropoutを0とは報告しない。
