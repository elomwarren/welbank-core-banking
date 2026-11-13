<script lang="ts">
	import { toast } from '$lib/toast.svelte';
</script>

<div class="toasts" aria-live="polite" aria-atomic="false">
	{#each toast.items as t (t.id)}
		<div class="toast {t.kind}" role={t.kind === 'error' ? 'alert' : 'status'}>
			<span class="msg">
				{t.text}
				{#if t.href}<a href={t.href}>{t.linkText ?? 'Open'}</a>{/if}
			</span>
			<button type="button" aria-label="Dismiss" onclick={() => toast.dismiss(t.id)}>×</button>
		</div>
	{/each}
</div>

<style>
	.toasts { position: fixed; right: 16px; bottom: 16px; display: grid; gap: 8px; z-index: 1000; width: min(420px, calc(100vw - 32px)); }
	.toast { display: flex; justify-content: space-between; gap: 10px; padding: 12px 14px; border-radius: var(--radius); background: var(--navy-900); color: #fff; box-shadow: var(--shadow-lg); border-left: 5px solid var(--blue); }
	.toast.success { border-left-color: #3ec47e; }
	.toast.error { background: #6b1410; border-left-color: #ff8b83; }
	.msg a { color: var(--gold-300); font-weight: 700; margin-left: 6px; }
	button { background: none; border: 0; color: inherit; font-size: 20px; cursor: pointer; line-height: 1; }
</style>
