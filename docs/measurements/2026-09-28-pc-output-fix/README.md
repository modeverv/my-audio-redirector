# PC OUTPUT取得と左右差・ミキサー表示の確認

記録日: 2026-09-28。ユーザーから、Spotify再生時にDiscrete4 Computer Play 1が小さく、2が大きいとの申告があった。設定とコードを読み取り、PC出力Tapだけを取得する試験を行った。**音源の同時確認、Discrete4への実音到着、修正後GUIの現物確認は未完了**であり、左右差の解消を確認した記録ではない。

## 読み取った保存設定

- PC取得元は物理RMEの出力stream 0、20ch。PC OUTPUTは全20chがMute。
- RME INPUT 1/2だけがUnmute、gainは両方+0.1 dB、panは両方`+1`（R）。他のRME入力はMute。
- RME 1/2のLinkは有効。RETURNはMute、RME復路の選択は9/10。

ユーザーの保存設定は変更していない。元の全設定は `/tmp/my-redirector-pc-display-fix/configuration-before.json` にあり、このディレクトリにはコピーしていない。

## PC Tap取得のみの結果

別々の時点に各5秒、stream 0、要求I/O64で取得した。いずれも20ch interleaved Float32、48 kHz、実callback64 frames、fault/非有限値0、self-process除外のreadback成立を記録した。本アプリからRME/Discrete4への音声出力は開始していない。

| 取得対象 | callbacks / frames | 終了時snapshotのprobePeaks | 記録 |
| --- | --- | --- | --- |
| 物理RME出力 | 3756 / 240256 | ch1: 0.0043644593、ch2: 0.0060092118、ch3〜20: 0 | [probe-rme-result.json](probe-rme-result.json) |
| 既存「5.1ch」出力 | 3753 / 240064 | 全20ch: 0 | [probe-aggregate-result.json](probe-aggregate-result.json) |

`probePeaks`は終了時snapshotで直近に処理したcallbackの各chピークであり、5秒間全体の最大値や音声録音ではない。Bridgeのprobe callbackは各chのピークを毎callback上書きしている。物理RMEを対象としたTapからその時点の非ゼロ信号を得たことは確認できるが、**Spotify由来とは断言できない**。再生音源と再生状態を同時に確認しておらず、試験時点も異なるため、「5.1chではSpotifyを取得できない」「常に物理RMEを選べばよい」とは結論しない。音源の出力先・再生状態を固定した左右別試験が必要。

両JSONは取得中の`state=probe`のスナップショットで、`tapActive`/`aggregateActive`もtrue。停止後の資源解放確認の資料ではない。capture-onlyではDSP coreを動かさないため、`primedMask=0`や`sources[*].frames=0`を転送失敗として扱わず、`probeFrames`/`probePeaks`を見る。

別途行った終了後inventoryではRME/Discrete4とも48 kHz・I/O512 frames、`runningSomewhere`はRME=true、Discrete4=falseだった。RME=trueは本アプリの転送継続を意味せず、利用中のclientの特定もこの値だけではできない。

## コードの読み取りで確認した範囲

- `source0`はRME HAL入力、`source1`は選択したPC出力device/streamのTap。入力・出力方向やsourceの交換は見つからなかった。
- 保存ch番号から0-based indexへの変換は一度。往路はsource0+1を合算し、D4 host1=L、host2=Rへコピーする。
- `pan=+1`は左係数を厳密に0、右係数をgainに設定する。提示設定が実行中にも適用されていれば、RME入力1/2は両方右へ合算され、MuteされたPC OUTPUTからの寄与は0になる。
- Linkはgain/Muteだけを連動し、panは保持する。Link ONでも`R/R`が`L/R`へ自動修正されることはない。

この設定は右へ偏る原因候補だが、SpotifyがRME入力1/2へ届く経路はコードだけでは確認できない。他の有効入力がなく設定が反映済みなら、ランプ・残留信号終了後の本アプリの左出力は無音になるため、D4左に継続して見える小さい信号まで説明したことにはならない。別アプリや別経路からの出力も分けて確認する。

現在の`outputPeaks[0]`/`[1]`はforward/return各stereo busの最大値で、L/R別の値ではない。

## GUI修正と確認状況

ミキサーをsourceとch番号を含む一意な行IDへ変更し、RME INPUTとPC OUTPUTの取得元説明を追加した。PanのL/C/R表示と、OFF中に取得元単位で「Panを奇数L・偶数Rに戻す」ボタンを追加した。Pan resetはPanだけを変更し、gain/Mute/Linkを変更しない。保存済みPanの自動書き換えは行わない。Dockのアイコンは`NSApplication`へ明示設定する処理を追加した。

修正後のビルド、`--self-test-config`（`audioStarted=false`）、codesign verifyは成功した。新版processの2秒間のsampleではmain threadの1720サンプルがすべてevent wait、単発の`ps`表示はCPU 0.0%だった。その観測区間でmain threadが計算を続けて詰まっていた証拠はないが、GUI操作の応答性を実証したものではない。

GUIの読み取り確認ではCUAが `Sky Computer Use native pipe closed before response` となり、再試行でも同じエラー、Dockの`getApp`はtimeoutとなった。**修正後の表示・Pan reset操作・Dockアイコンはユーザー確認待ち**。この項目は確認後に追記する。ユーザー設定の変更、Discrete4への実音転送、左右差の解消は今回未検証。

## 保存資料

プローブJSON2件を `/tmp/my-redirector-pc-display-fix/` から内容を変えずにコピーした。

| ファイル | SHA-256 |
| --- | --- |
| probe-rme-result.json | `7bf3a1113eea2889c9013ae9012d8ece7eeabea7bdc85b7aa3511b159de6f45a` |
| probe-aggregate-result.json | `7b4132f4a52f80b8e9672242d8e1b2a3716a0fc8683d40fab5fc969c369643ad` |

次の手順は [検証ガイド](../../validation-guide.md) のPC音声・RME入力の項目を参照。
