# Discrete4 Monitor mix の USB 復路設定

後続のユーザー確認: 「送り出しと戻しが動作した」との報告を受け、ここまでを動作確認済みの区切りとしてコミットする。個別FX、物理出力ごとの対応、遅延や連続運転の定量試験まで合格したという意味ではない。GUI設定、特にミキサーの操作が緩慢との報告は、次の改善対象とする。

記録日: 2026-09-28。ユーザーから往路の動作確認後、Discrete4 の Master mix が RME に戻らないとの申告があった。初代 Discrete4 の内部 routing とアプリの復路入力を合わせ、**Monitor/HP1のmix後信号がUSB 7/8を経由してRME Software Playback 9/10へ戻ることを、ミキサー消音・復元へのメーター追従で確認した**。聴感、名前を特定したFXの比較、最終物理出力、長時間運転は未検証。以下は今回の実機操作・画面観測の記録であり、他の世代や firmware の動作を保証するものではない。

## 変更前に確認したこと

- Control Panel は初代 `DISCRETE4` の表示で、Synergy Core のロゴはなかった。Core Audio は `Discrete4 USB`、16入力・16出力。
- アプリの往路は Computer Play 1/2。RME INPUT は全Mute、PC OUTPUT 1/2 が有効だった。
- アプリ復路は Discrete4 USB入力1/2を選んでいたが、Control Panel の DAW Record 1/2 は PREAMP 1/2 で、目的の Monitor mix ではなかった。
- DAW Record 5/6 は COMPUTER PLAY 1/2 で、Play 側に信号が見えた。一方、Monitor/HP1 の該当ミキサースロット5/6は−90 dB・Mute有効だった。
- RME復路は Software Playback 9/10（SPDIFの表示）、RETURN gain 0 dB・Mute解除。Hardware Outまでの実音確認とは分けて扱う。

初代のDAWソース表示に対する通常クリック・ダブルクリック・右クリックではメニューが開かなかった。Settings、SAVE、タブ切替は動作した。この結果だけで Loopback 非対応やアプリ全体の操作不能とは判定しなかった。

## バックアップと変更方法

転送停止後に、Discrete4 の通常の **SAVE AS** で現状プリセットを保存した。変更前のアプリ設定・プリセットと、後述の修正後プリセットの恒久バックアップは、ユーザーの次のローカルディレクトリにある。

```text
~/Library/Application Support/My Redirector/backups/2026-09-28-return-fix/
  configuration-before.json
  configuration-after.json
  discrete4-before-return-fix.as
  discrete4-after-return-fix.as
  discrete4-master-return-7-8.as
```

`discrete4-after-return-fix.as` は、後続の消音反応試験を始める前にControl PanelのSAVE ASで保存した、修正後の全50成分のプリセット。JSONを読み取り、Record 7/8=`MIXER_OUT0CH1/2`、Monitor/HP1のComputer Playスロット5/6=0 dB・Mute解除・Solo解除、Loopbackスロット7/8=−90 dB・Mute有効・Solo解除を確認した。変更前へ戻すバックアップとは別に、復路設定後の状態を復元するためのもの。これもリポジトリへコピーしていない。

`discrete4-master-return-7-8.as` は、Routingと4つのMixerの成分を含む復路設定プリセットの恒久保存分。消音反応試験の終了時には、このファイルを通常LOADして運用候補の設定へ戻した。

`configuration-after.json` も最終の保存設定から同じ恒久バックアップ先へコピーした。変更前・変更後のアプリ設定を区別して保管している。

保存された JSON 形式のプリセット内には、`LOOPBACK HP1/MON` に対応する `MIXER_OUT0CH1` / `MIXER_OUT0CH2` が存在した。そこで元のプリセットを基準に下表の箇所だけを変更した候補を作り、Control Panel の通常の **LOAD** から Routing と4つの Mixer 成分を読み込んだ。独自の機器制御APIや非公開コマンドによる書込みは行っていない。

表のslot番号は画面と同じ1始まり。プリセット内のキー番号をそのまま表したものではない。

| 変更対象 | 変更前 | 読み込んだ候補 |
| --- | --- | --- |
| `COM_REC` のslot7/8 | 未使用のS/PDIF入力ペア | `MIXER_OUT0CH1` / `MIXER_OUT0CH2` |
| 4つすべての `MIXER_IN` のslot7/8 | 同上 | 同じMonitor/HP1 LoopbackのL/R |
| 4つすべてのMixerのslot7/8 | 元のミキサー設定 | Mute=1。Loopbackをミキサー自身へ再投入せず、他のヘッドフォンmixにも出さない |
| Monitor/HP1（mixer0）のslot5/6 | COMPUTER PLAY 1/2、−90 dB、Mute=1 | ソースは維持し、level=0 dB、Mute=0 |
| My Redirector のDiscrete4復路入力 | USB 1/2 | USB 7/8。保存上のチャンネル名も `7` / `8` |

PREAMP 1/2のFX、上表以外のrouting、RME復路9/10、RETURN gain 0 dB・Mute解除は維持した。slot7/8は、その時点で未使用だったS/PDIF入力枠を置き換えたもので、他の環境に共通する空き枠ではない。

途中の `COM_REC` だけを変えるrouting-only試行では、DAWラベルは変更前のままだった。その試行を完成扱いにせず、元のプリセットを基準に作り直し、共有ソース枠の `MIXER_IN` と `COM_REC` を揃えた最終候補で確認した。

