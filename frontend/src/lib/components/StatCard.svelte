<script lang="ts">
	import type { Snippet } from 'svelte';

	let { label, tone = 'default', hint, children }: { label: string; tone?: 'default' | 'good' | 'warn' | 'bad'; hint?: string; children: Snippet } = $props();
</script>

<div class="stat {tone}">
	<span class="lbl">{label}</span>
	<span class="val">{@render children()}</span>
	{#if hint}<span class="hint">{hint}</span>{/if}
</div>

<style>
	.stat {
		display: grid;
		gap: 4px;
		padding: 14px 16px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-left: 4px solid var(--navy-700);
		border-radius: var(--radius);
		box-shadow: var(--shadow);
	}
	.stat.good { border-left-color: var(--green); }
	.stat.warn { border-left-color: var(--gold-500); }
	.stat.bad { border-left-color: var(--red); }
	.lbl { font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; color: var(--text-muted); }
	.val { font-size: 22px; font-weight: 700; color: var(--navy-900); font-variant-numeric: tabular-nums; }
	.hint { font-size: 12px; color: var(--text-faint); }
</style>
