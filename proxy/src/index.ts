// Jev（TypeSafe System One API）を中継する Worker。
// API キーはアプリに入れず、この Worker の Secret（TYPESAFE_API_KEY）に置く。
// アプリと同じ形のリクエストだけを受け付け（validate.ts）、インストールごとと全体の回数を制限してから転送する。

import { LIMITS, validateSystemOneRequest } from "./validate.ts";

export type ProxyEnv = Env & {
	/** `wrangler secret put TYPESAFE_API_KEY` で登録する。 */
	TYPESAFE_API_KEY?: string;
};

const UPSTREAM_URL = "https://api.typesafe.ai/v1/systemone";
const UPSTREAM_TIMEOUT_MS = 10_000;
/** アプリのインストールごとの ID（UUID）。回数の制限に使う。 */
const INSTALL_ID_HEADER = "X-OdaiAttack-Install-ID";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default {
	async fetch(request, env): Promise<Response> {
		const started = Date.now();
		const response = await handle(request, env);
		console.log(
			JSON.stringify({
				status: response.status,
				ms: Date.now() - started,
				requestID: response.headers.get("x-typesafe-request-id"),
			}),
		);
		return response;
	},
} satisfies ExportedHandler<ProxyEnv>;

export async function handle(request: Request, env: ProxyEnv): Promise<Response> {
	if (new URL(request.url).pathname !== "/v1/systemone") {
		return errorResponse(404, "not_found", "Not found");
	}
	if (request.method !== "POST") {
		return errorResponse(405, "method_not_allowed", "Use POST");
	}
	if (!env.TYPESAFE_API_KEY) {
		return errorResponse(500, "not_configured", "TYPESAFE_API_KEY is not set on the Worker");
	}

	const installID = request.headers.get(INSTALL_ID_HEADER) ?? "";
	if (!UUID_PATTERN.test(installID)) {
		return errorResponse(400, "invalid_request", `${INSTALL_ID_HEADER} header must be a UUID`);
	}
	const [perInstall, overall] = await Promise.all([
		env.PER_INSTALL_LIMITER.limit({ key: installID.toLowerCase() }),
		env.GLOBAL_LIMITER.limit({ key: "all" }),
	]);
	if (!perInstall.success || !overall.success) {
		return errorResponse(429, "rate_limited", "Too many requests. Try again later.");
	}

	const body = await readText(request, LIMITS.bodyBytes);
	if (body === null) {
		return errorResponse(413, "too_large", `Request body must be at most ${LIMITS.bodyBytes} bytes`);
	}
	let parsed: unknown;
	try {
		parsed = JSON.parse(body);
	} catch {
		return errorResponse(400, "invalid_request", "Request body must be JSON");
	}
	const allowedModels = env.ALLOWED_MODELS.split(",").map((model) => model.trim());
	const problem = validateSystemOneRequest(parsed, allowedModels);
	if (problem !== null) {
		return errorResponse(400, "invalid_request", problem);
	}

	let upstream: Response;
	try {
		upstream = await fetch(UPSTREAM_URL, {
			method: "POST",
			headers: {
				Authorization: `Bearer ${env.TYPESAFE_API_KEY}`,
				"Content-Type": "application/json",
				Accept: "application/json",
				"User-Agent": "odaiattack-proxy",
			},
			// 確認した本文をそのまま送る（アプリが並べたキーの順番を変えないため）
			body,
			signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
		});
	} catch (error) {
		if (error instanceof Error && error.name === "TimeoutError") {
			return errorResponse(504, "upstream_timeout", "TypeSafe did not respond in time");
		}
		return errorResponse(502, "upstream_unreachable", "Could not reach TypeSafe");
	}

	// TypeSafe の応答は、成功でもエラーでもそのまま返す
	const headers = new Headers({ "Content-Type": upstream.headers.get("Content-Type") ?? "application/json" });
	const requestID = upstream.headers.get("x-typesafe-request-id");
	if (requestID !== null) {
		headers.set("x-typesafe-request-id", requestID);
	}
	return new Response(upstream.body, { status: upstream.status, headers });
}

/** 本文を文字列で読む。`maxBytes` を超えたら途中で読むのをやめて null を返す。 */
async function readText(request: Request, maxBytes: number): Promise<string | null> {
	if (Number(request.headers.get("Content-Length") ?? 0) > maxBytes) {
		return null;
	}
	if (request.body === null) {
		return "";
	}
	const reader = request.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) {
			break;
		}
		total += value.byteLength;
		if (total > maxBytes) {
			await reader.cancel();
			return null;
		}
		chunks.push(value);
	}
	const bytes = new Uint8Array(total);
	let offset = 0;
	for (const chunk of chunks) {
		bytes.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return new TextDecoder().decode(bytes);
}

/** TypeSafe のエラーと同じ形（`{"detail": {"error_type", "message"}}`）で返す。アプリはどちらも同じように読める。 */
function errorResponse(status: number, errorType: string, message: string): Response {
	return Response.json({ detail: { error_type: errorType, message } }, { status });
}
