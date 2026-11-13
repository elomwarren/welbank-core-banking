<script lang="ts">
	// WEL Bank wordmark: a gold "W" ribbon mark and the name. Original artwork.
	let { size = 36, light = true, showName = true }: { size?: number; light?: boolean; showName?: boolean } = $props();
</script>

<span class="logo" class:dark={!light}>
	<svg width={size} height={size} viewBox="0 0 40 40" role="img" aria-label="WEL Bank">
		<rect width="40" height="40" rx="9" fill="#C8962E" />
		<rect x="2" y="2" width="36" height="36" rx="7" fill="#0B2E59" />
		<path d="M8 13l5 15 7-11 7 11 5-15" fill="none" stroke="#C8962E" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" />
		<path d="M10 31h20" stroke="#E6C37A" stroke-width="1.6" stroke-linecap="round" />
	</svg>
	{#if showName}
		<span class="name"><strong>WEL</strong> Bank</span>
	{/if}
</span>

<style>
	.logo { display: inline-flex; align-items: center; gap: 10px; color: #fff; }
	.logo.dark { color: var(--navy-900); }
	.name { font-size: 20px; letter-spacing: 0.02em; }
	.name strong { color: var(--gold-300); font-weight: 800; letter-spacing: 0.06em; }
	.dark .name strong { color: var(--gold-600); }
</style>
