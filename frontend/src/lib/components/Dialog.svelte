<script lang="ts">
	// Modal dialog on the native <dialog> element: focus trap, Esc to close and backdrop come for free.
	import type { Snippet } from 'svelte';

	let {
		open = $bindable(false),
		title,
		children,
		actions,
		wide = false
	}: { open: boolean; title: string; children: Snippet; actions?: Snippet; wide?: boolean } = $props();

	let el = $state<HTMLDialogElement>();

	$effect(() => {
		if (!el) return;
		if (open && !el.open) el.showModal();
		if (!open && el.open) el.close();
	});
</script>

<dialog bind:this={el} class:wide onclose={() => (open = false)} oncancel={() => (open = false)} aria-labelledby="dlg-title">
	<form method="dialog" onsubmit={(e) => e.preventDefault()}>
		<header>
			<h2 id="dlg-title">{title}</h2>
			<button type="button" class="x" aria-label="Close" onclick={() => (open = false)}>×</button>
		</header>
		<div class="content">{@render children()}</div>
		{#if actions}<footer>{@render actions()}</footer>{/if}
	</form>
</dialog>

<style>
	dialog {
		border: 0;
		padding: 0;
		border-radius: 10px;
		width: min(480px, calc(100vw - 32px));
		box-shadow: var(--shadow-lg);
		color: var(--text);
	}
	dialog.wide { width: min(720px, calc(100vw - 32px)); }
	dialog::backdrop { background: rgb(6 26 53 / 55%); }
	header { display: flex; justify-content: space-between; align-items: center; padding: 14px 20px; border-bottom: 1px solid var(--border); background: var(--navy-50); border-radius: 10px 10px 0 0; }
	.x { border: 0; background: none; font-size: 24px; line-height: 1; cursor: pointer; color: var(--text-muted); padding: 0 6px; }
	.content { padding: 18px 20px; display: grid; gap: 12px; max-height: 70vh; overflow: auto; }
	footer { display: flex; justify-content: flex-end; gap: 10px; padding: 12px 20px; border-top: 1px solid var(--border); background: var(--surface-2); border-radius: 0 0 10px 10px; }
</style>
