# 初期アプリの確認記録（2026-09-28）

## 環境と対象

Apple M4 Max / arm64、macOS 26.7、Swift 6.3.3、Clang 21。SwiftPMでSwiftUIアプリ、Core Audio HAL/Tap bridge、C++ core、libsamplerate 0.2.2をビルドした。ユーザーがRME↔Discrete4間のS/PDIF/ADAT全撤去、D4 Internal・48 kHz確認、両USBとRME最終出力の維持を報告。Discrete4のFX後USB割当は未確認。

## 完了した確認

- `scripts/test.sh`: 正式なvendored libsamplerateを使ったrelease buildと全offline testsが成功。結果: [core-tests.txt](core-tests.txt)。
- 60秒相当×28条件の独立クロックsimulation。16/32/64 frames、正負100 ppm、callback位相差、timestamp有無、Fastest/Mediumをケースごとに組み合わせた。全組み合わせの網羅ではない。Q32/B32を6条件で確認。Q32/B64は不足を再現し、期待どおりfaultで無音化。
- stereo routing、gain/master ramp、mute、非有限値、underflow/overflow、timestamp不連続、起動時backlogの初回だけのdiscard、最大64ch/4096frame、producer/consumer/control-snapshotの並行実行を確認。
- Release + AddressSanitizerで追加16-frame試験前の全22条件のoffline testsが成功。[core-tests-asan-release.txt](core-tests-asan-release.txt)。Debug + AddressSanitizerで旧並行fixtureが失敗した。起動時discard後の各FIFO実残量を共通callback数で誤って推定していたテストを修正し、Debug+ASan focused 20回連続成功。音声coreの変更は不要だった。[初回ログ](core-tests-asan.txt) / [修正後](concurrency-debug-asan.txt) / [原因](concurrency-investigation.md)
- C++ `new` のRT割当ガードを通過。C allocatorを含む全RT処理の完全な無割当保証とは区別する。
- 設定JSONのround-trip、初期mute、engine JSONからUI専用状態を除く処理、未知schemaの拒否を確認。[configuration-tests.txt](configuration-tests.txt)
- 読み取り専用の機器一覧を取得。[inventory.json](inventory.json)。RME20in/20out、D4 16in/16out、5.1chのstream 0は20ch、RME/D4とも48 kHz、I/O512。
- rate監視を30秒実行し、区間内で48→44.1変更なし。[rate-watch.jsonl](rate-watch.jsonl)。ユーザーの再発申告を否定する結果ではなく、変更元processも未特定。
- 署名したappを起動し、メインがOFF/ONボタンだけであること、⌘,で設定画面が開くことをUIで確認。RME/D4/PC 5.1chの選択とチャンネル表示を確認。全入力mute・復路muteのまま。

## 実機PC Tap取得（無音）

署名済みCLIで `--probe-config ... --seconds 10` を実行しexit 0。選択5.1ch stream 0、20ch interleaved Float32、48 kHz、I/O64。Tap-only private Aggregateで7508 callbacks / 480512 framesを取得し、fault/非有限値0。非mixdown・self-process除外をTap記述のreadbackで確認した。全peak0であり、再生停止中の取得処理の成立を示す。信号内容の取得許可・channel対応・自己出力非再取得の実信号試験は別途必要。RME/D4への本アプリからの出力は開始していない。

32 framesでも10秒で15013 callbacks / 480416 frames、fault 0を確認した。[32-frame結果](tap-probe-32.json)。これも無音取得の確認である。

[64-frame取得結果](tap-probe.json) / [標準エラー（空）](tap-probe-stderr.txt) / [終了後inventory](inventory-after-probe.json)

## 制約・次の実機確認

- 上記simulationは実時間の連続運転でも、実機の遅延測定でもない。8/24時間、100回ON/OFF、LadioCast比較は未実施。
- 現行版は1つのPC出力device/streamを取得する。複数独立PC stream/clock groupや仮想出力driverは未実装。
- FIFO目標は各経路の実source/destination I/O blockの最大以上が必要。小さすぎる値を黙って増やさず拒否する。32 samplesはI/Oも32で試す。
- Tapのnon-mixdown channel対応、self-process除外の実信号確認、Discrete4のFX後USB入力、TotalMixから目的の物理出力までの一致は未検証。
- 設定画面の途中でGUI操作ツールが `Sky Computer Use native pipe closed before response` となった。後にユーザーもミックスタブ切替で約10秒の応答停止を報告し、再現・レイアウト調査を行った。[経過・再確認](gui-investigation.md)。
- 物理clock source、sample rate、default output、TotalMixやDiscrete4内部routingをアプリから自動変更しない。

## 双方向開始時の不連続（修正前の記録）

最初の全mute試験はRME/D4/TapともI/O64で開けたが、開始途中にcore fault6で停止した。マイク権限はauthorized。停止でTap/Aggregate解放、48 kHz維持、RME/D4 I/O512への復元を確認した。

[初回fault](muted-route-64-initial-fault.json)、[timestamp trace付き再現](muted-route-64-trace.json) では、PC Tap callback156のsampleTime=9938からcallback157で-34へ戻った（通常なら10002）。hostSecondsは進行している。直後にRMEの最初のcallbackが到着した。Tapだけを先に開始し、背後のRMEを後から開始した順序による起動epoch変更と整合する。負のsampleTime自体は禁止しておらず、停止理由は差分の不連続。

## 開始順序修正後の64-frame双方向I/O（全mute）

