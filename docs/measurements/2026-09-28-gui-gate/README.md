# GUI変更・Gate追加の検証

2026-09-28、Apple Silicon / macOS 26.7、Fireface UCX II + Discrete4 USB。往復動作確認までの保存点は `b4ef283`。

## 実装・回帰

- AppKitの再利用行・ネイティブフェーダーへ変更。設定とメーターの更新を分離し、可視行のみ30 Hzでメーター描画。JSON保存を350 ms debounce後の専用queueへ移動。
- RME 20ch + PC 20ch + Return 2chへGateを追加。チャンネル数は実機の列挙結果であり固定しない。
- release buildと `--self-test-config` 成功。旧設定の互換、リンクした左右の一致、Swift→C JSON境界の最小Attack 0.1 msを含む全範囲、Cメーター配列の配置を確認。
- [CoreTests](core-tests.txt) 全成功。16/32/64frameのGate連続性、正確な閉鎖0、stereo detector、before-gain、live設定、長いRelease、並行制御、RT内C++ allocation guardを含む。
- [Gate ASan](gate-asan-tests.txt)、[時計診断ASan](clock-diagnostics-asan.txt) 成功。時計の5 trackerと3理由、最初の失敗記録の固定、同時failure/snapshotも試験。

## GUI

ユーザーの手動試用で「軽快にはなった」との報告を得た。Gate詳細・変更値・PC OUTPUT・Return左右もGUIで確認した。

ミキサー待機中の `ps` でCPU約0.3%、3秒のmain thread sampleで2570中2553回はrun loopの待機経路だった。これはOFF時の待機測定で、ドラッグのフレーム時間やTotalMixとの同条件比較ではない。

自動操作はAXの全行・全コントロール読取を含み、ミキサーを読むだけで約13〜33秒かかった。旧版とのクリック+AX往復時間の比較を、GUI自身の操作遅延改善率として使わない。新版の診断タブはAX取得に成功し、ミックスからの操作応答1051 ms + 診断AX取得467 msを観測した（自動操作系の時間を含む）。

## 音声I/OとGate負荷

初回は既存I/O64、FIFO64/64/64、Fastest、全42Gate ONで20秒間の全Mute実機試験が成功。全3producerが進み、不足/超過/clip/非有限値は0、出力peakは全て0、停止後tap/aggregate解放を確認。[要約](muted-route-64-summary.json)。短時間の成功は長時間安定・音声内容・実遅延の証明ではない。

[オフライン演算測定](gate-benchmark.txt) は20+20+2ch・各30000 callbacks。Gate ONの平均処理時間は16frameでRME/PC/D4 = 2.385/1.387/2.050 µs、32frameで4.870/2.892/4.069 µs。Gate OFFとの差は小さいが、USB・OSのcallback配信・実際の輸送遅延を含まない。

再現用:

```sh
swift build -c release --product CoreTests
.build/release/CoreTests --gate-only
.build/release/CoreTests --gate-benchmark
.build/release/MyRedirector --self-test-config
.build/release/MyRedirector --check-muted-route CONFIG --seconds 60 --stress-gates
```

最後のコマンドは全経路Muteを強制し、Gate enabledはCONFIGの値を維持して設定値だけを50 Hz目標で変更する。実測更新頻度・API回数・最大制御時間も出力する。元のprocess再生音は消さず、CONFIGファイルを書き換えない。GUIの転送は先にOFFにする。

GUIを終了し、外部sample/AX読取とビルド・オフライン試験を止めて、同じ64frame・FIFO64/64/64で比較した。

| Gate | 時間 | 実測更新頻度 | 設定API回数 | fault / 不足 / 超過 |
| --- | ---: | ---: | ---: | --- |
| 全42ch OFF | 60秒 | 42.08 Hz | 106,050 | 0 / 0 / 0 |
| 全42ch ON | 60秒 | 42.27 Hz | 106,554 | 0 / 0 / 0 |

両方とも出力peakは0、終了時にtap/aggregate解放を確認。50 Hzは制御の目標値で、status/HAL照会などを含むcontrol queueの実測は約42 Hzだった。[OFF記録](stress-gate-off-summary.json)、[ON記録](stress-gate-on-summary.json)。ON時の最大callback到着間隔はRME1431 µs・D4 1373 µs・PC1373 µsで、前述の同時数ms遅着は再現しなかった。

この試験ではGateの高速更新単独による停止は再現しない。GUI側や外部自動操作が関与する可能性を除外した意味ではなく、頻発報告の根本原因が確定・解消したとも扱わない。

## GUI試用中のfault 6

ユーザーからGate操作時の頻発報告があった。保存した診断では、約0.18秒分の音声処理後、RME・D4・Tapが同時に遅着し、次のcallbackのsampleTimeが飛んでいる。

| I/O | 飛ぶ直前の到着間隔 | 余分なsample進行 | callback内の最大処理時間 |
| --- | ---: | ---: | ---: |
| RME | 3560 µs | +112 frames | 17.5 µs |
| Discrete4 | 4305 µs | +148 frames | 12.0 µs |
| PC Tap | 4823 µs | +169 frames | 7.6 µs |

RME/D4は出力予定時刻を約400 µs過ぎていた。これはGate演算が数ms占有した証拠ではなく、callback配信の遅れを伴う時刻不連続の記録。GUI操作、AX自動読み取り、外部sampleプロファイラーが並行していたので、それらの影響をこの記録だけで分離できない。

Gateの異常値と時刻飛びを区別できるよう、最初のtracker・理由・前/期待/現在sampleTime・hostTimeを新たに保存し、エラー文にも経路と差分を表示する。先頭traceにはarmed/stoppingを追加。停止処理中の大きな時刻飛びを最初の原因と混同しない。時計判定を緩める変更は行わない。