今回の作業用ファイルは次の場所にある。ユーザーのプリセット全体・設定全体は、このリポジトリへコピーしていない。

```text
/tmp/my-redirector-return-fix/discrete4-master-return-7-8.as
/tmp/my-redirector-return-fix/configuration-after.json
```

## 確認状況

| 確認項目 | 状態と根拠 |
| --- | --- |
| 候補プリセットの通常LOAD | 実施済み。Routingと4つのMixer成分を選択して読み込み |
| DAW Record 7/8 のソース表示 | CUAで `LOOPBACK HP1/MON 1` / `LOOPBACK HP1/MON 2` の実表示を確認 |
| Monitor/HP1 のComputer Play 1/2 | CUAで0 dB・Mute解除を確認 |
| Monitor/HP1 のLoopbackスロット | CUAで−90 dB・Mute有効を確認。他の3 Mixerは候補プリセットでMute=1を指定した範囲であり、全画面の実表示を確認したとはしない |
| アプリ復路設定 | 保存設定をUSB 7/8へ更新。RME復路9/10を維持 |
| RETURN表示の修正 | RETURNメーター表示修正を含む新版アプリのビルド済み。表示修正自体を音声到着の証拠とはしない |
| 別途の全Mute起動・停止試験 | 5秒のCLI試験で停止前の復路under/overflow=0、fault=0。停止後`cleanup.confirmed=true` |
| Monitor/HP1 mix → USB 7/8 → RME Playback 9/10 | **実信号で確認**。下記のミキサー消音・復元にRME復路メーターが追従 |
| 目的の物理出力への到着・聴感 | **未検証**。Software Playbackメーターの確認と区別する |
| 左右対応、RETURN gain/Mute | **保留** |
| Monitor mix後の取得 | **確認**。元PCの信号が続く状態で、Monitor mix全入力消音により復路だけがUFLになった |
| 個別フェーダー・GUI Solo/Mute・名前付きFXの反映 | **未検証**。GUI Solo/Mute単独操作のDSP追従は曖昧だったため、成功扱いにしない |
| Monitor主音量・DIM・Mute・AuraVerbとの取得位置 | **未確認** |
| 循環・二重再生・連続運転・実遅延 | **未確認** |

## ミキサー消音・復元による実信号確認

アプリをONにすると、RME Software PlaybackのSPDIF 9/10左右に約−40 dBの信号が見えた。そこからMonitor Mixer#0だけを変える一時プリセットを通常LOADした。プリセット内の全32入力枠を`level=90`（−90 dB）、`mute=1`、`solo=0`としたもので、他のMixerとRoutingはこの試験で変更していない。

| 操作・状態 | RMEで観測した結果 |
| --- | --- |
| Monitor Mixer#0の全入力を消音 | Software Playback SPDIF 9/10が−52.7 / −52.9 dBへ減衰後、左右ともUFLに到達 |
| 同じ消音区間の元PC音声 | Software Playback Analog 1/2は約−44 dBで継続。元音源の停止による復路消音ではなかった |
| 恒久バックアップの`discrete4-master-return-7-8.as`を通常LOAD | SPDIF 9/10が−41.5 / −41.3 dBへ復帰 |

この追従から、設定した復路がComputer Playの直接コピーだけではなく、Monitor/HP1のmix結果を取得していることを確認した。試験後はSoloをすべて解除した状態を確認し、Monitor/HP1のPCスロット5/6を0 dB・Mute解除へ復元した。Loopbackスロット7/8はMuteを維持した。

作業終了時は通常設定へ戻し、GUIのメイン画面がrunningであることを確認した。上記5秒のCLI試験は正常起動・停止の追加確認であり、現在のGUI運転の長時間安定性を示すものではない。

GUIでのSolo/Mute単独操作はDSPへの追従が曖昧だったため、この合格根拠には使わない。また、上の数値はその時点のメーター観測値で、録音波形や校正済みの音圧測定ではない。左右別の信号、アプリRETURNのgain/Mute、名前を特定したFXのbypass比較、耳で聞く試験、最終物理出力、循環・二重再生、長時間安定性は別途確認する。Monitor主音量・DIM・Mute・AuraVerbとの厳密な取得位置も、この試験では確定しない。

## 復元と資料の扱い

戻す場合は転送を停止し、恒久バックアップの `.as` をControl Panelから読み込んで、今回変更したRoutingと4つのMixerを復元する。アプリ側も停止・終了した状態で変更前の設定へ戻し、再起動後に復路入力番号とMuteを照合する。アプリ設定だけをUSB 1/2へ戻しても、Discrete4内部routingは復元されない。

メーカーの [Loopback手順](https://support.antelopeaudio.com/en/support/solutions/articles/42000096671-how-to-use-loopback-with-discrete-and-zen-go-q-interfaces) と [ストリーミング設定](https://support.antelopeaudio.com/en/support/solutions/articles/42000099254-using-antelope-interfaces-with-streamer-software) を調査の手掛かりにしたが、資料の世代差と今回のGUI操作結果があるため、上記の実表示・実音確認を優先する。初代の共有ソース枠については [初代日本語マニュアル §6.2.8](https://jp.antelopeaudio.com/support/user-manuals/discrete-4/) も参照した。

通常の検証手順は [検証ガイド](../../validation-guide.md) を参照。
