<script lang="ts">
	// Horizontal proportion bars for a handful of labelled values (KYC status, deposits by product).
	let { items, format = (v: number) => String(v) }: { items: { label: string; value: number; color?: string }[]; format?: (v: number) => string } = $props();
	const max = $derived(Math.max(...items.map((i) => i.value), 1));
</script>

<ul>
	{#each items as item (item.label)}
		<li>
			<span class="name">{item.label}</span>
			<span class="track" aria-hidden="true"><span class="fill" style="width: {(item.value / max) * 100}%; background: {item.color ?? 'var(--navy-700)'}"></span></span>
			<span class="val num">{format(item.value)}</span>
		</li>
	{/each}
</ul>

<style>
	ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
	li { display: grid; grid-template-columns: minmax(110px, 170px) 1fr minmax(70px, auto); align-items: center; gap: 10px; }
	.track { height: 12px; background: var(--grey-bg); border-radius: 6px; overflow: hidden; }
	.fill { display: block; height: 100%; border-radius: 6px; }
	.val { font-weight: 600; }
</style>
