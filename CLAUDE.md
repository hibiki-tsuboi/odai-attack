# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## アプリ概要

- お題（例:「赤いもの」「冬に使うもの」）に対して、制限時間10秒でお題に合う言葉をできるだけ多く声で言うパーティーゲーム。
- iPhone の音声認識で言葉を1語ずつ拾い、TypeSafe AI の Jev モデルで即座に判定する。
- 判定の速さがゲームのテンポそのものなので、レイテンシを最優先で扱う。
- 開発はフェーズ単位で進める。各フェーズの依頼文は `docs/prompt.md` にある。1つのフェーズを実機で確認してから次へ進む。
- 2026-09-28 時点で `docs/prompt.md` のフェーズはすべて実装し、実機で確認済み。中継サーバーはデプロイ済みで、アプリは `JEV_PROXY_HOST` の中継サーバーを通して Jev を呼んでいる。

## Jev について

- Jev は文章を生成しない「System One」モデル。状態（テキストや JSON）と型付きの質問を送ると、型付きの答えと確率を返す。
- 質問タイプは Choice / Score / Noul。Noul は「この文は真か？」に対して true の確率（0〜1）を返す。
- 公式 SDK は Python と JavaScript のみなので、Swift からは REST API（`POST https://api.typesafe.ai/v1/systemone`）を URLSession で直接呼ぶ。
- リクエスト/レスポンスの正確な形式は推測せず、typesafe プラグインのスキルか https://docs.typesafe.ai を必ず確認してから実装すること。
- モデルはバージョンを固定する（`jev-latest` は新リリースで答えが変わるため）。現在は `jev-1.13.0`（2026-09-28 にドキュメントで確認）。上げるときはドキュメントで最新の固定版名を確認し、しきい値を調整し直す。
- Jev の世界知識はあてにしない。判定に必要な情報（お題、候補の言葉、判定基準）はすべてリクエストに含める。
- ドキュメントによると Jev の主な学習言語は英語で、日本語は精度が落ちる。そのため質問文（`instructions` / `criteria`）は英語で書き、お題と言葉は日本語のまま `state` に入れている。
- 質問 ID（`questions` のキー）はモデルに送られない。質問の意味はすべて `instructions` と `criteria` に書く。
- JSON のキー変換（`convertFromSnakeCase` など）は使わない。質問 ID などの辞書のキーまで変換されてしまう。
- エラー時の本文は `{"detail": {"error_type": ..., "message": ...}}`。キーが無いと 403、無効なキーだと 401（ドキュメントには 401 しか書かれていない）。レスポンスヘッダー `x-typesafe-request-id` にリクエスト ID が入る。
- 408・429・5xx（529 を含む）とタイムアウトなどの接続エラーは、`SystemOneHTTP` が `JevRetryPolicy` に従って待ってから送り直す（待ち時間は倍々で最大25%ばらつかせ、`Retry-After` があれば従う）。言葉の判定は1回4秒で切って1回だけ送り直し、ベスト回答は公式 SDK の既定値（1回10秒、2回まで）。設定は `WordJudge` の `judgmentRetry` / `bestAnswerRetry`。2026-09-28 の夜は、TypeSafe のステータスページが正常なのに 503（upstream connect error）や10秒以上の応答が多く混ざった。

## 設計方針

- SwiftUI + Swift Concurrency (async/await)。
- Jev の呼び出しは `JevClient` プロトコルの裏に隠し、実装を差し替え可能にする。
  - `ProxyJevClient`: 自前の中継サーバー（`proxy/` の Cloudflare Worker）を通す。API キーはアプリに入らない。接続先が設定されていればこちらを使う
  - `DirectJevClient`: TypeSafe API を直接呼ぶ（開発用）。API キーがアプリの Info.plist に平文で入るので、Release ビルドではキーを入れない
- API キーはソースコードに直接書かない。開発用のキーは `Config/Secrets.xcconfig`（.gitignore 対象）から Info.plist 経由で読み込む。本番のキーは中継サーバーの Secret にだけ置く。
- 通信にかかった時間（ms）を毎回計測してログに出す。
- 外部ライブラリは極力使わない。

