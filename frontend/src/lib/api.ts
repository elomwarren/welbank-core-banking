// The one place that talks to the FastAPI backend (same origin: /api).

export interface FieldIssue {
	loc: (string | number)[];
	msg: string;
}

/** An error answer: `{code, message}` plus the HTTP status (and `errors` for 422). */
export class ApiError extends Error {
	readonly status: number;
	readonly code: string;
	readonly issues: FieldIssue[];

	constructor(status: number, code: string, message: string, issues: FieldIssue[] = []) {
		super(message);
		this.name = 'ApiError';
		this.status = status;
		this.code = code;
		this.issues = issues;
	}

	/** Validation messages by field path without the leading "body" (e.g. "address.town"). */
	get fieldErrors(): Record<string, string> {
		const out: Record<string, string> = {};
		for (const issue of this.issues) {
			const path = issue.loc.slice(1).join('.');
			if (path && !(path in out)) out[path] = issue.msg;
		}
		return out;
	}
}

type Query = Record<string, string | number | boolean | null | undefined>;

interface RequestOptions {
	method?: 'GET' | 'POST' | 'PUT' | 'DELETE';
	query?: Query;
	body?: unknown;
	form?: FormData;
	/** Do not run the global 401 handler (used by the login form). */
	quiet401?: boolean;
}

type UnauthorizedHandler = () => void;
let onUnauthorized: UnauthorizedHandler = () => {};

/** The session store registers what happens on 401 (go to /login). */
export function setUnauthorizedHandler(handler: UnauthorizedHandler): void {
	onUnauthorized = handler;
}

function withQuery(path: string, query?: Query): string {
	if (!query) return path;
	const params = new URLSearchParams();
	for (const [key, value] of Object.entries(query)) {
		if (value !== null && value !== undefined && value !== '') params.set(key, String(value));
	}
	const text = params.toString();
	return text ? `${path}?${text}` : path;
}

export async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
	const { method = 'GET', query, body, form, quiet401 } = options;
	const headers: Record<string, string> = { Accept: 'application/json' };
	let payload: BodyInit | undefined;
	if (form) {
		payload = form; // the browser sets the multipart boundary
	} else if (body !== undefined) {
		headers['Content-Type'] = 'application/json';
		payload = JSON.stringify(body);
	}

	let response: Response;
	try {
		response = await fetch(withQuery(`/api${path}`, query), {
			method,
			headers,
			body: payload,
			credentials: 'same-origin'
		});
	} catch {
		throw new ApiError(0, 'NETWORK', 'The server cannot be reached. Check the connection and try again.');
	}

	const text = await response.text();
	let data: unknown = null;
	if (text) {
		try {
			data = JSON.parse(text);
		} catch {
			data = null;
		}
	}

	if (!response.ok) {
		const err = (data ?? {}) as { code?: string; message?: string; errors?: FieldIssue[] };
		const error = new ApiError(
			response.status,
			err.code ?? `HTTP_${response.status}`,
			err.message ?? (response.status === 503 ? 'The database is not available right now.' : `Request failed (${response.status}).`),
			err.errors ?? []
		);
		if (response.status === 401 && !quiet401) onUnauthorized();
		throw error;
	}
	return data as T;
}

export const api = {
	get: <T>(path: string, query?: Query) => request<T>(path, { query }),
	post: <T>(path: string, body?: unknown, options: RequestOptions = {}) =>
		request<T>(path, { ...options, method: 'POST', body: body ?? {} }),
	upload: <T>(path: string, form: FormData) => request<T>(path, { method: 'POST', form })
};
