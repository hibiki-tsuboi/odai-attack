# odaiattack-proxy

OdaiAttack から Jev（TypeSafe System One API）を呼ぶための中継サーバー（Cloudflare Workers）。
TypeSafe の API キーはこの Worker の Secret にだけ置き、アプリには入れない。

## していること

- `POST /v1/systemone` だけを受け付け、アプリと同じ形のリクエストか確かめる（`src/validate.ts`）。
  - モデルは `wrangler.jsonc` の `ALLOWED_MODELS` にあるものだけ
  - `state` はお題（40文字まで）と言葉（40文字まで）だけ
  - 質問は4つまでで、種類は noul か score。質問文と判定基準は1つ500文字まで。本文は 8 KB まで
- 回数を制限する。アプリのインストールごとの ID（`X-OdaiAttack-Install-ID` ヘッダー）ごとに 120回/分、全体で 1000回/分まで（どちらも Cloudflare のデータセンターごとに数える）。
- 通ったリクエストに API キーを付けて TypeSafe に送り、応答をそのまま返す。中継サーバー自身のエラーも、TypeSafe と同じ `{"detail": {"error_type", "message"}}` の形で返す。

## 初めてデプロイする

1. `cd proxy && npm install`
2. `npx wrangler login` — ブラウザが開くので、Cloudflare にログインして許可する。
3. `npx wrangler deploy` — 最後に表示される `https://odaiattack-proxy.<サブドメイン>.workers.dev` を控える。
   workers.dev のサブドメインをまだ決めていなければ、ここで聞かれる。
4. `npx wrangler secret put TYPESAFE_API_KEY` — 聞かれたら TypeSafe の API キーを貼り付ける。
   登録するとすぐに反映される（それまでは `500 not_configured` を返す）。
5. 動作を確かめる（`answers` の入った JSON が返れば成功）:

   ```sh
   curl -X POST https://odaiattack-proxy.<サブドメイン>.workers.dev/v1/systemone \
     -H "Content-Type: application/json" \
     -H "X-OdaiAttack-Install-ID: 00000000-0000-4000-8000-000000000000" \
     -d '{"model":"jev-1.13.0","state":{"topic":"赤いもの","word":"りんご"},"questions":{"fits_topic":{"type":"noul","instructions":"Is `word` a valid answer for the word-game category `topic`?"}}}'
   ```

6. アプリの `Config/App.xcconfig` の `JEV_PROXY_HOST` に `odaiattack-proxy.<サブドメイン>.workers.dev` を書いて（`https://` は付けない）、ビルドし直す。

## コマンド

- `npm test` — テスト（Node.js の型の取り除きで .ts をそのまま動かす）
- `npm run typecheck` — 型チェック（`wrangler types` で型を作ってから `tsc`）
- `npm run dev` — ローカルで動かす。API キーは `.dev.vars`（git 管理外）に `TYPESAFE_API_KEY="..."` と書く
- `npm run deploy` — デプロイ
- `npx wrangler tail` — デプロイした Worker のログ（状態・かかった時間・リクエスト ID）を見る

## 変えるとき

- アプリの `WordJudge.model` を上げるときは、先に `ALLOWED_MODELS` に新しいモデルを足してデプロイし、そのあとアプリを出す。
- アプリの質問を増やしたり長くしたりしたら、`src/validate.ts` の `LIMITS` に収まるか確かめる。
- API キーを替えるときは、もう一度 `npx wrangler secret put TYPESAFE_API_KEY`。
