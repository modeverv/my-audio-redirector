# 実機・ルーティング・未確定事項

確認日: 2026-09-28。ユーザー申告、読み取り観測、提案を区別する。

## 1. ユーザーが確認した要件・現在の構成

- Discrete4へは **Computer Play 1/2への入力が必須**。S/PDIF入力への置き換えは採用しない。
- Discrete4から戻すのは、機器内でミックス／エフェクト処理した後のステレオ音声。
- 接続の申告: `RME S/PDIF → Discrete4 S/PDIF`、`Discrete4 master out → RME ADAT 5/6`。
- 現状はDiscrete4がADAT経由でRMEのクロックに追従し48 kHz動作。症状の具体化: **RMEとDiscrete4をAggregate Deviceで連結すると、音声入出力がおかしくなる**。単独の外部LOCK不良とは断定しない。
- 最終的には **RMEとDiscrete4間のS/PDIF・ADAT・同期ケーブルを使わず、全てソフトウェアで接続する**。両機器とMacのUSB、およびRMEから最終出力先への接続は残る。復路のRME出力チャンネルは設定で変更可能にし、当初のAES指定は初期候補とする。
- メイン画面はOFF/ONのみ。設定とミックス操作は設定画面へ集約する。
- 64 samples程度を目標に、設定画面で小バッファを調整したい。my-lan-audio2で32 samples程度の安定動作実績があるとの申告。[ソース・保存ログの確認と遅延予算](latency-budget.md)を参照。
- 最新要件では **RMEのLoopbackを使わない**。RMEの物理入力とPCの出力チャンネルを設定画面に並べ、それぞれの音量をアプリで調整してステレオへ混合する。
- PC音声は、既存出力デバイスのチャンネルを維持できるCore Audioのdevice/stream Tapを第一評価候補とする。既存の再生先を維持するか、専用の仮想出力デバイスへ変更してよいかは未確定。変更を前提にしない。
- RMEとDiscrete4をまとめるAggregate Deviceは使わない。Tap取得のためのprivate Aggregateは、両機器を結合しないキャプチャ用コンテナに用途を限定する。Tapだけでの稼働可否と時刻基準の選択は実機検証で決める。
- プログラムの複雑さを理由に個別ミックスを断念せず、低遅延・安定動作を目指す。過去のTotalMix 2ch転送との演算比較は参考測定として残すが、RME Loopbackを使うモードを新要件の代替にはしない。

ADAT 5/6は光ケーブル内の論理チャンネル。クロック用RME→Discrete4 ADATと、音声戻しDiscrete4→RME ADATは方向が違う。これらは移行前の記録・比較用であり、新アプリの最終経路ではない。現在のS/PDIF線の用途も確認し、必要な音声はソフト側の経路で代替する。

## 2. 今回の読み取り観測

`system_profiler`、Core Audioのプロパティ取得のみを行う一時的なSwift診断、RME Settingsの画面を使用した。音声I/O開始、テスト信号の再生、設定値の書き込みはしていない。

| 項目 | 観測値 |
| --- | --- |
| OS | macOS 26.7 / build 25G229 |
| RME | Fireface UCX II、USB、20 input / 20 output、HALのnominal rate 48,000 Hz |
| Discrete4 | `Discrete4 USB`、16 input / 16 output、HALのnominal rate **44,100 Hz** |
| RME Settings | Driver v4.27、Firmware v43、Clock Source Internal、48,000 Hz、Optical Out ADAT |
| HAL buffer frames | RME・Discrete4ともに読み取り時512 frames |
| HAL buffer range | RME 15–3072、Discrete4 14–3072 frames。範囲内の任意値が実用可能という意味ではない。 |
| 既存DTM | Active subdevicesはRME + BlackHole、22 input / 22 output、48 kHz |
| 既存5.1ch | Active subdeviceはRME、20 input / 20 output、48 kHz。通常のdefault output |
| システム音のdefault output | BlackHole 2ch。通常のdefault outputとは別 |
| LadioCast | インストール済み。今回のprocess一覧には起動中のプロセスなし。現行ブリッジの比較測定は未実施 |

