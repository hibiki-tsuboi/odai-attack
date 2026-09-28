import assert from "node:assert/strict";
import { afterEach, describe, it, mock } from "node:test";
import { handle, type ProxyEnv } from "../src/index.ts";
import { validateSystemOneRequest } from "../src/validate.ts";

const MODELS = ["jev-1.13.0"];
const INSTALL_ID = "3f2c8f4e-8d1a-4c1e-9b7a-2f5d6c7e8a9b";

/** アプリ（WordJudge）が送るリクエストと同じ形。 */
function appRequest(): Record<string, any> {
	return {
		model: "jev-1.13.0",
		questions: {
			fits_topic: {
				criteria: {
					false: "`word` does not fit `topic`, fits only in rare special cases, or is not a meaningful word.",
					true: "`word` is something that belongs to `topic` or typically has the quality that `topic` describes. A surprising answer still counts if it genuinely fits.",
				},
				instructions: "Is `word` a valid answer for the word-game category `topic`?",
				type: "noul",
			},
			typicality: {
				criteria: [
					"`word` does not fit `topic`.",
					"`word` fits `topic`, but it is a surprising answer that few people would think of.",
					"`word` fits `topic` and is a reasonable answer, but it is not one of the first answers that come to mind.",
					"`word` is a textbook example of `topic`, one of the first answers most people would say.",
				],
				instructions: "How typical an answer is `word` for the word-game category `topic`?",
				type: "score",
			},
		},
		state: { topic: "赤いもの", word: "りんご" },
	};
}

/** アプリ（WordJudge.bestAnswer）が送る、ベスト回答を選ぶリクエストと同じ形。 */
function bestAnswerRequest(options: string[] = ["トマト", "ポスト", "金魚"]): Record<string, any> {
	return {
		model: "jev-1.13.0",
		questions: {
			best_answer: {
				criteria: Object.fromEntries(options.map((option) => [option, null])),
				instructions:
					"Which answer is the best answer of this round for the word-game category `topic`? The best answer fits `topic` well, and few players would think of it.",
				type: "choice",
			},
		},
		state: { topic: "赤いもの" },
	};
}

function env(overrides: Partial<ProxyEnv> = {}): ProxyEnv {
	const allow = { limit: async () => ({ success: true }) };
	return {
		TYPESAFE_API_KEY: "test-key",
		ALLOWED_MODELS: "jev-1.13.0",
		PER_INSTALL_LIMITER: allow,
		GLOBAL_LIMITER: allow,
		...overrides,
	} as ProxyEnv;
}

function post(body: string, headers: Record<string, string> = { "X-OdaiAttack-Install-ID": INSTALL_ID }): Request {
	return new Request("https://proxy.example/v1/systemone", {
		method: "POST",
		headers: { "Content-Type": "application/json", ...headers },
		body,
	});
}

describe("validateSystemOneRequest", () => {
	it("accepts the request the app sends", () => {
		assert.equal(validateSystemOneRequest(appRequest(), MODELS), null);
	});

	it("rejects other models", () => {
		const body = { ...appRequest(), model: "jev-latest" };
		assert.match(validateSystemOneRequest(body, MODELS) ?? "", /model must be one of/);
	});

	it("rejects extra fields and extra state", () => {
		assert.match(validateSystemOneRequest({ ...appRequest(), stream: true }, MODELS) ?? "", /unexpected field/);
		const body = appRequest();
		body.state.document = "long text";
		assert.match(validateSystemOneRequest(body, MODELS) ?? "", /only topic and word/);
	});

	it("rejects long or empty words", () => {
		const long = appRequest();
		long.state.word = "あ".repeat(41);
		assert.match(validateSystemOneRequest(long, MODELS) ?? "", /state.word/);
		const empty = appRequest();
		empty.state.word = "  ";
		assert.match(validateSystemOneRequest(empty, MODELS) ?? "", /state.word/);
	});

	it("rejects too many or unknown questions", () => {
		const many = appRequest();
		for (const id of ["a", "b", "c"]) {
			many.questions[id] = { type: "noul", instructions: "Is it red?" };
		}
		assert.match(validateSystemOneRequest(many, MODELS) ?? "", /1 to 4 entries/);
		const unknown = appRequest();
		unknown.questions.fits_topic = { type: "rank", instructions: "Which?" };
		assert.match(validateSystemOneRequest(unknown, MODELS) ?? "", /type must be noul, score, or choice/);
		const levels = appRequest();
		levels.questions.typicality.criteria = Array.from({ length: 11 }, (_, i) => `level ${i}`);
		assert.match(validateSystemOneRequest(levels, MODELS) ?? "", /2 to 10 levels/);
	});
});

