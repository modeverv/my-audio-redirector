# 実信号による遅延測定 — 2026-09-28

48 kHz・I/O 64 frames・各FIFO 64 frames・Fastest SRC・Gate ONの保存済み設定で、実際のPC往路とDiscrete4のミックスからの復路を2回測定した。

**PC Tapの取得地点からDiscrete4出力バッファまで約6.9〜7.3 ms、Discrete4戻り入力バッファからRME出力バッファまで約6.6〜7.6 ms。Discrete4のミックスを通した全体は約14.8〜15.3 msだった。** これは各試行の中央値の範囲であり、長時間運転の上限保証ではない。

## 測定値

以下は対応する音声フレームにCore Audioが付けた共通host timestampの差。実端子のADC/DACを外部測定した値ではない。L/Rは個別解析し、表は左右でほぼ一致する値を丸めた。

| 区間 | 試行1の中央値 | 試行2の中央値 | 48 kHz換算（試行1 / 2） |
| --- | ---: | ---: | ---: |
| RME PC出力1/2のTap入力 → D4 Computer Play 1/2への出力バッファ | 6.89 ms | 7.28 ms | 約331 / 349 frames |
| D4出力バッファ → D4の処理後USB入力7/8 | 0.85 ms | 0.87 ms | 約41 / 42 frames |
| D4入力7/8 → RME host出力9/10 | 7.55 ms | 6.60 ms | 約363 / 317 frames |
| PC Tap入力 → D4のミックスを経由 → RME host出力9/10（直接相関） | 15.29〜15.30 ms | 14.76 ms | 約734 / 708 frames |

試行ごとにエンジンを開始し直した。往路・復路それぞれの遅延は、独立する機器callbackの位相と実際のFIFO/SRC内保有量にも依存する。64-frameという設定だけで固定されない。各段の中央値合計は試行1約15.30 ms、試行2約14.75 msで、直接相関した全体値と約0.01 ms以内で一致した。ただし中央値の加算が一般に厳密な合成測定になるわけではない。

ソフトウェアが受け取ってから送り出すまでを別の定義で見るため、同じ音声に対応する**入力callback入口→出力callback入口**の時刻差も計算した。

| callback間の受け渡し | 試行1 | 試行2 |
| --- | ---: | ---: |
| PC Tap → D4 | 約2.46 ms | 約2.85 ms |
| D4戻り入力 → RME | 約2.87 ms | 約1.92 ms |

これはアプリへの配送後のFIFO/SRC待ち・callback位相を含む指標で、実端子の再生時刻ではない。出力callbackの入口と実際のコピー完了にも数µs〜数十µsの差がある。上の約7 msと、この約2〜3 msは異なる測定端点の値であり、足し合わせない。

**64 frames = 1.333 msはI/Oの1周期**。FIFO64＋Fastest先読み20=1.75 msという設計上の部分予算も、全経路の実遅延ではない。今回の実測値にこれらやドライバーのlatencyプロパティを再加算していない。

## 実経路と試験条件

- RME Fireface UCX IIとDiscrete4 USB、どちらも48 kHz。機器間デジタルケーブルなし。
- 別プロセスのAudioQueueからRME UIDを直接指定し、host 1/2へ左右独立の非周期試験音を出力。システム既定出力は変更していない。
- My RedirectorはRME出力stream 0の20ch Tapを使用。自プロセス除外を維持。PC 1/2のみunmute、gain 0 dB、左右pan。
- RME物理入力はすべてMute。今回、RMEの物理入力から始まる経路は測定していない。
- D4 Computer Play 1/2 → 使用中のMonitor/HP1ミックス → USB Record 7/8 → アプリ復路 → RME host 9/10。
- D4の既存ミックス/FXを変更せず測定。戻りに他の成分が混在し得る。相関だけでその音源までは特定していない。
- I/O 64、RME/PC/Return各FIFO 64、SRC Fastest、Gate ON（使用中のPC/Returnは−60 dBFS、attack 0.2 ms）。保存済み設定は変更していない。
- 試行1はピーク−42 dBFS、試行2は−36 dBFS。150 Hz〜8 kHzの擬似雑音、左右別系列、14秒、20 ms fade。RMSはそれぞれ約−56 / −50 dBFS。
- running確認後2秒待ってから約4秒記録。入力はGate前、出力は実際にHAL AudioBufferListへコピーした値。記録は停止前にdisarmし、JSON化・解析は音声I/O停止後。
- 実callback長はRME/D4/PC Tapすべて64。別プロセスのinventoryやinjectorが記録した512という値を、このエンジンの実callback長と取り違えない。実際の長さは各runの `beforeStop.ioTiming` で確認できる。

## 相関の信頼性と限界

0.3秒の窓ごとに、block先頭のhost timestampと各streamの実rate推定を使って共通時刻軸へ対応づける。機器ごとに原点の違うsampleTime同士を直接引かない。探索0〜100 ms、相関係数0.8以上、別ピークとの差0.15以上、遅延＋gain適合後の信号/残差比3 dB以上、各ch最低3窓という基準で採択した。

| 区間 | 試行1 採択 L/R | 試行2 採択 L/R |
| --- | ---: | ---: |
| PC → D4 | 13/13、13/13 | 12/12、12/12 |
| D4出力 → D4戻り | 4/13、5/13 | 5/12、5/12 |
| D4戻り → RME | 13/13、13/13 | 12/12、12/12 |
| PC → 全体 → RME | 3/13、4/13 | 5/12、5/12 |

