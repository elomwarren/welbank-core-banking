// Reference data (products, regions, enum lists) is loaded once and kept for the session.
import { api } from './api';
import type { Reference } from './types';

class ReferenceStore {
	data = $state<Reference | null>(null);
	private pending: Promise<Reference> | null = null;

	/** Load once; later calls share the same answer. */
	load(): Promise<Reference> {
		if (this.data) return Promise.resolve(this.data);
		this.pending ??= api
			.get<Reference>('/reference')
			.then((d) => (this.data = d))
			.finally(() => (this.pending = null));
		return this.pending;
	}

	enumValues(name: string): string[] {
		return this.data?.enums[name] ?? [];
	}

	clear(): void {
		this.data = null;
	}
}

export const reference = new ReferenceStore();