## コード構成

- `OdaiAttack/Jev/`: System One API の型、`JevClient` プロトコル、2つの実装（`ProxyJevClient` / `DirectJevClient`、通信は共通の `SystemOneHTTP`）、設定から実装を選ぶ `makeConfiguredJevClient()`。ゲーム固有の知識は持たない。
- `OdaiAttack/WordJudge.swift`: お題と言葉から Jev への質問（Noul: 当てはまるか / Score: 典型度）を組み立て、回答を `WordJudgment` にまとめる。質問文・Score の段階・固定するモデル版はここに集める。通信時間の計測とログもここで行う（どの `JevClient` 実装でも同じ条件で測れるように）。
- `OdaiAttack/Game/`: ゲーム本体（フェーズ3）。`GameModel` がタイトル → お題とカウントダウン → 10秒間声で言う → 結果を進める。結果画面では、正解した言葉の中から Jev の Choice で「今回のベスト回答」を1つ選んで発表する（点数は変えない。質問は `WordJudge.bestAnswer`）。時間・正解のしきい値・点数（意外な言葉のボーナス）・ベスト回答の条件は `GameRules.swift`、お題は `Topics.swift`。結果画面から開く「判定のしくみ」（`JudgmentMechanicsView`）は、そのラウンドの実際の確率と `WordJudge` の質問文・`GameRules` の値をそのまま使って、Noul・Score・Choice の使い方を説明する（説明の文章は手書きなので、質問やルールの意味を変えたら合わせて直す）。
- `OdaiAttack/SpokenWordList.swift`: 声で確定した言葉を受け取り、判定を言葉ごとに並行して送り、結果を言った順に出す（前の言葉の判定を最大1秒待つ）。同じ言葉（ひらがな・カタカナなどの違いは無視）は判定しない。ゲームと音声判定画面で共有する。
- `OdaiAttack/Speech/`: 声を言葉に区切る部分。`SpeechWordRecognizer` が音声認識と区切りを受け持ち、音声は `append(_:)` で受け取る。iOS 専用のマイクまわりは `Audio/` に分けているので、`Speech/` は Mac でもコンパイルして動かせる。区切りのパラメータはすべて `SpeechTuning.swift` にある。
- `OdaiAttack/Audio/`: `AudioIO`（マイク入力と効果音の出力を1つの AVAudioEngine で扱う）と、コードで作る効果音 `SoundEffect`。
- `OdaiAttack/VoiceLab/`・`OdaiAttack/JudgeLab/`: フェーズ2・1の検証画面（声での判定と区切りの確認 / テキストでの判定とレイテンシの計測）。タイトル画面の「検証画面を開く」から、`LabsView` のシートで開く。
- `Formatting.swift`（秒・ms・小数の表示）と `APIKeyMissingBanner` は画面どうしで共有する。
- `tools/speech-harness/`: `SpeechWordRecognizer` を Mac で試す道具（下の「コマンド」参照）。アプリには含まれない。
- `proxy/`: Jev を中継する Cloudflare Worker（TypeScript、依存は wrangler と typescript だけ）。アプリと同じ形のリクエストだけを通し（`src/validate.ts`）、インストール ID（`X-OdaiAttack-Install-ID`、アプリが最初の起動で作る UUID）ごとと全体の回数を制限して、API キーを付けて TypeSafe に転送する。デプロイ手順は `proxy/README.md`。アプリの `WordJudge.model` や質問を変えたら、`proxy/wrangler.jsonc` の `ALLOWED_MODELS` と `src/validate.ts` の `LIMITS` も確かめる（モデルを上げるときは先にサーバーをデプロイする）。
- 接続先の設定の流れ: ターゲットの Debug / Release に `Config/App.xcconfig` を割り当ててある。中継サーバーのホスト名 `JEV_PROXY_HOST` はそこに書き（xcconfig では `//` 以降がコメントになるので `https://` は付けない）、`OdaiAttack/Info.plist` の `JevProxyHost` を経て `ProxyJevClient.fromInfoPlist()` が読む。開発用の `TYPESAFE_API_KEY` は `Config/Secrets.xcconfig` を `#include?` で読み（ファイルが無くてもビルドは通る）、Info.plist の `TypeSafeAPIKey` を経て `DirectJevClient.fromInfoPlist()` が読む。`App.xcconfig` の `TYPESAFE_API_KEY[config=Release] =` で、Release ビルドにはキーを入れない（2026-09-28 に Release の .app にキーが無いことを確認）。

