<script lang="ts">
	// Previous/next paging for skip/take endpoints, which do not report a total:
	// a full page means there may be more.
	let {
		skip,
		take,
		shown,
		onchange
	}: { skip: number; take: number; shown: number; onchange: (skip: number) => void } = $props();

	const hasNext = $derived(shown >= take);
</script>

{#if skip > 0 || hasNext}
	<nav class="pager" aria-label="Pages">
		<button class="btn small" type="button" disabled={skip === 0} onclick={() => onchange(Math.max(0, skip - take))}>← Previous</button>
		<span class="muted">Rows {skip + 1}–{skip + shown}</span>
		<button class="btn small" type="button" disabled={!hasNext} onclick={() => onchange(skip + take)}>Next →</button>
	</nav>
{/if}

<style>
	.pager { display: flex; align-items: center; justify-content: flex-end; gap: 12px; padding: 10px 4px; }
</style>
