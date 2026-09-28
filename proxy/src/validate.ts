// アプリが送る判定リクエスト（TypeSafe System One API の形）だけを通すための確認。
// お題と言葉は短い文字列に限るので、長い文章の判定など、ゲーム以外の用途には使えない。

export const LIMITS = {
	/** リクエスト本文の最大バイト数。アプリのリクエストは 1.5 KB ほど。 */
	bodyBytes: 8 * 1024,
	/** お題の最大文字数。 */
	topic: 40,
	/** 言葉の最大文字数。 */
	word: 40,
	/** 1リクエストの質問の数。アプリは2つ送る。 */
	questions: 4,
	/** 質問文と判定基準の1つあたりの最大文字数。 */
	text: 500,
	/** Score の段階の数（API の上限と同じ）。 */
	scoreLevels: 10,
} as const;

type JSONObject = Record<string, unknown>;

/** 問題があれば理由を返し、無ければ null を返す。理由はそのままエラーの本文になる。 */
export function validateSystemOneRequest(body: unknown, allowedModels: readonly string[]): string | null {
	if (!isObject(body)) {
		return "body must be a JSON object";
	}
	const unexpected = Object.keys(body).find((key) => !["model", "state", "questions"].includes(key));
	if (unexpected !== undefined) {
		return `unexpected field: ${unexpected}`;
	}

	if (typeof body.model !== "string" || !allowedModels.includes(body.model)) {
		return `model must be one of: ${allowedModels.join(", ")}`;
	}

	const state = body.state;
	if (!isObject(state) || Object.keys(state).sort().join(",") !== "topic,word") {
		return "state must be an object with only topic and word";
	}
	if (!isText(state.topic, LIMITS.topic)) {
		return `state.topic must be a non-empty string of at most ${LIMITS.topic} characters`;
	}
	if (!isText(state.word, LIMITS.word)) {
		return `state.word must be a non-empty string of at most ${LIMITS.word} characters`;
	}

	const questions = body.questions;
	if (!isObject(questions)) {
		return "questions must be an object";
	}
	const entries = Object.entries(questions);
	if (entries.length === 0 || entries.length > LIMITS.questions) {
		return `questions must have 1 to ${LIMITS.questions} entries`;
	}
	for (const [id, question] of entries) {
		if (!/^[a-z0-9_]{1,40}$/.test(id)) {
			return `invalid question id: ${id}`;
		}
		const problem = validateQuestion(question);
		if (problem !== null) {
			return `questions.${id}: ${problem}`;
		}
	}
	return null;
}

function validateQuestion(question: unknown): string | null {
	if (!isObject(question)) {
		return "must be an object";
	}
	const unexpected = Object.keys(question).find((key) => !["type", "instructions", "criteria"].includes(key));
	if (unexpected !== undefined) {
		return `unexpected field: ${unexpected}`;
	}
	if (!isText(question.instructions, LIMITS.text)) {
		return `instructions must be a non-empty string of at most ${LIMITS.text} characters`;
	}

	const criteria = question.criteria;
	switch (question.type) {
		case "noul":
			if (criteria === undefined) {
				return null;
			}
			if (!isObject(criteria)) {
				return "criteria must be an object";
			}
			for (const [key, value] of Object.entries(criteria)) {
				if (key !== "true" && key !== "false") {
					return `unexpected criteria: ${key}`;
				}
				if (!isText(value, LIMITS.text)) {
					return `criteria.${key} must be a non-empty string of at most ${LIMITS.text} characters`;
				}
			}
			return null;
		case "score":
			if (!Array.isArray(criteria) || criteria.length < 2 || criteria.length > LIMITS.scoreLevels) {
				return `criteria must be 2 to ${LIMITS.scoreLevels} levels`;
			}
			if (!criteria.every((level) => isText(level, LIMITS.text))) {
				return `each level must be a non-empty string of at most ${LIMITS.text} characters`;
			}
			return null;
		default:
			return "type must be noul or score";
	}
}

function isObject(value: unknown): value is JSONObject {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isText(value: unknown, maxLength: number): value is string {
	return typeof value === "string" && value.trim().length > 0 && value.length <= maxLength;
}