往路と復路のソフトウェア区間は全窓で成立した。D4のミックスをまたぐ区間は、**波形対応が明確だった区間の主たる一致成分**についての値。採択できなかった窓もJSONに残し、除外した窓を安定性の成功へ読み替えていない。全体の試行2は左右とも採択窓の相関が約0.90以上だった。

2試行ともfault、underrun、overflow、non-finite、clipは0。timestamp連続性・有効bit・PCMの有限性・記録容量を確認し、停止時のTap/一時Aggregateの解放も成功した。試行1の最大callback処理時間はRME約34 µs、D4約13 µs、PC Tap約16 µs。これは遅延のms単位の待ちとは別のCPU処理時間である。

**測定後の通常GUI運転では別途PC FIFO不足が再発した。** 最初は約9,984,704入力frames（48 kHz換算約208秒）の時点でfault 3、PC underrun=1、PC FIFO=0。RME/Returnの不足は0、clip/non-finiteは0だった。[停止時の診断](gui-after-measurement-pc-underrun.json)を保存し、同じ設定で再開後にもfault 3の通知を確認した。4秒の計測成功を、64/Q64の長時間安定性の証明には使えない。この停止の原因切り分け・修正は今回の遅延計測では完了していない。

復旧時はGUIを測定前の実行バイナリへ戻し、設定も測定前のまま再開した。復元したバイナリのSHA-256は `5bf847bd3721e231de308b7976017382d9f66d78c0651f488cb16bf3c2a79d15` で保存コピーと一致。測定機能のコード・ビルドは残してある。計測追加前後でRealtimeCoreの変更はなく、通常GUIでは記録領域を確保せずポインタ確認で終了するため、追加コードが直接の原因と確認できたわけではない。過去にも64/Q64のPC不足があり、復元だけで長時間安定を保証しない。

この試験では以下は測れていない。

- Spotify等の生成・内部バッファからPC Tap取得地点まで。
- RMEのADCを含む物理入力→D4の経路。
- D4 Monitorアナログ端子のDAC、RME出力後のTotalMix/物理AES・S/PDIF・DAC、スピーカーまで。
- Gateが閉じた状態から開くときの検出/attack、およびFXのすべての反射・tailの先頭。

「音の頭」は最初の非ゼロsampleではなく、相関の主ピークとして測っている。フィルターやFXで波形が変わるため、物理的な立ち上がり検出と同一ではない。D4 Monitor端子まで測るには、その出力を空きline入力へ戻す等の外部ループ測定が別途必要になる。

## 保存した証跡

- [試行1](run-01.json)、[試行2](run-02.json)：設定、停止前後のhealth、実callback長、試験音再生結果、全解析窓、raw captureのSHA-256。
- PCMを含むraw JSONと試験WAVはローカルの `.build/latency-measurement/` に保存し、Git対象にはしていない。
- 保存設定は測定前後でbyte一致。SHA-256: `24839067031f48af16af0d26a210ea649f22895222982bd0ad40e903e64ca718`。
- 測定後の再開で上記停止があったため、最終的に測定前のGUIバイナリへ復元した。再提示されたmacOS音声入力許可をユーザーが承認し、メイン画面のON/runningを確認した。復元後の長時間連続運転は今回の検証範囲外。

## 再実行

GUIをOFFにして終了し、他のMy Redirectorエンジンを同時起動しない。試験音は別PIDで再生する必要がある。ルーター内から再生すると自プロセス除外によりTapへ入らない。

```sh
scripts/build-app.sh release
swiftc -O scripts/play-latency-signal.swift -o .build/play-latency-signal
python3 scripts/analyze-latency.py --generate-wav .build/probe.wav --duration 14 --level-dbfs -36
```

1つのターミナルで、指定したRME UIDのhost 1/2へ再生する。

```sh
.build/play-latency-signal --device-uid RMEUSBDevice-130-24100500 --wav .build/probe.wav --seconds 14
```

再生開始後すぐ別ターミナルで以下を実行する。保存設定をそのまま鳴らす計測なので、出力経路・音量を確認してから使う。

```sh
"dist/My Redirector.app/Contents/MacOS/MyRedirector" \
  --measure-latency "$HOME/Library/Application Support/My Redirector/configuration.json" \
  --output .build/capture.json --seconds 4

python3 scripts/analyze-latency.py .build/capture.json \
  --pair pc_tap:d4_output --pair d4_output:d4_return \
  --pair d4_return:rme_output --pair pc_tap:rme_output \
  --output .build/analysis.json
```

CLIの収録成功と、解析の相関成立は別の判定。失敗/未測定のJSONも保持する。解析専用の合成テスト12件（分数遅延、独立クロック、左右差、逆極性、混入音、曖昧な信号、異常timestamp、fault/容量チェック、探索上限ピーク拒否と真のゼロ遅延等）は以下で実行する。

```sh
python3 -m unittest discover -s Tests/LatencyAnalysisTests -v
```

APIの端点定義はAppleの[AudioDeviceIOProc](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc)、device/stream Tapは[CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription/initexcludingprocesses:anddeviceuid:withstream:)を参照。物理端子の遅延を保証するAPIとして扱っていない。
