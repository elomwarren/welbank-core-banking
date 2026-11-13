// A small loader for pages: holds data, loading flag and error of one API call.
import { untrack } from 'svelte';
import { ApiError } from './api';

export class Resource<T> {
	data = $state<T | null>(null);
	loading = $state(true);
	error = $state<ApiError | null>(null);
	private ticket = 0;

	/** Run a request; answers of an older request are ignored. Call inside an $effect. */
	run(fetcher: () => Promise<T>, keepData = false): Promise<void> {
		const mine = ++this.ticket;
		return untrack(async () => {
			this.loading = true;
			this.error = null;
			if (!keepData) this.data = null;
			try {
				const result = await fetcher();
				if (mine === this.ticket) this.data = result;
			} catch (e) {
				if (mine === this.ticket) this.error = e instanceof ApiError ? e : new ApiError(0, 'UNEXPECTED', String(e));
			} finally {
				if (mine === this.ticket) this.loading = false;
			}
		});
	}
}
