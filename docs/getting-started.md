# 初期実装のビルドと使い方

この版はローカルMac向けの初期実装。設計の全受け入れ条件（実音の経路一致、32/64 frames、8/24時間運転）を合格済みとするものではない。実施した確認と残る制約はREADMEの実装状況を参照。

実際の画面操作と、全Muteから実信号・FX後復路・低遅延設定・長時間へ進める手順は [使い方と実機検証ガイド](validation-guide.md) を参照。保存したgain/muteは次回も復元するため、起動時OFFと全入力Muteは別に確認する。

## ビルド

Xcode Command Line ToolsとmacOS 14.2以降を使う。この開発環境はApple Silicon / macOS 26系。

```sh
./scripts/build-app.sh release
./scripts/test.sh
```

アプリは `dist/My Redirector.app` に生成する。libsamplerate 0.2.2の必要ソースをリポジトリに含めたため、追加ライブラリのインストールや初回ダウンロードは不要。build-app.shは既定でadhoc署名を行う。継続利用時は `CODESIGN_IDENTITY` に利用可能な署名identityを指定できる。開発中の再署名でmacOSが取得権限を再確認する場合がある。

## 先にPC取得を確認する

1. アプリを開き、メニューの「設定…」（⌘,）へ進む。起動時はOFF。
2. 入出力画面でRME、Discrete4、PC再生先deviceと出力streamを選ぶ。PC再生先は物理RMEとは限らず、現在の5.1chやDTMへの再生ならその実際の出力先を確認する。
3. PC取得テストを開始する。これはTapの音声取得だけで、Discrete4やRMEへの音声出力は開始しない。macOSのシステム音声取得許可が表示された場合はユーザーが許可する。
4. 取得format、チャンネル数、callback数、メーターを確認し、停止する。メーターが動くことと、各channelが正しく対応することは別に確認する。

Tapを受信するprivate Aggregateはアプリ管理の一時資源。RMEとDiscrete4を1つのAggregateへ結合しない。Tap-onlyの受信がこのOSで成立しなければエラーを表示し、別の経路へ自動切替しない。

## 音声転送

- 物理RME入力、PC出力、Discrete4処理後USB入力が48 kHzであることを確認する。アプリは機器のclock sourceやTotalMix／Discrete4内部routingを自動で変更しない。
- Discrete4側で必要なFX後ミックスをUSB/DAW Recordへ送れる経路を先に確認し、確定した番号をアプリの「処理後入力 L/R」に設定する。DAW Record Loopbackは候補で、その選択肢とFX後の取得位置は実機未確認。現在のRecord1/2はPREAMP1/2であり、目的の処理後ミックスとは扱わない。確認まで復路をMuteにする。
- 復路のRME出力L/Rを選ぶ。これはhost playbackの番号であり、物理Hardware Outへの割当はTotalMix側で照合する。AES相当11/12は初期候補で固定ではない。
- RME INPUTとPC OUTPUTで使用する音源だけを有効にする。初期値は全入力mute、復路もmute。隣接stereoのL/Rを崩さずgain/muteを連動できる。
- I/O frames、RME/PC/復路それぞれのFIFO目標、SRC品質を選ぶ。64は試験目標であり実遅延64の保証ではない。
- メインのONで開始する。必要な経路のprimeが終わるまでON完了とは表示しない。形式不一致・機器消失・FIFO異常では出力を止め、設定画面に原因を表示する。
- 出力先・機器・buffer等の構造変更はOFF中のみ。gain/muteは動作中も変更できる。

**初期版のFIFO制限:** 各経路のsourceとdestinationの実I/O bufferの大きい方以上をFIFO目標にする。RME往路と復路はRME／Discrete4、PC往路はTap capture／Discrete4の組を照合する。I/O64に対してFIFO32は拒否する。GUIのFIFO候補は16/32/64/128/256/512/1024 frames。I/O要求値自体も読み戻しと一致しない場合は開始を拒否する。例えばI/O512で比較するなら全FIFOを512以上に明示設定する。アプリはFIFOを無断で拡大しない。

この下限は現在の実装の開始条件であり、それを満たせば実機で安定するという保証ではない。FIFOを増やすと待ち時間も増える。小さいI/O・FIFOへの調整は、PC取得、往路、復路がそれぞれ成立してから測定しながら行う。

Tapは自アプリの復路出力を除外する。既存の他アプリやTotalMix経由の二重モニター・循環は別に確認する。PC元音声の出力を残す設定を既定とし、全PC音声を無条件にはmuteしない。

## 診断CLI

```sh
"dist/My Redirector.app/Contents/MacOS/MyRedirector" --inventory
"dist/My Redirector.app/Contents/MacOS/MyRedirector" --probe-config /absolute/path/config.json --seconds 5
```

