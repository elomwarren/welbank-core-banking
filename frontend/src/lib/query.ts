import { goto } from '$app/navigation';
import { page } from '$app/state';

/** Change some query parameters of the current page (empty values are removed) without losing focus or scroll. */
export function setParams(updates: Record<string, string | number | null | undefined>, resetSkip = true): void {
	const url = new URL(page.url.href);
	for (const [key, value] of Object.entries(updates)) {
		if (value === null || value === undefined || value === '') url.searchParams.delete(key);
		else url.searchParams.set(key, String(value));
	}
	if (resetSkip && !('skip' in updates)) url.searchParams.delete('skip');
	void goto(url.pathname + url.search, { reset: false });
}

export function intParam(name: string, fallback: number): number {
	const n = Number(page.url.searchParams.get(name));
	return Number.isFinite(n) && n >= 0 && page.url.searchParams.has(name) ? Math.floor(n) : fallback;
}
