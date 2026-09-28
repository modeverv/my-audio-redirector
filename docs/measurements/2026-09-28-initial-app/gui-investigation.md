# 設定画面の応答停止の調査

2026-09-28。ユーザーはSettingsが正常描画される一方、ボタン操作でレインボーカーソルとなり約10秒待つと報告。初めはGUI操作ツールだけの障害と考えたが、アプリ側の応答問題として再調査した。

- メイン画面のAX読み取り、メニュー開閉は成功。
- Settingsを動作タブで開く操作＋AX読み取りは1.18秒、入出力タブは1.56秒で成功。
- ミックスタブのクリック＋AX読み取りは10.92秒後に `Sky Computer Use native pipe closed before response` で失敗。ツール往復時間であり、純粋な描画時間ではない。
- 操作後のプロセス観測はCPU49.5%、RSS約814MiB。後続sampleではphysical footprint124.6MiB、peak1.0GiB、main threadは待機に戻った。永続hangや音声I/O待ちとは判定していない。
- 操作に重ねた15秒sampleの途中に、main threadのSwiftUI `sizeThatFits`、`StackLayout`、`ScrollView`、`LayoutProxy.dimensions`が深く繰り返される処理を確認。全チャンネルをネストしたVStackで構築するレイアウトを改善候補とした。

raw sample（約13MiB）を[gzip圧縮して保存](gui-layout-sample.txt.gz)。この記録に結論と再確認結果を残す。

## レイアウト修正と再確認

40行を入れ子のGroupBox/VStackで一括配置していた部分を、単一LazyVStackのSectionと32pt固定行へ変更した。gain slider幅は145ptとし、dividerは行overlayへ移した。設定値・音声処理は変更していない。Releaseをビルドして署名済みappを再起動した。

- ミックスタブでSettingsを開く操作＋AX取得は3.815秒で成功。
- 入出力への切替は1.618秒、入出力→ミックスは3.716秒で成功。これはUI操作ツールの待ちと全AX列挙を含む往復時間で、描画単体のレイテンシーではない。
- ミックスのスクリーンショットも取得でき、表示中のRME入力・gain・mute・pan・linkが描画されていることを確認。ユーザーが設定した入力1 gain 1.2dBも保持した。
- 一方、ツールの `AXScrollToBottom` は1.57秒でnative pipe切断となり、その後の画面取得も失敗した。直後のapp CPUは0%、RSS約526MiB。最初の10秒のレイアウト停止とは分け、通常スクロールの操作感をユーザーへ確認中。全GUI確認済みとはしない。
