<script lang="ts" generics="T">
	// Shows a skeleton while loading, an error notice on failure, and the data when it has arrived.
	import type { Snippet } from 'svelte';
	import type { Resource } from '$lib/resource.svelte';
	import ErrorNotice from './ErrorNotice.svelte';

	let {
		res,
		children,
		onretry,
		rows = 5
	}: { res: Resource<T>; children: Snippet<[T]>; onretry?: () => void; rows?: number } = $props();
</script>

{#if res.error}
	<ErrorNotice error={res.error} {onretry} />
{:else if res.data !== null}
	<div class:stale={res.loading}>{@render children(res.data)}</div>
{:else}
	<div class="skel" aria-busy="true" aria-label="Loading">
		{#each Array(rows) as _, i (i)}
			<div class="skeleton" style="height: 18px; width: {92 - i * 9}%"></div>
		{/each}
	</div>
{/if}

<style>
	.skel { display: grid; gap: 12px; padding: 18px; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); }
	.stale { opacity: 0.6; transition: opacity 0.15s; }
</style>