## 音声認識について（2026-09-28 に SDK と Mac での計測で確認したこと）

- 使っているのは SpeechAnalyzer + `DictationTranscriber`（iOS 26 からの API）。`SpeechTranscriber` は認識途中の結果が約1秒ごとにしか届かず、`DictationTranscriber` は0.1〜0.3秒ごとに届く。短い言葉の正確さは、合成音声で試した範囲では同程度。
- マイクの音声は iOS 27 の `installAudioTap`（旧 `installTap` は非推奨）で受け取り、`AnalyzerInputConverter`（iOS 27）で認識用の形式に変える。タップのバッファは 100〜400 ms しか指定できないので、区切りの判定も 100 ms 単位になる。タップのコールバックはオーディオスレッドで呼ばれるので、`SpeechWordRecognizer` の音声まわりの状態は `Mutex` で守っている。
- 区切り方: 音量で話し終わり（無音）を検出したら `SpeechAnalyzer.finalize(through:)` を呼び、届いた確定結果を言葉にする。`reportingOptions` に `.frequentFinalization` が無いと、finalize しても確定結果（`isFinal`）が届かない。確定の範囲は `through` より少し後ろ（処理済みのところ）まで伸びることがある。
- 無音の判定は、周りの騒音レベルに合わせてしきい値を動かし、話している間はしきい値を下げる（ヒステリシス）。これが無いと、騒がしいときに言葉の途中で切れた。
- 効果音を鳴らしながら聞くので、`AudioIO` はマイクと効果音を同じ AVAudioEngine で扱い、音声処理（`setVoiceProcessingEnabled`、エコーキャンセル）を有効にしている（`SpeechTuning.usesVoiceProcessing`）。音声処理を使うときの音声セッションのモードは `.default`、使わないときは `.measurement`。さらに、効果音を拾って同じ言葉が何度も認識されても音が鳴り続けないように、重複した言葉では効果音を鳴らさない。
- 入出力のサンプルレートなどが変わると、AVAudioEngine は自分で止まって `AVAudioEngineConfigurationChange` を出す。初めて音声処理を有効にしたときに起き、インストール直後の1回目だけ音声が入らなかった（2026-09-28 に実機で確認）。`AudioIO` は、音声処理を初めて有効にしたらすぐに、プレイヤー・エンジン・音声セッションをすべて止めてから始め直す（2回目以降のプレイと同じ状態にする）。止まった知らせを受けたときも同じ手順で動かし直し、タップを今の形式で付け直す。エンジンだけを動かし直したときは、マイクは戻っても効果音が鳴らなかった。聞き始めて1秒たっても音声が届かなければ1回だけ入れ直し、ゲームはマイクの音声が安定して届いてからカウントダウンを始める。サンプルレートが途中で変わってもよいように、`SpeechWordRecognizer` は受け取った音声の長さを秒で数える。
- iOS 27 で非推奨になった AVFAudio の API: `AVAudioEngine.connect(_:to:format:)` → `connectNode(_:to:format:)`、`AVAudioPlayerNode.play()` → `playAudio()`（どちらも throws）、`installTap` → `installAudioTap`。
- `SpeechDetector` は単体では使えず、文字起こしと一緒に使っても結果が出なかったので使っていない。
- 合成音声だと「コップ」のような短い言葉を誤認識したり、空の結果になったりする。区切りのテストでは、その2語以外を見る。
- シミュレーターには日本語の音声入力モデルが無く、「音声認識モデルを用意できませんでした」になる。声の確認は実機か `tools/speech-harness` で行う。
- マイクと音声認識の両方の許可が必要。利用目的の説明は `INFOPLIST_KEY_NSMicrophoneUsageDescription` / `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` のビルド設定にある。

