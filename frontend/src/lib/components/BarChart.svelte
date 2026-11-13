<script lang="ts">
	// Simple inline-SVG bar chart: one group per category, one bar per series (or stacked).
	import { formatMoney, formatNumber } from '$lib/format';

	interface Series {
		name: string;
		color: string;
		values: number[];
	}

	let {
		categories,
		series,
		stacked = false,
		money = true,
		height = 240,
		title = 'Bar chart'
	}: { categories: string[]; series: Series[]; stacked?: boolean; money?: boolean; height?: number; title?: string } = $props();

	const W = 640;
	const left = 56;
	const bottom = 28;
	const top = 12;

	const max = $derived.by(() => {
		let m = 0;
		for (let i = 0; i < categories.length; i++) {
			m = Math.max(m, stacked ? series.reduce((s, x) => s + (x.values[i] ?? 0), 0) : Math.max(...series.map((x) => x.values[i] ?? 0), 0));
		}
		return niceMax(m);
	});

	function niceMax(v: number): number {
		if (v <= 0) return 1;
		const pow = 10 ** Math.floor(Math.log10(v));
		for (const f of [1, 2, 2.5, 5, 10]) if (v <= f * pow) return f * pow;
		return v;
	}

	function short(v: number): string {
		if (!money) return formatNumber(v);
		if (v >= 1e9) return `${+(v / 1e9).toFixed(1)}B`;
		if (v >= 1e6) return `${+(v / 1e6).toFixed(1)}M`;
		if (v >= 1e3) return `${+(v / 1e3).toFixed(1)}k`;
		return String(v);
	}

	const plotH = $derived(height - top - bottom);
	const plotW = W - left - 8;
	const groupW = $derived(categories.length ? plotW / categories.length : plotW);
	const barW = $derived(stacked ? Math.min(46, groupW * 0.6) : Math.min(30, (groupW * 0.78) / Math.max(series.length, 1)));
	const ticks = $derived([0, 0.25, 0.5, 0.75, 1].map((f) => f * max));
	const y = (v: number) => top + plotH - (v / max) * plotH;

	const total = $derived(series.reduce((s, x) => s + x.values.reduce((a, b) => a + b, 0), 0));
	const fmt = (v: number) => (money ? formatMoney(v) : formatNumber(v));
</script>

<figure>
	<svg viewBox="0 0 {W} {height}" role="img" aria-label={title}>
		<title>{title}</title>
		{#each ticks as t (t)}
			<line x1={left} x2={W - 8} y1={y(t)} y2={y(t)} stroke="var(--border)" stroke-width="1" />
			<text x={left - 6} y={y(t) + 4} text-anchor="end" font-size="11" fill="var(--text-muted)">{short(t)}</text>
		{/each}
		{#each categories as cat, i (cat)}
			{@const gx = left + i * groupW}
			{#if stacked}
				{@const x0 = gx + (groupW - barW) / 2}
				{#each series as s, si (s.name)}
					{@const below = series.slice(0, si).reduce((a, b) => a + (b.values[i] ?? 0), 0)}
					{@const v = s.values[i] ?? 0}
					{#if v > 0}
						<rect x={x0} y={y(below + v)} width={barW} height={Math.max(0, y(below) - y(below + v))} fill={s.color} rx="2"><title>{cat} · {s.name}: {fmt(v)}</title></rect>
					{/if}
				{/each}
			{:else}
				{#each series as s, si (s.name)}
					{@const v = s.values[i] ?? 0}
					{@const x0 = gx + (groupW - barW * series.length - 3 * (series.length - 1)) / 2 + si * (barW + 3)}
					<rect x={x0} y={y(v)} width={barW} height={Math.max(0, y(0) - y(v))} fill={s.color} rx="2"><title>{cat} · {s.name}: {fmt(v)}</title></rect>
				{/each}
			{/if}
			<text x={gx + groupW / 2} y={height - 8} text-anchor="middle" font-size="11.5" fill="var(--text-muted)">{cat}</text>
		{/each}
		{#if total === 0}
			<text x={W / 2} y={height / 2} text-anchor="middle" fill="var(--text-faint)" font-size="14">No activity in this period</text>
		{/if}
	</svg>
	{#if series.length > 1}
		<figcaption>
			{#each series as s (s.name)}
				<span><i style="background: {s.color}"></i>{s.name}</span>
			{/each}
		</figcaption>
	{/if}
</figure>

<style>
	figure { margin: 0; }
	svg { width: 100%; height: auto; display: block; }
	figcaption { display: flex; gap: 16px; justify-content: center; flex-wrap: wrap; font-size: 12.5px; color: var(--text-muted); margin-top: 4px; }
	i { display: inline-block; width: 11px; height: 11px; border-radius: 2px; margin-right: 6px; vertical-align: -1px; }
</style>
