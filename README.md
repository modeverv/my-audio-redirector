# my-redirector

RME Fireface UCX IIとAntelope Discrete4の間で、音声のミックスと転送を行うmacOSアプリの設計。

現段階は設計とオフラインのSRC・ミックス演算測定まで。アプリの音声エンジン・GUIは未実装で、機器設定変更・音出し試験は行っていない。

## 作るもの

- RMEの物理入力とPC再生出力を別々に取り込み、設定画面にチャンネルを一覧表示する。それぞれのgainを調整して2mixを作る。PC再生音にもRMEのLoopbackを使わない。
- ミックスをDiscrete4の **Computer Play 1/2** に送る。この入力先は必須。
- Discrete4内でミックス／エフェクト処理したステレオ音声を、設定で選んだRME出力チャンネルへ返す。AESは初期候補で、固定しない。
- 通常画面の操作は **OFF / ONの1個だけ**。入出力、ミックス量、クロック運用、診断は設定画面へまとめる。
- LadioCastに対する改善は、同条件の実測で判断する。
- 64 samplesを目標に小バッファを調整できる設定を用意する。I/Oサイズ、ソフト内の待ち量、実際の往復遅延は別に表示する。

## 推奨する構成

**SwiftUI + Core Audio HAL + C++音声エンジン**。RMEの物理入力はHAL、PC音声は出力device/streamを指定したCore Audio Tapを第一検証候補とする。PC出力のチャンネル構成を保持し、全体を先にstereoへ潰すTapは使わない。[PC音声の取得設計](docs/computer-audio-capture.md)

**RMEとDiscrete4をまとめるAggregate Deviceは採用しない。** ユーザー環境では、両機器をAggregateにすると音声入出力がおかしくなる。一方、AppleのTap受信方式はAggregateを使うため、PC音声の受信に限定したprivate Aggregateは検証対象とする。2台の物理機器を結合せず、privateだから安定するとも仮定しない。具体的な受信構成は実機PoCで確定する。

最終形は両機器とMacのUSB接続だけで橋渡しし、**RMEとDiscrete4間のS/PDIF・ADAT・同期ケーブルを使わない**。復路はDiscrete4の処理済みミックスをDAW Record Loopbackへ出してUSBで取得し、設定で選んだRMEのhost出力L/Rへ送る。物理端子への接続はTotalMixの経路と併せて確認する。RMEから最終出力先への接続は撤去対象に含まない。

独立した2台は同じ48 kHzでも少しずつクロックがずれる。FIFOだけでは長時間後に破綻するため、ASRCとバッファ量の制御が安定性の中心となる。まずこの部分を計測用エンジンで検証する。

RMEの前段Loopbackペアを予約しない。PC音声はTotalMixのHardware Outサブミックスより前で取得する。復路のRMEチャンネルにかかわらず自分の出力をTapから除外し、往路への循環を防ぐ。隣接するmy-lan-audio2の小I/Oバッファ実装とSRC単体測定を、[遅延予算](docs/latency-budget.md)へまとめた。

RME入力とPC音声をそれぞれstereoへ混合し、Discrete4の時間軸へ合わせて最終2mixを作る。別受信経路になったため、初期設計はstereo FIFO・ASRCを3系統とする。チャンネルごとには増やさない。複雑さを採否の理由にせず、処理時間・音切れ・実遅延を検証する。[方式間の性能比較](docs/mixing-performance.md)

## 文書

| 文書 | 内容 |
| --- | --- |
| [アーキテクチャ](docs/architecture.md) | 方式選定、音声処理、GUI、状態管理、設定保存 |
| [PC音声の取得](docs/computer-audio-capture.md) | Loopback不要の多チャンネルTap、取得対象、自己音声除外、成立条件 |
| [64 samples目標と遅延予算](docs/latency-budget.md) | I/Oサイズ・実遅延の違い、SRC単体測定、my-lan-audio2からの知見 |
| [個別ミックスとTotalMixの性能比較](docs/mixing-performance.md) | CPU・遅延・安定性の差、取得チャンネルの制約 |
| [実機・ルーティング](docs/routing-and-observations.md) | 確認済み要件、今回の観測、信号の取り出し方、クロック運用 |
| [実装・検証計画](docs/implementation-and-validation.md) | 最初に解く課題、段階的実装、遅延・安定性の合格条件 |
| [参考資料](docs/references.md) | RME・Antelope・Appleの一次資料と適用範囲 |
| [元の依頼](todo.md) | 当初の要件 |

最初の実装は、音声を転送しない **デバイス／ストリーム／チャンネル診断**。次に **多チャンネルTapの取得と自己音声除外のPoC**、**固定経路の計測用エンジン**へ進む。音声取得位置、実効サンプルレート、Discrete4の処理後USB復路を確認してからGUIを載せる。

更新日: 2026-09-28