inventoryは機器情報の読み取りだけでTapや音声I/Oを作らない。probeは明示的なPC取得テストでシステム音声取得許可が必要。CLIでの権限判断がGUIと同じとは仮定せず、通常利用は署名済みアプリから行う。

probeは既定で5秒、`--seconds`で0.2〜60秒の取得期間を指定できる。指定時間にかかわらずcallbackが0回なら終了コード1と説明を返し、最終status JSONは標準出力に残す。正常終了にはcallbackの進行が必要だが、音声内容・チャンネル対応・自己音声除外の正しさまで確認した意味ではない。無音のcallbackも進行回数に含むため、実際の信号は別に検証する。

設定JSONの形式とC ABIは [implementation-contract.md](implementation-contract.md)。音声内容の録音ファイルは通常動作では保存しない。

### 全ミュートで双方向I/Oを確認する

```sh
"dist/My Redirector.app/Contents/MacOS/MyRedirector" --check-muted-route /absolute/path/config.json --seconds 10 > muted-route-check.json
```

この診断はRME・Discrete4とPC Tapを開く。読み込んだ設定のメモリ上のコピーで、RME入力・PC入力の全チャンネルをmute、復路をmute、`tapMuteOriginal=false`へ強制する。未指定の入力もbackend既定のmuteを維持する。元の設定ファイルは書き換えず、muteを解除するオプションはない。他アプリが再生する元音声はこの診断で消音しない。

マイク／音声入力の権限を確認し、未決定ならOSの許可画面を表示して最大60秒待つ。拒否・時間切れでは音声エンジンを開始せず終了コード1。権限待ちはmain RunLoopを動かして処理する。Tap用のシステム音声取得権限も必要になる。

`--seconds`は全ミュート運転の期間で、既定10秒、0.2〜60秒。準備・primeもこの運転期間に含む。開始処理は最大30秒、停止処理は最大10秒を監視し、期限超過時は停止要求後に最大10秒の回収猶予を置く。制御API自体が返らず回収を確認できない場合は、その事実をJSONに残して失敗にする。GUIの保存ラベル確認を代行するものではないが、実デバイス・形式・チャンネル範囲等はbackendの開始時検証を通す。

出力JSONには有効な全mute設定、権限結果、状態の推移、RME／PC／Returnのframe数、prime状態、rateの観測、fault、停止前後と回収結果を記録する。音声データは記録しない。成功には`running`の観測、全producerのframe進行、faultなし、出力peakの無音維持、停止後の`off`・Tap／Aggregateの非稼働・安全なteardown確認が必要。失敗時もJSONと標準エラーの説明を残す。

PC FIFO不足は転送を止めずに再同期するが、この検証CLIは不足/超過のない `lossFree` も成功条件にする。回復があれば指定時間の運転は続け、最終JSONにその回数を残したうえで検証結果は失敗とする。GUIの継続運転と、欠落ゼロの検証合格は別の意味になる。

アプリケーションログは `~/Library/Logs/My Redirector/events.jsonl`。PC不足/復帰の累計と差分を最大1秒ごとにまとめ、終了時にも未記録分を出力する。音声PCMは保存しない。最大2 MiB×現行1本＋過去3本で循環する。診断JSONの `eventLog.error`、`droppedRecords`、`writeFailures` に問題があればログの保存は完全ではないが、その失敗で音声を停止しない。

成功しても、信号内容、channel対応、自己音声除外、FX後復路、物理端子からの実音、実遅延を検証した意味にはならない。これらは全ミュート診断後に別の信号試験で確認する。

## 48 kHzから44.1 kHzへ戻る場合

読み取り専用の監視を次で実行できる。各機器のnominal/actual rate、buffer、他のアプリを含めた稼働状態が変わるとJSONLへ記録する。音声I/OやTapを開かず、機器設定も書き換えない。

```sh
swift scripts/watch-rates.swift 60 > rate-watch.jsonl
```

0.25秒ごとのスナップショット比較であり、その間の短い変化を全て捕捉する保証や変更元processを断定する機能はない。AntelopeはUSB動作でPC/DAWの指定に追従することを説明しているが、この環境の変更元はまだ未特定。[メーカー説明](https://testsupport.antelopeaudio.com/en/support/solutions/articles/42000017543-what-does-it-mean-when-the-clock-source-changes-to-usb-)

RMEとDiscrete4間のデジタル配線を外すときは、再生を止め、Discrete4が外部ADAT等のクロックに依存しない設定と48 kHz動作を確認してから外す。MacへのUSBとRMEから最終出力先への接続は残す。配線撤去がソフト内の循環検査の代わりになるわけではない。

16/32/64 framesの短時間実機比較は [試験記録](measurements/2026-09-28-initial-app/README.md) を参照。I/O16/FIFO32とI/O32/FIFO32は全muteで60秒成功したが、I/O16/FIFO16やI/O64/FIFO64には不足を観測した。設定候補にあることは安定性保証ではない。
