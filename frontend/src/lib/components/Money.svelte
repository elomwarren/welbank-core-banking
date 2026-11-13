<script lang="ts">
	import { formatMoney } from '$lib/format';

	let { value, currency = 'GHS', signed = false }: { value: number | null | undefined; currency?: string; signed?: boolean } = $props();
</script>

<span class="num money" class:neg={value !== null && value !== undefined && value < 0}>{signed && value && value > 0 ? '+' : ''}{formatMoney(value, currency)}</span>

<style>
	.money { font-variant-numeric: tabular-nums; white-space: nowrap; }
	.neg { color: var(--red); }
</style>
