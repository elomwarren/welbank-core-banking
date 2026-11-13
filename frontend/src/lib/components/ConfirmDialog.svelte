<script lang="ts">
	// Confirmation before an irreversible action; optionally asks for a reason (required then).
	import Dialog from './Dialog.svelte';
	import Spinner from './Spinner.svelte';
	import type { Snippet } from 'svelte';

	let {
		open = $bindable(false),
		title,
		confirmLabel = 'Confirm',
		danger = false,
		reasonLabel,
		minReason = 3,
		onconfirm,
		children
	}: {
		open: boolean;
		title: string;
		confirmLabel?: string;
		danger?: boolean;
		/** When set, a required reason is asked for and passed to onconfirm. */
		reasonLabel?: string;
		minReason?: number;
		onconfirm: (reason: string) => Promise<void> | void;
		children?: Snippet;
	} = $props();

	let reason = $state('');
	let busy = $state(false);
	let touched = $state(false);

	const reasonBad = $derived(reasonLabel !== undefined && reason.trim().length < minReason);

	$effect(() => {
		if (open) {
			reason = '';
			touched = false;
		}
	});

	async function confirm() {
		touched = true;
		if (reasonBad) return;
		busy = true;
		try {
			await onconfirm(reason.trim());
		} finally {
			busy = false;
		}
	}
</script>

<Dialog bind:open {title}>
	{#if children}{@render children()}{/if}
	{#if reasonLabel !== undefined}
		<div class="field">
			<label>
				<span class="lbl">{reasonLabel} <span class="req">*</span></span>
				<textarea bind:value={reason} rows="3" maxlength="400" aria-invalid={touched && reasonBad}></textarea>
			</label>
			{#if touched && reasonBad}<p class="err" role="alert">Give a reason of at least {minReason} characters.</p>{/if}
		</div>
	{/if}
	{#snippet actions()}
		<button class="btn" type="button" onclick={() => (open = false)} disabled={busy}>Cancel</button>
		<button class="btn {danger ? 'danger' : 'primary'}" type="button" onclick={confirm} disabled={busy}>
			{#if busy}<Spinner />{/if}{confirmLabel}
		</button>
	{/snippet}
</Dialog>

<style>
	.lbl { font-size: 12.5px; font-weight: 650; color: var(--text-muted); }
	label { display: grid; gap: 4px; }
	.req { color: var(--red); }
	.err { color: var(--red); font-size: 12px; margin: 4px 0 0; font-weight: 600; }
</style>