RME→Discrete4→Tapの順に開始し、全start成功後にatomic armを公開する形にした。arm前はcallbackが出力zeroと時刻記録だけを行い、coreのpush/renderを呼ばない。起動中のepoch切替がFIFO/SRCへ入らず、coreのtimestamp連続性検査と初回5ms fadeは維持される。

修正後 `--check-muted-route ... --seconds 10` は成功。48 kHz、全I/O64、全FIFO目標64、Fastest、全sourceと復路mute。RME481792／PC481728／Return481728 frames、全FIFO underrun/overflow0、fault0、非有限値0、出力peak0、state running・primedMask7を確認。終了時Tap/Aggregate inactive、unsafeTeardown false、cleanup confirmed、RME/D4 I/O512復元・48 kHz維持。 [結果](muted-route-64.json)

開始9秒付近の単発ps表示はCPU0.5%、RSS22384 KiBだった。ただし全muteの短い1点観測であり、通常音声のCPU比較や最大負荷測定ではない。

## 32-frame双方向I/O（全mute・60秒）

I/O32／3経路FIFO32、48 kHz、Fastestで60秒の全muteチェックが成功。各producerが2882016 framesを処理し、全FIFO underrun/overflow0、fault0、出力peak0、全prime完了、停止後cleanup confirmed。FIFO min/maxはRME30/96、PC30/96、Return31/96。補正は最終時点RME -3.571 ppm／PC -3.570 ppm／Return +3.558 ppm。独立クロックでの短時間動作の確認であり、実音ルートや8/24時間安定性は未確認。 [結果](muted-route-32-60s.json)

## 64-frameの追加60秒試験（不足を検出）

同じI/O64/FIFO64の追加試験は開始から約37秒後にPC FIFO underrun1・fault3で停止した。RME/Returnのunderrunは0、PC最終FIFO0、ppm -27.62。起動timestamp問題とは別である。全出力zero・cleanup・I/O512復元は成功した。32-frameの先行60秒成功だけで常用設定の安定性を断定できず、callback配送のジッタ・位相と追従制御を切り分ける。[結果](muted-route-64-60s.json)

16-frame/FIFO16の±100ppm・3位相の6条件（各60秒）もofflineで成功。負のsampleTime原点からゼロをまたぐ試験（Fastest/Medium）と、その後のclock reset検出も追加した。正式release全suiteを再実行済み。[16-frame結果](core-16-frame-tests.txt)

## 16-frame I/Oの対応とFIFO16試験

HALが示すRME/D4のbuffer範囲は両方15〜3072 frames。[範囲のinventory](inventory-with-buffer-range.json)。実機へ16を要求し、RME/D4/Tapすべて読み戻し16、実callbackもmin=max16だった。

全FIFO16では約28.4秒の処理後にRME input underrun1 / fault3となり停止。各sourceは約136万framesまで進行。armed区間の最大callback間隔はRME422.3 µs／D4 370.3 µs／PC386.3 µs、最大処理時間は26.0／8.42／5.37 µs。16 framesの公称周期333.3 µsを超える到着間隔があり、処理量より小さい待ち量・位相・配送ジッタの余裕が課題と考えられる。ただし最大値だけで特定callbackの原因までは断定しない。全出力zero、cleanup・I/O512復元を確認。[結果](muted-route-16-60s.json)

## FIFOを分けた追加試験

- I/O16・全FIFO32: 60秒成功。RME/PC2882016・Return2882000 frames、全FIFO不足/あふれ0、fault0、出力peak0、cleanup成功。最大処理時間RME5.04 µs／D4 8.46 µs／PC4.33 µs。[結果](muted-route-16-q32-60s.json)
- I/O64・RME/Return FIFO64・PC FIFO128: 60秒成功。全source2881856 frames、全FIFO不足/あふれ0、fault0、出力peak0、cleanup成功。最大処理時間RME18.33 µs／D4 26.50 µs／PC7.58 µs。[結果](muted-route-64-pc128-60s.json)

いずれも一回の短時間・全mute試験であり、常用の安定性や実往復遅延の合格ではない。Qはrender後の平均占有目標で、常にQ frames以上を確保する意味ではない。I/O16の可否とFIFO16の安定性を区別し、待ちを増やした成功を『全遅延16 samples』とは扱わない。16-frameの追加6条件はRelease+ASanでもPASS。[結果](core-16-frame-tests-asan.txt)

## Discrete4パネルの読み取り

DAW画面でRecord1〜8はPREAMP1/2/3/4、COMPUTER PLAY1/2、SPDIF IN1/2の順に表示された。アプリ初期候補の復路入力1/2は現在PREAMP1/2であり、目的の処理後ステレオミックスとは確認できない。DAW表示への切替だけを行い、routing設定は変更していない。USB I/O動作中、Clock SourceはUSB・48.0 kHz・LOCKを表示した。ユーザーが先に選択したInternalと矛盾する故障とは断定せず、AntelopeのUSB動作中の追従仕様と併せて扱う。

## 最終の停止処理修正後の再確認

Property listenerを、engineへ参照しないrun固有signalsを保持するblockへ変更した。登録解除後に遅延通知が残っても解放済みengineや次のrunへ触れない構造にした。修正版でI/O16・全FIFO32を全muteで10秒再実行し、全producer進行、fault/不足/あふれ0、出力zero、cleanup confirmed、設定ファイル未変更を確認。[結果](muted-route-final-16-q32.json)