## コマンド

Deployment Target が **iOS 27.0** なので、iOS 27 のシミュレーター（例: `iPhone 18 Pro`）が必要。iOS 26.x 以前のランタイムは実行先に使えない。

```sh
# ビルド（Debug、シミュレーター）
xcodebuild -project OdaiAttack.xcodeproj -scheme OdaiAttack \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build build

# シミュレーターにインストールして起動
xcrun simctl boot "iPhone 18 Pro" 2>/dev/null; \
xcrun simctl install "iPhone 18 Pro" build/Build/Products/Debug-iphonesimulator/OdaiAttack.app && \
xcrun simctl launch "iPhone 18 Pro" jp.hibiki.OdaiAttack

# 声の区切りを Mac で試す（合成音声の単語を実時間で流す。引数: 単語間の無音ms、雑音dBFS か off、単語...）
tools/speech-harness/run.sh 400 -60

# 中継サーバー（proxy/ で。最初に npm install）
npm test                 # テスト
npm run typecheck        # 型チェック
npm run dev              # ローカルで動かす（API キーは proxy/.dev.vars に書く。git 管理外）
npx wrangler deploy      # デプロイ
npx wrangler secret put TYPESAFE_API_KEY   # API キーを Secret に登録
```

テストターゲットはまだ無い。追加したら同じ `-scheme` と `-destination` で `xcodebuild test` を使い、1つだけ実行するときは `-only-testing:<TestTarget>/<TestClassOrSuite>/<testMethod>` を付ける。

`OdaiAttack` スキームは Xcode が自動生成したもので、`xcshareddata` に共有されていない。テストターゲットや CI を追加するときは先にスキームを共有する。

## プロジェクト設定でコードに影響するもの

- **同期フォルダ**: `OdaiAttack/` は `PBXFileSystemSynchronizedRootGroup`。中に作ったファイルは自動でアプリターゲットに入る（.md なども Resources にコピーされる）。ソースやリソースを追加するために `project.pbxproj` を編集しない。
- **Info.plist**: `GENERATE_INFOPLIST_FILE = YES` で生成したものに `OdaiAttack/Info.plist`（`INFOPLIST_FILE`）の内容がマージされる。このファイルには独自キーだけを置き、Apple 標準のキー（利用目的の説明など）は各ビルド構成の `INFOPLIST_KEY_*` ビルド設定で追加する。`Info.plist` は同期フォルダ内にあるため、`project.pbxproj` の例外設定（`PBXFileSystemSynchronizedBuildFileExceptionSet`）でターゲットのメンバーから外している。
- **デフォルトで MainActor**（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`、`SWIFT_APPROACHABLE_CONCURRENCY = YES`）: `nonisolated` を付けない限り、すべての型と関数が暗黙に `@MainActor` になる。UI に依存しない `Jev/`・`Speech/`・`WordJudge` の型は `nonisolated` にしている。オーディオスレッドなど別スレッドから呼ばれるクロージャを MainActor の中で作らないこと（呼ばれたスレッドとアクターが食い違う）。メインアクター外で動かす処理は `nonisolated` や `@concurrent` で明示する。
- **Swift 言語モード 5.0** で、upcoming feature の `MemberImportVisibility` が有効。各ファイルで、メンバーを使うモジュールをすべて直接 `import` する（`Logger` なら `import os`）。推移的な import ではメンバーが見えない。
- **アセットのシンボル生成**（`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`）: カタログのアセットは文字列名ではなく、生成されたシンボル（`Image(.myImage)`、`Color.accent` など）で参照する。
- **String Catalog**（`LOCALIZATION_PREFERS_STRING_CATALOGS`、`STRING_CATALOG_GENERATE_SYMBOLS`）: ローカライズする文字列は `.xcstrings` に置く。development region は `en`。
- Bundle ID は `jp.hibiki.OdaiAttack`。署名は自動で、チームは `AK92W9FN2D`。
