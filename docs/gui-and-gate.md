# ミキサーUIとチャンネルGate

更新日: 2026-09-28。初期設計後の実装差分。操作方法は[検証ガイド](validation-guide.md#gateの使い方)、試験結果は[測定記録](measurements/2026-09-28-gui-gate/README.md)を参照。

## GUI

メインのOFF/ONはSwiftUIを維持し、設定のミキサーはAppKitのNSTableView/NSSliderで実装する。チャンネル数が変わった時だけ行構造を再構築し、通常は可視行を再利用する。画面外で保持された行も、スクロールで再表示される際に最新設定へ同期する。

音声レベル・カウンターは設定モデルから分離する。メーターは固定サイズのC構造体をcontrol queueで33 ms間隔に読み、AppKitがキャッシュを30 Hzで描く。メーターの変化でSwiftUIの設定ツリーやフェーダーを再生成しない。音声callbackはメーター描画・UI操作を待たない。詳細な状態検査は別に200 ms間隔で実施し、停止・fault後はタイマーを停止する。

設定タブは選択中のページだけをマウントする。保存は350 msのdebounce後に専用queueでJSON化してatomic writeする。フェーダー操作ごとのメインスレッド上のJSON生成を避ける。

## Gateの信号順序

```text
RME入力/PC出力 → チャンネルGate → gain/pan/Mute → 2mix → FIFO/ASRC → D4
D4処理後USB入力 → 左右Gate → FIFO/ASRC → Return gain/Mute → RME選択出力
```

各Gateの設定はON/OFF、Threshold、Attack、Hold、Release、Hysteresis。既定値はON、−60 dBFS、0.2 ms、50 ms、30 ms、6 dB。旧設定にGateがない場合もこの値を補完し、既存の経路・gain/pan/Muteは保持する。

絶対振幅を検出し、AttackとReleaseで利得をランプさせる。閉鎖完了時のGate出力は厳密な0。先読みバッファや新しいFIFOを追加しないため、Gateによる輸送遅延は追加しない。ただしAttackは立ち上がりを、Hold/Releaseは消音までの時間を変える。FIFO/SRC内に既に入った音は通常どおり排出される。

ステレオLink時は左右の大きい方を検出し、共通のGate利得を掛ける。どちらの行から編集しても両方へ同じ設定を保存する。Link構造の変更はOFF時のみ。設定ファイルの左右不一致は明示的に拒否する。

Gate commandは一つのatomic値として公開し、callbackの先頭で読み込む。envelope状態はproducer callbackのみが所有し、callback内で割当・mutex・UI通知を行わない。各チャンネルの入力peakとGate利得を別々に診断する。

## 時刻不連続とGateエラーの区別

`fault 6`はsampleTimeの飛び・hostTimeの非増加・非有限な時刻情報を検出した停止であり、Gateのしきい値検査とは別。Gateの演算より先に時刻を検査する。音声callbackの処理時間が短くても、OSから届くcallback自体が遅れると時刻飛びが起こり得る。

時刻飛びを単に無視すると、FIFOとASRCの時間軸が一致しない音声を転送し続ける。そのため判定を緩めず、最初の不連続の経路・理由・前後の時刻を保存して出力を止める。再開はOFF状態から明示的にONにする。Gateの負荷評価はGUI自動読み取りや外部プロファイラーの影響を分けて比較する。