**Discrete4の48 kHz動作というユーザー申告と、HALの44.1 kHz報告が食い違っている。** これだけで実クロックが44.1 kHz、ユーザー設定が誤り、または不安定さの原因がレート不一致とは断定しない。ベンダーパネル・本体のclock/lock/rate、HAL nominal/actual rate、実stream formatを同時に読む調査が必要。

RME SettingsにはADAT 48 kHz / Syncの表示も読み取れた。ただしこれはRME側で受けているADAT入力の状態であり、Discrete4の外部クロック追従が継続して正常という証拠ではない。

512 framesは48 kHzなら1周期10.67 ms。これは今回の読み取り時点の共有機器プロパティで、LadioCastが使用していた値や実際の往復遅延を示さない。

## 3. チャンネル対応

Core Audioからの今回の実列挙。番号は各物理デバイス内で1始まり。

| 機器 | Host input | Host output |
| --- | --- | --- |
| RME 1–8 | Mic/Line 1/2、Inst/Line 3/4、Analog 5–8 | Analog 1–6、Phones 7/8 |
| RME 9/10 | S/PDIF L/R | S/PDIF L/R |
| RME 11/12 | AES L/R | AES L/R |
| RME 13–20 | ADAT 1–8 | ADAT 1–8 |
| **RME 17/18** | **ADAT 5/6: 移行前の復路** | ADAT 5/6 |
| Discrete4 1–16 | ドライバーのチャンネル名が空。DAW Record側割当を実機確認 | ドライバーのチャンネル名が空。公式資料上はComputer Play 1–16 |

RMEのチャンネル名がAnalogであっても、既存設定でその入力ペアにLoopbackが有効ならホストが受け取る中身は物理入力ではなく出力サブミックスに変わる。新アプリの物理入力として使うチャンネルは、Loopbackによる置換がないことを確認する。名前の列挙だけで信号の由来は判定できない。

## 4. RME物理入力とPC出力を別々に取り出す

### RME物理入力

RMEを物理デバイスとしてHALで開き、録音入力を直接読む。PC音声取得のためのHardware Outペア予約や、録音入力のLoopback置換は行わない。機器内の入力gainや録音向けDSP設定の影響は別途確認する。

### PC出力の第一評価候補: device/stream Tap

