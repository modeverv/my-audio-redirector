# my-redirector

RME Fireface UCX IIとAntelope Discrete4の間で、音声のミックスと転送を行うmacOSアプリの初期実装。

SwiftUI GUI、HAL／Tap取得backend、C++ミックス・FIFO・ASRC、設定保存、診断CLIを実装済み。Releaseビルド、オフラインcore試験（28条件×各60秒相当を含む）、設定テスト、機器列挙に成功した。GUIの起動、⌘,での設定表示、RME／Discrete4／PC取得元の選択も確認した。

**16/32 framesでの短時間の実機動作を確認しました。** 全mute試験の結果は次のとおりです。I/OサイズとFIFO待ち量は別設定です。

| I/O | FIFO RME / PC / 復路 | 結果 |
| --- | --- | --- |
| 16 | 16 / 16 / 16 | 約28秒でRME側不足、停止 |
| 16 | 32 / 32 / 32 | 60秒成功 |
| 32 | 32 / 32 / 32 | 60秒成功 |
| 64 | 64 / 64 / 64 | 10秒成功、追加試験は約37秒でPC側不足 |
| 64 | 64 / 128 / 64 | 60秒成功 |

全条件で停止後の資源解放・機器buffer復元を確認。PC Tap単独も20ch・48 kHz・32/64 framesで各10秒動作した。**処理後の実信号ルート・実遅延・長時間安定性は未検証。** D4の現在のDAW Record1/2はPREAMP1/2なので、目的の処理後ミックスをUSBへ割り当てられる経路を先に確認する。 [ビルドと使い方](docs/getting-started.md)、[これからの実機検証ガイド](docs/validation-guide.md)、[実機試験記録](docs/measurements/2026-09-28-initial-app/README.md)


## 主な機能と要件

- RMEの物理入力とPC再生出力を別々に取り込み、設定画面にチャンネルを一覧表示する。それぞれのgainを調整して2mixを作る。PC再生音にもRMEのLoopbackを使わない。
- ミックスをDiscrete4の **Computer Play 1/2** に送る。この入力先は必須。
- Discrete4内でミックス／エフェクト処理したステレオ音声を、設定で選んだRME出力チャンネルへ返す。AESは初期候補で、固定しない。
- 通常画面の操作は **OFF / ONの1個だけ**。入出力、ミックス量、クロック運用、診断は設定画面へまとめる。
- LadioCastに対する改善は、同条件の実測で判断する。
- 64 samplesを目標に小バッファを調整できる設定を用意する。I/Oサイズ、ソフト内の待ち量、実際の往復遅延は別に表示する。

## 実装した構成

**SwiftUI + Core Audio HAL + C++音声エンジン**。RMEの物理入力はHAL、PC音声は出力device/streamを指定したCore Audio Tapを初期backendとして実装した。PC出力のチャンネル構成を保持し、全体を先にstereoへ潰すTapは使わない。無音でも64-frame callbackが進むことを実機で確認した。実信号のchannel対応は今後確認する。[PC音声の取得設計](docs/computer-audio-capture.md)

**RMEとDiscrete4をまとめるAggregate Deviceは採用しない。** ユーザー環境では、両機器をAggregateにすると音声入出力がおかしくなる。一方、AppleのTap受信方式はAggregateを使うため、初期backendはPC音声の受信に限定したtap-only private Aggregateを作成する。2台の物理機器を結合せず、privateだから安定するとも仮定しない。実機でこの構成が成立しなければエラーにし、別構成へ自動切替しない。

最終形は両機器とMacのUSB接続だけで橋渡しし、**RMEとDiscrete4間のS/PDIF・ADAT・同期ケーブルを使わない**。復路はDiscrete4の処理済みミックスをUSBで取得し、設定で選んだRMEのhost出力L/Rへ送る。DAW Record Loopbackは候補であり、現在の機器で選べることとFX後の取り出し位置は未確認。物理端子への接続はTotalMixの経路と併せて確認する。RMEから最終出力先への接続は撤去対象に含まない。

独立した2台は同じ48 kHzでも少しずつクロックがずれる。FIFOだけでは長時間後に破綻するため、ASRCとバッファ量の制御が安定性の中心となる。この部分はオフライン試験を通過し、実機の短時間比較も実施した。次に実信号と長時間運転を検証する。

RMEの前段Loopbackペアを予約しない。PC音声はTotalMixのHardware Outサブミックスより前で取得する。復路のRMEチャンネルにかかわらず自分の出力をTapから除外し、往路への循環を防ぐ。隣接するmy-lan-audio2の小I/Oバッファ実装とSRC単体測定を、[遅延予算](docs/latency-budget.md)へまとめた。

RME入力とPC音声をそれぞれstereoへ混合し、Discrete4の時間軸へ合わせて最終2mixを作る。別受信経路になったため、初期設計はstereo FIFO・ASRCを3系統とする。チャンネルごとには増やさない。複雑さを採否の理由にせず、処理時間・音切れ・実遅延を検証する。[方式間の性能比較](docs/mixing-performance.md)

## 文書

| 文書 | 内容 |
| --- | --- |
| [ビルドと使い方](docs/getting-started.md) | 起動、設定、PC取得テスト、CLI、初期版の制限 |
| [使い方と実機検証ガイド](docs/validation-guide.md) | 全Mute起動、1chずつの経路確認、FX後復路、循環・二重再生、16/32 frames比較、長時間試験 |
| [アーキテクチャ](docs/architecture.md) | 方式選定、音声処理、GUI、状態管理、設定保存 |
| [PC音声の取得](docs/computer-audio-capture.md) | Loopback不要の多チャンネルTap、取得対象、自己音声除外、成立条件 |
| [64 samples目標と遅延予算](docs/latency-budget.md) | I/Oサイズ・実遅延の違い、SRC単体測定、my-lan-audio2からの知見 |
| [個別ミックスとTotalMixの性能比較](docs/mixing-performance.md) | CPU・遅延・安定性の差、取得チャンネルの制約 |
| [実機・ルーティング](docs/routing-and-observations.md) | 確認済み要件、今回の観測、信号の取り出し方、クロック運用 |
| [実装・検証計画](docs/implementation-and-validation.md) | 最初に解く課題、段階的実装、遅延・安定性の合格条件 |
| [参考資料](docs/references.md) | RME・Antelope・Appleの一次資料と適用範囲 |
| [元の依頼](todo.md) | 当初の要件 |

PC取得と64 framesの全mute双方向I/Oは確認済み。次の実機検証は **実信号のchannel対応・自己音声除外・処理後復路**。GUIから選択できることと、選んだ経路で実音が流れることを分けて確認する。初期版では各FIFO目標を、その経路のsource／destinationの最大実I/O buffer以上にする必要がある。GUIのFIFO候補は16/32/64/128/256/512/1024 framesで、条件を満たさない設定を無断で増やさない。[制限の詳細](docs/getting-started.md#音声転送)

更新日: 2026-09-28
