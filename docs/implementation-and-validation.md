# 実装と検証の進め方

更新日: 2026-09-28。以下は計画であり、試験結果ではない。

## 1. Phase 0: ソフトウェアだけで経路が成立するか確認

1. TotalMix・Discrete4の現在の設定を保存し、移行前の経路・FX・音量操作を記録する。
2. モデル、driver/firmware、clock source、lock/sync、HAL nominal/actual rate、入出力のphysical/virtual stream format、bufferを同時に記録する。
3. Discrete4の48 kHz動作申告とHAL 44.1 kHz報告の差を調べる。Aggregate結合時の入出力異常は別の症状として記録し、原因を断定しない。
4. RME Loopbackを使わず、RMEの物理入力を個別に読む。既存のLoopbackが録音slotを置換したままになっていないことを確認する。復路は設定画面で選ぶRME host playbackのL/Rチャンネルへ送る。AES相当の11/12は初期候補にとどめ、現在のstream構成・ラベルとの対応を検証する。
5. PC再生音は、既存の出力先device UIDとstreamを指定するCore Audio process tapを第一評価候補にする。`isMixdown=false`で元のチャンネルを保持し、各チャンネルに個別gainを持たせる。stereo global tapで最初から2chへ潰さない。`stream`はデバイスのstream indexであり、チャンネル番号ではない。実際のtap format・stream構成・チャンネル対応を読み取る。[Appleのdevice-stream tap](https://developer.apple.com/documentation/coreaudio/catapdescription/initexcludingprocesses:anddeviceuid:withstream:)
6. Tapを読むためのprivate Aggregateは、PC captureの入れ物に用途を限定する。RMEとDiscrete4を束ねない。tapだけで構成できるか、clock anchorとなる単独deviceが必要かは未検証として、構成辞書・clock source・subdevice/subtap・drift compensation・追加input latencyを記録する。必要な構成がこの制約に収まらなければ不成立とする。[Appleのtap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
7. 現在の5.1ch／DTMを含め、アプリの出力先が物理RMEなのか既存Aggregateなのかを調べる。実際の出力先を対象にしたtapで各PC出力チャンネルを区別して取れることを示す。物理RME宛てtapが既存Aggregate宛て音声も取れるとは仮定しない。自分のプロセスを除外して、選択したRME復路チャンネルへ返した音声を再取得しないことを確認する。自己音声除外をAESの選択やチャンネル番号に依存させない。
8. 元のPC音声が直接RME出力にも流れる場合の二重出力を確認する。tapのmute behaviorについて、取得中、開始失敗、OFF、異常停止、アプリ終了の各状態で、どのprocess／streamの直接出力が止まり、いつ復帰するかを実測する。全PC音声を無条件にmuteする仕様にしない。
9. Discrete4のDAW Record Loopbackで目的のFX後ミックスを読めるか検証する。FX、ミキサーフェーダー、master/monitor音量・muteの反映範囲を記録する。禁止対象のRME Loopbackとは別の機能である。
10. 両機器を独立した48 kHz運用にし、機器間ケーブルなしで各物理デバイスを個別に開けることを確認する。PC captureの実レート・timestampも独立に記録する。既存の別Aggregateとの共存は独立した試験項目にする。
11. LadioCastの不満が再現する条件と比較基準を記録する。保存plistは稼働設定の証拠にしない。

成立条件は「PC出力をチャンネル別に取得できること」と「必要なDiscrete4処理済み音声をUSBで取得できること」。前者がtapで成立しない場合は、AudioServerPlugInによる多チャンネル仮想出力deviceを別案として評価する。これはアプリ／OSの出力先変更とdriverの導入を伴い、物理RMEへ送り続ける音声を自動捕捉するものではない。AudioDriverKitを仮想device用の既定案にしない。backendの変更は明示選択し、自動で切り替えない。[Appleのdriver方針](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver)

後者が不可なら機器内割当を再検討し、それでも不可なら今回の実機・firmwareでは要件未達と明記する。RME Loopback、ADAT復路、RME＋Discrete4 Aggregateへ戻して要件を満たしたとはしない。

## 2. Phase 1: 診断と同期制御の試験

まず音声を開始しない機器診断を実装する。UID、alive/running、チャンネル、stream形式、rate、buffer範囲、device/stream latency、safety offset、変更時刻を出力する。取得不能は未取得とし0で埋めない。

並行して、実機に依存しないSPSC FIFO・ASRC adapter・ドリフト制御を実装し、RME、PC capture、Discrete4の3つの仮想クロックで検証する。PC captureが複数の独立clock groupを持つ場合は、その数まで増やす。

| 入力条件 | 確認すること |
| --- | --- |
| クロック差0、正負の一定ppm差 | 24時間相当で占有量が発散しない。比率制御の符号が正しい |
| ppm差の緩やかな変化 | 補正が追従し、継続的な遅延増加がない |
| 異なるblock長、callback順序、jitter | FIFOの所有権・frame管理が正しく、PIが周期的変動を音程変調へ変えない |
| timestamp欠落・逆行・飛び | 無効なレート推定を使わず、規定のfaultまたは検証済み占有量制御になる |
| underflow/overflow、制御queue遅延 | RTが待機せず、欠落を記録し、停止・resetの順序が正しい |
| SRCが一部だけ消費／生成 | 実数に従ってFIFOを進め、余りを失わず、出力不足をゼロにする |
| NaN/Inf、左右別信号、gain変更 | 非有限値処理、左右・route、rampが正しい |
| 複数入力mix | RME物理20＋PC20なら計40 mono相当まで独立の識別信号で検証。実際のPC数はtap formatに従う。2/8/16/20/40 mono相当、32/64 frames、planar/interleaved、gain/pan ramp、mute、clipで結果と処理時間を確認 |
| source別の不着・無音 | PCアプリ無音／終了、tap callback停止、RME入力無音を区別。無音でも有効frameが供給されるかを確認し、primeの循環待ちや無期限待ちを起こさない |
| 経路間の時刻・位相差 | 到着順を収録時刻と混同しない。source別遅延と必要な位置合わせを測り、timestampの妥当性を確認する |

simulation合格は実機安定性の証明ではない。通常のSRC処理中にallocationやlockがないか、採用versionを固定して検査する。メモリ／race検出ツールの試験と、計測負荷を加えない性能試験は分ける。

## 3. Phase 2: PC captureと個別デバイスの双方向エンジン

標準構成はRME、PC capture、Discrete4の3 callbackと、3本のstereo FIFO・3個のASRC。RME＋Discrete4 Aggregateは作成しない。PC tapのcapture containerだけを別に管理する。

| callback | producerとして行う処理 | consumerとして行う処理 |
| --- | --- | --- |
| RME | 物理入力のgain/pan→stereo stem→FIFO R | FIFO D→ASRC D→選択したRME host playback L/R |
| PC capture | PC出力の各channelのgain/pan→stereo stem→FIFO P | なし |
| Discrete4 | 処理後USB入力→FIFO D | FIFO R→ASRC R、FIFO P→ASRC Pを加算→Computer Play1/2 |

R/PのSRC・PIはD4 callback、DのSRC・PIはRME callbackが所有する。同一clock groupの入力ごとにFIFO・ASRC・threadを作らない。PCを一度RME clockへ変換してからRME→D4へ変換する直列2段の経路を基準にせず、D4側で2本のstemを合流させる。複数の独立PC clock groupが必要ならP経路はgroupごとに増える。

PC tapがRMEと同じ出力deviceを対象としていても、同じclock・同じ配送位相と断定しない。timestampの対応、実レート差、tapの内部補正／遅延を検証して初めて共通clockへの統合を検討する。統合後も別callbackの到着差に対する受け渡し・位置合わせは必要であり、自動的に旧2 callback構成へ戻るとはしない。

1. 両機器48 kHz / 要求64 framesを主目標とし、32/64/128 framesを最初の比較に含める。各機器の設定成功、読み戻し、実callback長を確認する。未対応値を別値へ黙って置換しない。
2. RME物理入力→D4、PC capture→D4、D4→選択したRME host playback L/Rを別々に検証してから、全経路を同時に動かす。PC callback長は要求I/O値と一致すると仮定せず、実際の長さ・周期を記録する。
3. R/P/D別FIFOの目標32/64/128 framesとSRC品質を記録し、過不足・補正比率・実遅延を観測する。I/Oサイズとは別変数として一つずつ比較する。PC capture固有の配送jitterに必要な待ちを旧RME Loopback経路から流用しない。
4. 隣接my-lan-audio2で実I/O32と軽いcallback処理が確認できたため、32も最初から評価する。Discrete4側や双方向で同じ安定性になるかは別途試験する。
5. libsamplerate Fastestを低遅延候補、Mediumを音質比較とする。既存プロジェクトのlinearを低CPU基準、必要ならApple Varispeedも比較する。linearを音質評価なしに製品既定へはしない。
6. 通常運転中に無言でbufferやSRC品質を変えない。低遅延化は検証済み設定を明示選択する形にする。
7. RME入力・PC出力の各gainを別々に操作し、意図したchannelだけが変化することを確認する。最大入力数と全フェーダー操作中の処理時間、FIFO、音切れ、実遅延、clipを測る。gain/mix自体のための追加block待ちは作らないが、PC capture経路の受け渡し・遅延は独立に計上する。
8. tapを含む全callback、3個のASRC、必要な補助処理を実測する。隣接プロジェクトの32-frame動作、今回のSRC単体、旧20-source mix単体の測定を、新構成全体のCPU・遅延・安定性の証拠に置き換えない。

開始・停止、capture権限拒否、いずれかの開始失敗、prime timeout、機器消失時の回収までGUIより先に確立する。3 producerを動かして出力は無音から始め、各経路のFIFO/SRCをprimeする。D4処理済み入力の生成を、往路がON表示になるまで止めるような循環待ちは作らない。復路が初期に無音でも有効frameならprimeに使える。故障時は全経路を停止し、全callback終了を確認するまでFIFO/SRCやtapを解放しない。

## 4. Phase 3: ミックスとGUI

エンジンの合格後、設定保存、RME入力／PC出力の個別gain/mute、Settings、1個のON/OFFボタンを載せる。機器・tap対象・チャンネル・buffer等の構造変更はOFF中のみ。gain/muteは動作中も変更可能。設定画面ではI/OサイズとR/P/D別FIFO目標をsamplesで変更し、48 kHz換算msも併記する。要求64、HAL実値、callback実長、実測遅延を区別する。RMEの物理入力数とPC captureのチャンネル数は別に表示し、合計20を共通上限にしない。

復路のRME host playback L/Rを設定画面で選択する。RME device UID、L/Rの1-basedチャンネル番号、streamとの対応と照合ラベルを保存し、起動・再接続時に再検証する。AES相当11/12を固定せず、現在のmappingで確認できたときの初期候補とする。保存先の欠落、方向違い、範囲外、L/R重複、mapping不一致ではOFFのまま理由を表示し、AES、Analog1/2、近い番号へ自動fallbackしない。

この設定が選ぶのはTotalMixのSoftware Playbackへ渡すhostチャンネルであり、物理Hardware Outへのルーティングではない。host AES相当を選んでもTotalMixの物理出力サブミックスを自動変更したことにはならない。既存のTotalMix設定を確認し、目的の物理端子までの経路と二重出力・循環の有無を別々に検証する。

出力先変更はOFF完了後にだけ適用する。停止時は旧経路をfade outして自分の出力を無音化し、全callback停止を確認して旧mapping・残留音声を破棄する。再開時は新mappingでprimeし、自分のRME出力bufferを毎callbackゼロ初期化して選択したL/Rだけへ書く。未選択チャンネルと以前の出力先に自分の音声が残らないことを確認する。他アプリの出力やTotalMix内の既存ルートをゼロ化する処理ではない。

メイン画面から設定を開閉しても音声を乱さないこと、UIが重い間にRTが待たないことを検証する。未接続、権限拒否、設定破損ではOFFのまま理由を表示する。

## 5. 遅延をどう測るか

| buffer | 48 kHzでの1周期 |
| --- | --- |
| 32 frames | 0.67 ms |
| 64 frames | 1.33 ms |
| 128 frames | 2.67 ms |
| 256 frames | 5.33 ms |
| 512 frames | 10.67 ms |

これはcallback周期であって片道・往復遅延ではない。RME物理入力経路にはADC／機器内処理とUSB、PC経路にはtap／capture containerの配送・内部処理が加わる。そこから各source FIFOの実占有量、ASRC、Discrete4のDSP、USB復路、復路FIFO／ASRC、選択したRME host playbackおよび実際の物理出力までを測る。物理出力がアナログならDAC等の遅延も対象となる。RME Loopbackを通る経路は今回の測定対象ではない。

FIFO起因の待ち時間の目安は、その方向の実占有source frames ÷ source rate。SRC内部への先読み・フィルタ遅延は別に測る。HALのlatency/safety offset/bufferを足しただけの数字を実往復遅延としない。包含関係を確認して二重計上を避ける。

基準信号と対象経路の出力を同一の録音クロックで取り、低レベルのインパルスや相関用信号の相互相関で差を求める。独立クロック・SRCで波形は変わるため、サンプル完全一致は要求しない。

- RME物理入力→Discrete4の目的バス、PC playback→同バス、処理後バス→選択したRME出力、各sourceからの全経路を分ける。hostチャンネルとTotalMixで実際に送る物理端子を両方記録し、異なる端子の測定を同一条件として比較しない。
- RME／PC stemがD4で合流するときの相対位置を測る。同じ音の重複sourceを加算する場合は位相差も確認する。全sourceが同じ遅延とは表示しない。
- 中間地点を独立して測れない場合、片道を推測せず全経路だけ報告する。
- 測定機器へのAES接続等は最終出力の計測に使えるが、RMEとDiscrete4間の同期・転送ケーブルを再接続した状態を最終構成の測定にしない。
- DSP bypassと実際のFX有効状態を両方測る。起動直後と長時間後で遅延が蓄積していないか確認する。
- 録音系自身の遅延は基準測定で把握する。アプリ内部timestamp差と物理経路の実測値を分けて保存する。

LadioCast比較は可能な限り同じsource、復路、rate、実buffer、clock、FX、接続で行う。LadioCastで同条件を設定できない場合は相違を明記する。旧ケーブル／Aggregate構成との比較は「システム構成全体の比較」とし、アプリ単体の効果と混同しない。

記録するのは条件、計測回数、中央値、p95、最大、長時間前後差、異常回数。目標msは基準測定と実際の使用感から決定する。「往復3 ms」「無遅延」等は現時点で保証しない。

64 samplesの目標値は設定画面から調整可能にする。ただしI/O64/FIFO64の達成を「全経路64 samples達成」と報告しない。今回のSRC単体測定ではFastest約20 frames、Medium約47 framesの先読みがある。基準構成全体ではASRCは3個だが、各sourceからD4を経て選択したRME復路先へ至る直列経路は往路1個＋復路1個。tap／capture container内部の変換や待ちは別途調べる。[測定と暫定予算](latency-budget.md)

## 6. 暫定の受け入れ条件

| 試験 | 合格の目安 |
| --- | --- |
| 最終構成 | RME Loopbackなし、RMEとDiscrete4間のS/PDIF・ADAT・同期ケーブルなし。両者を結合するAggregateなし。tap用private Aggregateの構成・clock・副作用を検証し、PCチャンネル別取得と往復経路が成立 |
| 小バッファ | I/O要求64を両機器で読み戻し・callback確認。32も比較。設定したFIFO待ちを含め実遅延を別測定し、未達なら未達と報告 |
| 個別ミックス | RME物理入力とPC出力を独立に識別・gain操作。最大source数（実機形式が対応する場合20＋20）、gain/pan/muteの連続操作、meter表示中も同じ条件を維持。channelごとの追加block待ち・ASRCなし。clock group境界のFIFO／ASRCは別計上 |
| 信号内容 | Computer Play1/2へ正しい左右・mixが届き、USB復路が目的のFX後音声。自分のRME出力bufferでは選択L/R以外をゼロ化。TotalMixから意図した物理端子へ届き、意図しない二重出力なし |
| 復路先の選択・保存 | AES相当と別の有効なhost出力ペアでL/Rを識別。OFF中の変更、再起動後の復元、旧出力先に残留音声がないことを確認。欠落／不正／mapping変更ではOFFで説明し、自動fallbackなし。host選択とTotalMix物理ルートを別々に検証 |
| PC capture | non-mixdownのchannel対応、5.1ch／DTM出力先、自process除外、選択した復路の非再取得、直接出力との二重化なし。AES以外の復路先でも自己音声除外が有効。mute behaviorの開始／停止／異常時の影響が設計どおり |
| OFF/ON | 100回でクラッシュ、復旧不能、ルート誤り、目立つ開始停止ノイズなし。OFFで管理対象の両方向停止 |
| 連続運転 | 8時間、その後24時間。録音検査でクリック・音切れなし。FIFO underrun/overrun、確認できるoverload、callback停止なし |
| ドリフト | FIFOが限界へ向かわず、遅延の継続的増加なし。比率補正に起因する可聴な音程変動なし |
| 負荷・GUI | ブラウザー再生、通常作業、設定開閉でも維持。callbackの処理時間に周期に対する余裕 |
| CPU・メモリ | メモリ増加が収束。同条件LadioCastとCPU・電力負荷を比較。SRC品質と遅延の代償を記録 |
| USB切断／再接続 | 両方向を停止し理由を表示。同UIDを再検証しONで回復。別機器への切替なし |
| sleep／wake | 古いtimestamp、AudioObjectID、FIFO内容を使わず、再検証・primeから再開 |
| rate変更・制御異常 | 44.1/48等の形式変更、ratio上限張り付き、長い制御停止を検出し規定どおり停止 |
| 権限・設定破損 | マイク／入力録音とSystem Audio Tapの許可拒否・取消し、壊れた設定でもクラッシュせずOFFで説明。`NSAudioCaptureUsageDescription`等を整備し署名した実アプリで検証 |
| 共存 | DTM、5.1ch、Work Pager等の必要な用途を併用し、rate/buffer競合と二重出力を確認 |

「プロセスが動く」「callbackが進む」「メーターが動く」「正しく鳴る」「24時間安定」は別の達成条件。HALカウンターだけで音切れゼロと結論しない。

## 7. 合否による次の判断

- **USBで必要なFX後ミックスを取得できない**: 機器内割当を調査。解消できなければ現ハードでは要件未達。ケーブル復路を完成扱いしない。
- **tapで必要なPCチャンネルを分離取得できない**: 対象device／stream、既存Aggregateのmapping、実formatを調べる。解消しなければ仮想多チャンネルAudioServerPlugIn案を明示評価し、RME Loopbackやstereo tapへ黙って変更しない。
- **tap用Aggregateにも異常が出る**: tapだけの構成か、anchor、drift補正、既存device設定への影響を切り分ける。privateだから影響がないと扱わず、不成立ならこのbackendを採用しない。
- **独立I/Oでも異常がある**: driver、USB経路、同時I/O、他アプリによるrate変更を切り分ける。RME＋Discrete4 Aggregateを外しただけで解決済みとしない。
- **FIFOが発散する**: 比率の向き、timestamp、推定、PI、内部prefetch、frame数管理を点検。単に容量を増やして解決済みとしない。
- **安定だが遅延が大きい**: FIFO目標、実buffer、SRC内部遅延を個別測定し、一つずつ調整する。品質・余裕との代償を記録する。
- **目標に達する**: 不要なbackendや機能を増やさず、復旧・長時間試験・GUIの簡潔さを優先する。

## 8. 現在の成果と未実施

要件整理、一次資料調査、読み取りによる機器列挙、チャンネル対応確認、隣接my-lan-audio2の参照、SRC・ミックスのオフライン単体計測、設計文書の更新まで完了。アプリ実装、機器設定・配線変更、音出し、LadioCastとの測定比較、実機の長時間試験は未実施。
