<script lang="ts">
	// A label wrapped around its control (so it is always associated), with hint and inline error.
	import type { Snippet } from 'svelte';

	let {
		label,
		error = '',
		hint = '',
		required = false,
		children
	}: { label: string; error?: string; hint?: string; required?: boolean; children: Snippet } = $props();
</script>

<div class="field" class:bad={!!error}>
	<label>
		<span class="lbl">{label}{#if required}<span class="req" aria-hidden="true"> *</span>{/if}</span>
		{@render children()}
	</label>
	{#if error}<p class="err" role="alert">{error}</p>{:else if hint}<p class="hint">{hint}</p>{/if}
</div>

<style>
	.field { min-width: 0; }
	label { display: grid; gap: 4px; }
	.lbl { font-size: 12.5px; font-weight: 650; color: var(--text-muted); }
	.req { color: var(--red); }
	.hint, .err { margin: 4px 0 0; font-size: 12px; }
	.hint { color: var(--text-faint); }
	.err { color: var(--red); font-weight: 600; }
</style>
