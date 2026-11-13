<script lang="ts">
	import type { Snippet } from 'svelte';
	let { title, children }: { title: string; children?: Snippet } = $props();
</script>

<div class="empty">
	<svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M3 10h18M8 15h4" /></svg>
	<strong>{title}</strong>
	{#if children}<p>{@render children()}</p>{/if}
</div>

<style>
	.empty { display: grid; justify-items: center; gap: 6px; padding: 36px 16px; color: var(--text-muted); text-align: center; }
	.empty svg { color: var(--border-strong); }
	.empty strong { color: var(--navy-900); }
	.empty p { margin: 0; max-width: 460px; }
</style>