describe("validateSystemOneRequest (best answer)", () => {
	it("accepts the best answer request the app sends", () => {
		assert.equal(validateSystemOneRequest(bestAnswerRequest(), MODELS), null);
	});

	it("rejects too many, too few, or long options", () => {
		const many = bestAnswerRequest(Array.from({ length: 31 }, (_, i) => `言葉${i}`));
		assert.match(validateSystemOneRequest(many, MODELS) ?? "", /2 to 30 options/);
		assert.match(validateSystemOneRequest(bestAnswerRequest(["トマト"]), MODELS) ?? "", /2 to 30 options/);
		const long = bestAnswerRequest(["トマト", "あ".repeat(41)]);
		assert.match(validateSystemOneRequest(long, MODELS) ?? "", /each option/);
		const described = bestAnswerRequest();
		described.questions.best_answer.criteria["トマト"] = "x".repeat(501);
		assert.match(validateSystemOneRequest(described, MODELS) ?? "", /description of トマト/);
	});

	it("still requires the topic and allows nothing else in state", () => {
		const noTopic = bestAnswerRequest();
		noTopic.state = { word: "トマト" };
		assert.match(validateSystemOneRequest(noTopic, MODELS) ?? "", /only topic/);
		const extra = bestAnswerRequest();
		extra.state.document = "long text";
		assert.match(validateSystemOneRequest(extra, MODELS) ?? "", /only topic/);
	});
});

describe("handle", () => {
	afterEach(() => mock.restoreAll());

	it("forwards a valid request with the API key and returns the response as is", async () => {
		const body = JSON.stringify(appRequest());
		const upstream = mock.method(globalThis, "fetch", async () =>
			new Response('{"model":"jev-1.13.0","answers":{}}', {
				status: 200,
				headers: { "Content-Type": "application/json", "x-typesafe-request-id": "req_123" },
			}),
		);

		const response = await handle(post(body), env());

		assert.equal(response.status, 200);
		assert.equal(response.headers.get("x-typesafe-request-id"), "req_123");
		assert.equal(await response.text(), '{"model":"jev-1.13.0","answers":{}}');
		const [url, init] = upstream.mock.calls[0].arguments as [string, RequestInit];
		assert.equal(url, "https://api.typesafe.ai/v1/systemone");
		assert.equal((init.headers as Record<string, string>).Authorization, "Bearer test-key");
		assert.equal(init.body, body);
	});

	it("passes TypeSafe errors through", async () => {
		mock.method(globalThis, "fetch", async () =>
			Response.json({ detail: { error_type: "authentication_error", message: "bad key" } }, { status: 401 }),
		);
		const response = await handle(post(JSON.stringify(appRequest())), env());
		assert.equal(response.status, 401);
		assert.equal((await response.json()).detail.message, "bad key");
	});

	it("rejects requests without an install id", async () => {
		const response = await handle(post(JSON.stringify(appRequest()), {}), env());
		assert.equal(response.status, 400);
		assert.match((await response.json()).detail.message, /Install-ID/);
	});

	it("returns 429 when either limit is reached", async () => {
		const deny = { limit: async () => ({ success: false }) };
		assert.equal((await handle(post(JSON.stringify(appRequest())), env({ PER_INSTALL_LIMITER: deny }))).status, 429);
		assert.equal((await handle(post(JSON.stringify(appRequest())), env({ GLOBAL_LIMITER: deny }))).status, 429);
	});

	it("rejects invalid, oversized, and wrongly shaped bodies without calling TypeSafe", async () => {
		const upstream = mock.method(globalThis, "fetch", async () => new Response("{}"));
		assert.equal((await handle(post("not json"), env())).status, 400);
		assert.equal((await handle(post("x".repeat(9000)), env())).status, 413);
		assert.equal((await handle(post(JSON.stringify({ ...appRequest(), model: "jev-latest" })), env())).status, 400);
		assert.equal(upstream.mock.callCount(), 0);
	});

	it("rejects other paths, methods, and a missing API key", async () => {
		assert.equal((await handle(new Request("https://proxy.example/"), env())).status, 404);
		assert.equal((await handle(new Request("https://proxy.example/v1/systemone"), env())).status, 405);
		const response = await handle(post(JSON.stringify(appRequest())), env({ TYPESAFE_API_KEY: undefined }));
		assert.equal(response.status, 500);
	});

	it("returns 504 when TypeSafe does not respond in time", async () => {
		mock.method(globalThis, "fetch", async () => {
			throw new DOMException("timed out", "TimeoutError");
		});
		assert.equal((await handle(post(JSON.stringify(appRequest())), env())).status, 504);
	});
});