Appleの`CATapDescription`には、出力device UIDとstream indexを指定するTapがある。`initExcludingProcesses:andDeviceUID:withStream:`は指定streamへ向かうprocess音声を取り出し、Tap形式は対象streamの形式と一致すると説明されている。global stereo Tapと区別し、**non-mixdownのdevice/stream Tapで各出力チャンネルを維持できるか**を検証する。[Apple Tap仕様](references.md#apple)

このTapで取得するのは機器へ向かうprocess出力であり、TotalMixのHardware Outサブミックスではない。同じ出力チャンネルへ送られた複数processは合成され得るため、「PC出力チャンネルごとのフェーダー」と「アプリごとのフェーダー」も区別する。後者は今回の必須機能にしない。

実装前の検証手順:

1. 音源アプリごとの実際の出力device UIDと、出力stream一覧・形式・チャンネル数・開始チャンネルを取得する。Tapのstream indexをAN1/2等のチャンネル番号と取り違えない。
2. 対象device/streamにnon-mixdown Tapを作り、自アプリのprocessを明示的に除外する。除外対象は起動時に解決し、録音したDiscrete4復路を再びPC音声として取り込まない。
3. `kAudioTapPropertyFormat`とキャプチャ側の実`AudioBufferList`を確認する。20chが見えることやステレオペアの順序を、機器の公称チャンネル数だけから決めない。
4. PC出力の各チャンネルへ区別できる信号を送り、取得チャンネルとの対応を一つずつ確認する。downmix、複製、無音チャンネル、チャンネル入替を検出する。
5. `5.1ch`、`DTM`、物理RME直指定、BlackHoleなど、実際に使用する出力先ごとに同じ確認を行う。物理RMEを指定したTapが、そのRMEを内包するAggregate宛ての音声まで捕捉するとは仮定しない。
6. device/stream構成が変化した場合は再解決し、確認していない番号へ自動的に置き換えない。同じ音を物理RME向けTapとAggregate向けTapで二重取得しない。

通常のdefault outputとシステム音の出力先は今回の観測では異なる。どちらをPC音声の対象にするかも設定に含める。複数の出力先を同時に取得する場合は、その分のTap・形式・時刻・バッファを管理する。

### Tapのキャプチャ用コンテナと再生への影響

Appleの公式経路は、TapをHAL Aggregate Deviceの入力として追加して取得する。したがってTap案を「Aggregate APIを一切使わない」とは説明しない。使う場合はprivateなキャプチャ専用コンテナとし、**RMEとDiscrete4を両方subdeviceとして結合しない**。

Tapだけでコンテナを動かせるか、稼働に時刻基準となるデバイスが必要か、必要ならどのUIDを使うかは未確定。対象出力が既存Aggregateである場合も含め、物理機器の設定へ与える影響を検証する。privateであることだけを安定性の根拠にしない。

Tap callbackとRME入力callbackは別の到着時刻を持ち得る。形式・sample/host timestamp・実frame数・buffer・latencyを計測し、混合時の時刻整合と必要なFIFO／レート補正を設計する。RME出力をTapするという理由だけで、RME物理入力と同じcallback周期・同じサンプル時刻で届くとは扱わない。64-frame I/Oを設定できても、Tap全体の遅延や更新単位が64 framesに収まる保証はない。

Tapの既定`Unmuted`は、取得しながら元の再生先にも音を送る。`Muted`や`MutedWhenTapped`は元processの再生を抑えるため、既存再生を維持するか、処理後の選択出力だけを聴くかに合わせて選ぶ。消音される範囲、開始・停止時の復帰、二重モニターの有無を実機で確認し、既存出力の変更を未回答のまま固定しない。

Tap取得には`NSAudioCaptureUsageDescription`とシステム音声録音の許可が必要。RME入力向けの録音許可とは分けて案内する。現段階ではTap作成・録音開始・権限要求を行っていない。

### 表示する入力数と代案

TapはRMEの録音slotを置換しないため、設計上は「RME物理入力20ch＋別経路のPC出力20ch」のような構成を検討できる。ただしPC側20chの取得、チャンネル同一性、実際に信号がある範囲は未検証であり、固定40ch対応を確認済みとはしない。設定画面は検証できたソースとチャンネルを列挙する。

Tapで必要な出力チャンネルを保持できない場合は、専用の多チャンネル仮想出力をAudioServerPlugInで公開し、音源アプリからそこへ送る方式が代案になる。この場合のPC出力はRME Playbackではなく、新しい仮想デバイスのチャンネルである。再生先変更へのユーザーの意向を確認して採否を決める。ドライバーの配布・導入、仮想クロック、共有バッファ、channel mapping、更新・復旧の設計が追加で必要であり、現段階では実装・インストールしない。

Appleの仮想デバイスサンプルは2chであり、多チャンネル化や低遅延性能をそのまま保証するものではない。Tapも仮想デバイスも必要条件を満たせない場合、RME Loopbackへ無断で戻さず、成立しない条件を明示する。

### 過去案の位置づけ

TotalMix premixおよびRME Playback専用Loopbackは、初期の比較案としてのみ残す。Loopbackが対応録音slotを置換する制約、同じAESを往路Loopbackと復路出力にすると循環する制約は、その過去案に関するもの。新しいTap取得案の入力数へ転用しない。[過去案の演算比較](mixing-performance.md)の測定値には、Tap取得・仮想デバイスの遅延や負荷は含まれていない。

アプリの選択channel数、HAL stream構成、実USB転送量は別の値として検証する。PC Tapを増やしただけでRMEのUSB録音チャンネル数が増えるとは扱わない。

## 5. Discrete4の処理後ミックスを取り出す

Antelopeの公式手順ではMonitor/HP1のミックスを、DAW Recordに`Loopback Mon/HP1 1/2`として割り当て、ホスト側でその録音入力を取得する。[Loopback・Routing資料](references.md#antelope)

アプリでは「Discrete4復路: DAW Record N / N+1」と保存する。初期例は1/2だが、既存の録音用途を壊さない空きペアへ割り当てる。入力名が空なので、設定画面に機器側の割当説明を表示する。

次の一致確認を採用条件にする:

- Computer Play1/2を入力にした目的のミキサー音声であること。
- ユーザーが使う各FXのON/OFF・設定変更が復路に反映されること。
- ミキサーフェーダー、パン、muteと復路の関係。
- Master/Monitor音量ノブ、Dim、物理出力mute、AuraVerb等の反映範囲。

公式Loopback説明だけでは、物理Monitor出力の音量制御後と完全一致するかは確定しない。必要な処理がUSB復路へ届かず、機器内割当でも解消できない場合は、この実機・firmwareでは今回の要件を満たせない成立条件として扱う。ADATへ戻して完了とはしない。

### 復路のRME出力先

設定画面でRMEのhost playback出力ペアを選ぶ。AES 11/12は初期候補であり、Analog、Phones、S/PDIF、ADAT等の現在利用可能な出力から選択できる。番号・ラベル・streamの対応は実機列挙で検証する。詳細設定ではL/Rを個別指定できるが、同一チャンネルへの重複指定は受け付けない。

保存するのはRMEのdevice UIDと出力L/R番号・照合ラベル。変更はOFF中に適用し、次のONで選択先だけへ送る。保存した出力が見つからない場合はOFFで説明し、別チャンネルへ自動切替しない。

ここで選ぶのはTotalMixのSoftware Playbackへ届くhost出力。実際のHardware Outへの割当はTotalMix側と照合する。アプリの出力選択だけで物理端子の経路が切り替わるとは保証しない。Tapの自process除外は、選択する復路チャンネルに依存させない。

## 6. ケーブルなし運用への移行

往路はRME物理入力＋PC出力Tap → アプリ内の個別gain／ステレオmix → Discrete4 USB Computer Play1/2。復路はDiscrete4 DAW Record → USB → アプリ → 設定したRME host出力L/R → TotalMixで割り当てた物理出力。AESを選ぶ例ではhost output11/12 → TotalMix AES → 物理AESとなるが、アプリはTotalMixの割当を自動変更しない。両機器間のレート差は方向別ASRCで扱い、PC Tapの時刻整合も別途検証する。

移行時の順序:

1. 現在の機器設定を保存し、移行前の信号・FXを比較用に記録する。
2. PC出力の各チャンネルをTapで保持でき、自アプリの復路が混入しないことを確認する。Tapの元再生を残すか消音するかも決める。
3. 目的のDiscrete4処理済みミックスをUSB録音へ返せることを確認する。
4. 両方向を停止・muteした状態で、対象RME録音入力の既存Loopbackを解除し、Discrete4をRMEのADATに依存しないクロックへ設定する。RMEも独立した48 kHzを維持する。共有設定変更の他アプリへの影響を確認する。
5. S/PDIF・ADAT由来の音声を使用ミックスから外し、同じ信号の直結を解除する。外部同期設定だけを残してケーブルを抜かない。
6. RMEとDiscrete4間のケーブルを外し、USB経由だけで片方向ずつ確認する。
7. 必要な個別mix・FX、RMEの選択出力、OFFによる両方向停止、Tap停止時の元再生、長時間安定性を確認する。

これは次段階の作業手順であり、今回は機器設定や配線を変更していない。クロック・ルーティングの非公開APIやUI自動化を新アプリの必須機能にはしない。

移行前のADAT5/6→AES直結は比較基準にはなるが、最終経路へ残さない。独立クロックのデジタル入力で生じた問題を、USB側のASRCだけで修復することはできない。

## 7. フィードバック・二重経路の確認

- RME LoopbackをPC音声取得に使わない。物理入力として読むチャンネルに既存Loopbackの置換がないことを確認する。
- PC Tapは自アプリを除外し、Discrete4からRMEの選択チャンネルへ返した音を往路へ再取得しない。補助processを導入する場合は、その出力も除外対象を検討する。
- 同じPC出力を、物理device向けTapと既存Aggregate向けTapで二重に加算しない。
- 往路ミックスの入力リストに復路チャンネルを入れない。
- Discrete4のDAW Record返りを、別ソフトがComputer Play1/2へ折り返していないことを確認。
- LadioCast等による同じ経路の同時転送を止めてから比較する。
- RME S/PDIF経由と新アプリComputer Play経由で、同じ元音声をDiscrete4へ二重送信しない。
- Tapの元再生とDiscrete4処理後音が、同じスピーカー等へ二重に到達していないか確認する。
- 既存のスピーカー・5.1ch経路への意図しない出力を確認する。

初回の信号確認は低レベルかつ片方向ずつ行う。ソフト内の循環検査は外部ルーティングの確認を代替しない。

## 8. 実装前に確定する項目

| 未確定事項 | 確認方法 |
| --- | --- |
| Discrete4の正確な世代・firmware・driver | ベンダーパネル／本体表示。`Discrete4 USB`という名前だけでは断定しない |
| Aggregate時の入出力異常の詳細 | どの入出力がどう変わるか、結合前後のrate/stream/clock、発生時刻を記録。原因がLOCKとは決めつけない |
| 48 kHz申告とHAL 44.1 kHzの差 | 両側の状態を同時取得し、短い継続観測 |
| RME物理入力の内容 | 対象のLoopback置換がないことと、入力DSP／gain設定を確認 |
| PC音声の出力先を維持するか | 既存device/stream Tapを優先評価。仮想出力への変更可否は別途確認 |
| PC出力Tapのdevice/streamと各channel対応 | 音源ごとの実出力UID、stream形式、開始channel、各channelの試験信号を照合。5.1ch／DTM等も個別確認 |
| Tapキャプチャ用private Aggregateの構成 | Tapだけでの稼働可否、anchor要否・UID、既存機器設定への影響を確認。RMEとDiscrete4の結合は禁止 |
| TapとRME物理入力の時刻整合 | callback時刻、実frame数、latency、FIFO量、レート差を計測 |
| Tapの元再生と自アプリ除外 | Unmuted／MutedWhenTapped等の適用範囲、二重モニター、開始停止時の振る舞いを確認 |
| Discrete4処理後ミックスのUSB公開位置 | DAW Record sourceとFX反映を検証 |
| 移行前ADAT5/6との音声一致 | 旧経路とUSB復路で必要なFX・ミックスを比較 |
| 独立クロックへの移行 | 外部clock依存を解除し、S/PDIF/ADATの必要な音声をソフト経路で置き換える |
| 許容遅延 | LadioCastの同条件測定と、ユーザーが実際に使うミックス・演奏条件で決定 |

I/O buffer64の設定と、全経路の実遅延64 samplesは同じではない。設定と実測は[遅延予算](latency-budget.md)の区分で記録する。

過去のDTM/5.1ch構成は調査の手がかりにだけ使い、本書の現状値は今回の再列挙を採用した。保存済み設定や過去の表示を現在のルーティング成立の証拠にしない。
