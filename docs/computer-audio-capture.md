# RME Loopbackを使わないPC音声の取得

更新日: 2026-09-28。ユーザー指定の音声経路を設計へ反映した段階。Tap作成、録音許可要求、音声I/O、出力先変更、仮想driver導入は未実施。

## 1. 確定した要件と第一候補

設定画面にRMEの物理入力とPC再生出力を並べ、各channelのgainを調整する。合計を2mixにしてDiscrete4 Computer Play 1/2へ送る。PC音声にもRME Loopbackを使わず、録音入力slotをPC音声用に置き換えない。

第一検証候補は **Core Audioのdevice/stream指定・non-mixdown Tap**。現在のPC再生先を保ち、その出力streamへ向かう音声を取得する方式である。新しい仮想出力先を使う運用の可否は確認中で、現時点ではOSや各アプリの再生先を変更しない前提で調査する。

Appleの `initExcludingProcesses:andDeviceUID:withStream:` は、指定したdevice streamへ出るprocess音声を対象とし、Tapのformatがそのstreamと一致すると説明している。このため、多channelを保持できる候補となる。ただしこのRME driverと既存Aggregateでの取得・mappingは実機で確認する。[Apple API](https://developer.apple.com/documentation/coreaudio/catapdescription/initexcludingprocesses%3Aanddeviceuid%3Awithstream%3A?language=objc)

global stereo TapやstereoMixdownを使ってから20本の独立フェーダーを表示する設計にはしない。先に混合された音声から元の出力channelを分離することはできない。

## 2. 「PC出力」の意味

| 表示 | 取得元・意味 |
| --- | --- |
| RME INPUT 1..N | RMEの物理host input。既存Loopbackで置換されていないことを確認 |
| PC OUTPUT 1..M | 選択した再生deviceのstreamへアプリ群が送った音声。TotalMix処理前 |
| 2MIX | 上記のgain/pan適用後のstereo。送信先はD4 Computer Play 1/2 |
| RETURN | D4の目的のFX後ミックス。RMEの選択出力へ送る独立した復路 |

PC Out1/2に複数アプリが出す音は、その出力channel内で混ざった状態で取得する。今回のフェーダーはprocess別ではなくchannel別。同じchannelへ出されたアプリ同士を後から分ける要件は含めない。

Tapのstream indexはchannel番号ではない。device内の複数stream、そのstream内channel、全体のchannel位置、表示名を対応付ける。Tap formatとAudioBufferListを検証し、stereo化・欠落・順序違いがあれば対応済みと表示しない。

RME入力20chとPC出力20chを取得できた場合は合計40chを独立表示できる。これは取得backendが別だからで、RMEのUSB録音枠が40chになるわけではない。48 kHzでの実入力数、PC出力数、channel保持はPoCの結果で確定する。

既存のdefault output「5.1ch」やDTMを使うアプリは、物理RMEではなくAggregate UIDへ出している可能性がある。物理RME Tapだけで捕捉できるとは断定しない。取得元deviceを明示選択し、各channelへ一つずつ信号を送って対応を確かめる。複数deviceの同じ音を二重取得しない。

## 3. Tapの受信とAggregateの扱い

Appleの公式サンプルはTapをHAL Aggregateの入力として受信する。従ってこの方式を「Aggregateを一切使わない」と説明しない。[Apple capture sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

- RMEとDiscrete4を1つのAggregateへ結合する構成は採用しない。
- PC capture用のprivate Aggregateをアプリが管理する案を検証する。privateという属性は、低遅延・安定性の保証ではない。
- Tapだけを含むcapture deviceがこのOSで動作するか、clock anchorとして単一のdeviceが必要かは未確定。
- anchorを使う場合も、2台の物理機器を同時にsubdeviceとして含めない。既存Aggregateを入れ子で含める場合は実subdeviceまで確認する。
- Tap/aggregateのrate・buffer・latency・timestamp・drift compensation状態を読み、OS側の追加変換を含めて記録する。
- Tap受信のための出力には音声を送らない。D4出力とRMEの選択出力はそれぞれの物理HAL経路が所有する。

検証が不合格なら、そのbackendを未成立とする。RME LoopbackやRME＋D4 Aggregateへ黙って戻さない。

## 4. 自己音声・元の再生音

自アプリのprocessをTapから除外する。D4から戻してRMEの選択出力へ出す音がPC取得へ混ざると循環するため、これは開始条件とする。PIDは保存せず、実行中のprocess objectを毎回解決する。

自分の除外を確認する信号試験は、他アプリのPC音声が取れること、自分の復路送出は取れないことを別々に確認する。他アプリが復路を録音して再生する循環や、外部機器による折り返しはprocess除外だけでは防げない。

初期Tap評価はUnmutedで元の再生を残す。PC元音声がRMEから直接鳴る経路とD4処理後の経路が並列に残る可能性があるため、TotalMixの選択した最終出力には意図したD4復路だけが入るよう、既存用途と併せて確認する。

MutedWhenTappedは元のprocess出力を抑える選択肢だが、複数出力・他用途への影響、ON/OFF・権限取消し・クラッシュでの復元を検証してから明示的な運用設定とする。初期案で自動ミュートやdefault output変更を行わない。[Apple mute behavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)

Tapで解放するのは前段Loopbackのための出力バス割当と録音入力の置換。既存アプリがRMEへ再生し続ける限り、RMEのSoftware Playback出力そのものを使用しなくなるわけではない。

## 5. クロックと遅延

RME入力とPC Tapは別callbackから届く。入力blockの長さ、到着位相、sampleTime原点、clock domainを無条件には揃えられない。

基準構成はRME群とPC群をそれぞれstereoに混ぜ、各FIFO/ASRCでD4の出力時間軸へ合わせて合算する。D4復路には別FIFO/ASRCを使う。通常は3本のstereo FIFOと3つのstereo ASRCだが、各音源の往路に通るSRCは1つ、共有復路に1つ。3つが直列になるわけではない。

複数のPC streamが別時間軸で返るなら、まずclock groupを分ける。同一clockを実証したものはtimestampで位置合わせし、変換前の合算を最適化できる。UIのstrip数とASRC数を一致させる必要はない。

gain/mix自体には先読み不要という従来の結論は維持する。一方、Tap取得・別callbackのFIFO・OS内変換の遅延は追加の未測定項目。以前の20ch合成音声ベンチマークや2経路の待ち量を、新経路の総遅延・安定性の実測値には使わない。[遅延予算](latency-budget.md)

## 6. 成立条件と診断

1. 対象device/streamからmultichannel formatを取得し、channel別信号が独立に届く。
2. 既存のRME出力、5.1ch、DTMのうち必要な再生元を漏れ・二重取得なく扱う。
3. RME全物理入力とPC音声を同時取得でき、RME録音slotのLoopback置換が不要である。
4. 自アプリの出力を除外し、復路の再取り込みがない。
5. 要求32/64/128と実buffer・callback長、Tap内部待ち、timestampを測れる。
6. RME＋D4を結合しない受信構成で開始停止・再接続・sleep/wake・長時間動作を確認できる。
7. NSAudioCaptureUsageDescriptionを備え、システム音声取得権限の拒否・取消しを扱う。物理入力側の録音許可とは別に診断する。
8. 設定画面の全gain操作とmeter表示中も音声処理に待ち・allocationを持ち込まない。

デバイス列挙の成功と音声取得成功は別。音声取得成功と目的のchannel対応、実遅延、長時間安定性も別の合格条件とする。

## 7. 仮想多チャンネル出力という代案

PCの出力先を「My Redirector」に変更する運用であれば、自作のAudioServerPlugInでPC Out1..Mを明示的に定義し、アプリでRME物理入力と混ぜる方式がある。RME Software Playbackへの依存も減らせる。

Appleは仮想audio deviceにはAudio Server Driver Plug-inを案内している。物理device向けAudioDriverKitを仮想deviceの必須手段とはしない。[Apple driver guidance](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver)、[Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)

この代案ではdriver配布・更新・coreaudiod内処理・アプリとのデータ受け渡し・clock timeline・アプリ停止時の動作が新たな検証対象になる。複雑だから除外するのではなく、取得音声と運用が要件に合うか、I/O64で成立するかを比較する。

AudioServerPlugIn内部からclient HAL APIでRME/D4を開く構成にはしない。物理I/Oは外部のアプリエンジンが担当し、共有メモリ等による有限・非blockingの音声受け渡しと時刻対応を別に設計する。

現時点で仮想driver導入やPC出力先変更を実行したわけではない。Tapが不成立の際の代案として保存し、音声経路を黙って変更しない。
