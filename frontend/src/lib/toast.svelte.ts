// Short messages shown in the corner; announced to screen readers through aria-live.
export interface ToastItem {
	id: number;
	kind: 'success' | 'error' | 'info';
	text: string;
	/** Optional link, e.g. to the new transaction. */
	href?: string;
	linkText?: string;
}

class Toasts {
	items = $state<ToastItem[]>([]);
	private next = 1;

	show(kind: ToastItem['kind'], text: string, link?: { href: string; text: string }, ms = 7000): void {
		const id = this.next++;
		this.items.push({ id, kind, text, href: link?.href, linkText: link?.text });
		setTimeout(() => this.dismiss(id), ms);
	}

	success(text: string, link?: { href: string; text: string }): void {
		this.show('success', text, link);
	}
	error(text: string): void {
		this.show('error', text, undefined, 10000);
	}
	info(text: string): void {
		this.show('info', text);
	}
	dismiss(id: number): void {
		this.items = this.items.filter((t) => t.id !== id);
	}
}

export const toast = new Toasts();
