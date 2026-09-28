# PC FIFO不足時の継続運転

2026-09-28。PC側のFIFO不足で全経路を停止していた動作を変更した。FIFO設定値は変えず、不足したPC出力block・公開済みPC FIFO・SRCの残留信号を破棄し、PC成分だけ再同期する。

## 動作

- 不足時のPC成分は直前の最終sampleから48 frames（48 kHzで1 ms）かけてゼロへ移行する。部分的に生成できた古いblockを繰り返し再生しない。
- 16/32 framesでもfade-outを途中で打ち切らない。指定FIFO量とSRC先読みが揃うまでPC成分のみ無音にする。
- 復帰時は最新側の必要windowを残して余剰を破棄し、48 framesでfade-inする。通常時のバッファ値・SRC品質・Gate設定はそのまま。
- RME入力のミックスとDiscrete4からRMEへの復路は継続。初回起動の全経路primeは従来どおり。
- RME/Return不足、overflow、非有限値、converter error、時刻不連続、機器切断やcallback timeoutは停止対象のまま。

不足時のresetとread位置の変更はPC FIFOのconsumerであるD4 callbackだけが行う。producerのwrite位置や時計・Gateには触れない。既にmix中で未公開のproducer blockは、破棄の境界後に到着する可能性がある。破棄frame統計は公開済みFIFO分であり、SRC内部履歴の全量ではない。

## ログ

`~/Library/Logs/My Redirector/events.jsonl` にJSONを1行ずつ保存する。`session_start`、`session_started`、`pc_recovery_summary`、`session_end` を記録する。音声PCMは保存しない。

`pc_recovery_summary.recovery` はrunごとの累計、`delta` は前回queue投入時からの差分。`count` は不足episode数、`completed` は再prime後に完全なblockを生成できた回数、`discardedInputFrames` はFIFO破棄量、`replacedOutputFrames` はfade-out/無音へ置換したPC出力frame数。復帰fade-inは置換frame数に含めない。`observedAt` は制御側で観測した時刻で、問題sampleそのものの時刻ではない。

ログは最大1秒ごとに集約し、停止時に未報告分も保存する。音声callbackはatomic統計の更新だけを行い、JSON化・書込み・ローテーションは別のutility queueで行う。queueは最大32件、ファイルは2 MiB×現行1本＋過去3本。保存失敗時も音声は継続し、診断JSONの `eventLog.error` / `writeFailures` / `droppedRecords` に残す。読戻し確認は電源断への耐久性保証ではない。

## オフライン検証

- 16/32/64 frames × Fastest/Mediumの6条件で、各100回のPC不足・復旧を実行。RME/Return継続、旧音声の非再生、新markerの復帰、破棄・置換counterを検証。
- 不足直後にPC入力を大量供給しても1 ms fade-outを完遂すること、復帰直後・fade-in途中の再不足を確認。
- 初回prime、NaN、overflow、PC/出力timestamp異常、他経路の不足という既存の停止条件を維持。
- producer、consumer、設定変更、snapshotの並行動作と、RT内C++ allocation 0を確認。SRC resetのC実装も確認し、既存領域の初期化のみで割当て・ロックなし。
- 全Release suiteと既存の正常クロックsimulation（underrun 0）が成功。最終追加ケースを含むPC復旧専用試験と並行試験はASan＋UBSanでも成功。
- 実Bridgeを使う合成ログ試験で、差分集約・停止時flush・snapshot・readback・4ファイルrotate・書込失敗・エラー履歴保持・別writerとのlock競合を確認。音声デバイスは開いていない。

不足を検出したD4 render（SRC resetを含む）のオフライン計測では、6条件の観測最大は約2.9〜22.9 µsだった。16 framesの周期333 µsに対して短いが、通常thread上の各100回の結果であり、実時間処理の最大値保証ではない。

証跡: [PC復旧Release](core-recovery-tests.txt)、[全Release](full-core-tests.txt)、[PC復旧ASan/UBSan](core-recovery-asan-ubsan.txt)、[並行ASan/UBSan](concurrency-asan-ubsan.txt)、[ログ機能](event-log-tests.txt)。

## 実機検証

署名済みReleaseアプリで48 kHz・I/O 64 frames・各FIFO 64 frames・Fastestの全Mute経路を60秒間実行した。全producerが進行し、RME/PC/Returnとも不足・超過0、fault 0、`lossFree: true`、停止後のTap・Aggregate回収も成功した。実callback内の観測最大処理時間はRME 33.42 µs、Discrete4 22.17 µs、PC Tap 11.08 µs。全Mute試験は経路の稼働確認であり、実音や信号内容の検証ではない。

`session_start`・`session_started`・`session_end` は実ログへの保存とreadback成功を確認した。この60秒間には自然発生のPC不足はなく、復帰回数は0。不足時の挙動は上記の注入試験で別途検証している。証跡: [実機60秒JSON](muted-route-64-60s.json)。

さらに新版GUIを保存済みの通常設定で約4分18秒間ONにした。終了前もメイン画面は `running`、手動OFF後のログは `fault: 0`、PC復帰回数0、Tap/Aggregate非稼働、`unsafeTeardown: false` だった。自然発生の不足はこの間も観測していない。元の設定ファイルはbyte単位で一致し、作業前と同じOFF状態へ戻した。これはGUI稼働の確認で、試験信号による実音の往復測定は今回は行っていない。証跡: [実機イベントログ](hardware-events.jsonl)。

## 再現コマンド

```sh
scripts/test.sh
.build/release/CoreTests --pc-recovery-only
scripts/test-event-log.sh
```

実機の全Mute試験では、回復によってONを維持しても欠落を成功扱いしない。`--check-muted-route` は運転を指定時間続け、最後に `lossFree` がfalseなら検証結果を失敗とする。これは通常アプリの停止条件とは別である。
