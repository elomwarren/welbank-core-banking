<script lang="ts">
	import type { Snippet } from 'svelte';

	let {
		title,
		subtitle,
		actions,
		children,
		flush = false
	}: { title?: string; subtitle?: string; actions?: Snippet; children: Snippet; flush?: boolean } = $props();
</script>

<section class="card">
	{#if title || actions}
		<header>
			<div>
				{#if title}<h2>{title}</h2>{/if}
				{#if subtitle}<p class="muted sub">{subtitle}</p>{/if}
			</div>
			{#if actions}<div class="row">{@render actions()}</div>{/if}
		</header>
	{/if}
	<div class="body" class:flush>{@render children()}</div>
</section>

<style>
	.card {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--radius);
		box-shadow: var(--shadow);
		min-width: 0;
	}
	header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 12px;
		padding: 14px 18px;
		border-bottom: 1px solid var(--border);
	}
	.sub { margin: 2px 0 0; font-size: 13px; }
	.body { padding: 16px 18px; }
	.body.flush { padding: 0; }
	.body.flush :global(.table-wrap) { border: 0; border-radius: 0 0 var(--radius) var(--radius); }
</style>
