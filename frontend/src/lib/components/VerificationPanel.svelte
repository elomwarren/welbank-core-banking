<script lang="ts">
	// Simulated NIA check of the Ghana Card and simulated sanctions screening.
	import FormField from './FormField.svelte';
	import StatusBadge from './StatusBadge.svelte';
	import Spinner from './Spinner.svelte';
	import { api, ApiError } from '$lib/api';
	import { reference } from '$lib/reference.svelte';
	import { toast } from '$lib/toast.svelte';
	import { formatDateTime, label } from '$lib/format';

	interface Verification { method: string; result: string; nia_reference: string | null; is_simulated: number | boolean; performed_at: string }

	let {
		customerNo,
		verifications = [],
		sanctionsStatus,
		onrecorded
	}: { customerNo: string; verifications?: Verification[]; sanctionsStatus: string; onrecorded: () => void } = $props();

	let method = $state('FACE');
	let outcome = $state<'MATCH' | 'NO_MATCH'>('MATCH');
	let screening = $state<'CLEAR' | 'POTENTIAL_MATCH'>('CLEAR');
	let busy = $state<'' | 'nia' | 'screen'>('');
	let error = $state('');

	const methods = $derived(reference.enumValues('verification_method'));

	async function verify() {
		busy = 'nia';
		error = '';
		try {
			const r = await api.post<{ result: string; nia_reference: string | null }>(`/customers/${customerNo}/verification`, { method, outcome });
			if (r.result === 'MATCH') toast.success(`NIA check matched (simulated). Reference ${r.nia_reference}.`);
			else toast.error('NIA check did not match (simulated). The identity is not verified.');
			onrecorded();
		} catch (e) {
			error = e instanceof ApiError ? e.message : 'The check failed.';
		} finally {
			busy = '';
		}
	}

	async function screen() {
		busy = 'screen';
		error = '';
		try {
			await api.post(`/customers/${customerNo}/screening`, { result: screening });
			toast.success(`Sanctions screening recorded as ${label(screening).toLowerCase()} (simulated).`);
			onrecorded();
		} catch (e) {
			error = e instanceof ApiError ? e.message : 'The screening failed.';
		} finally {
			busy = '';
		}
	}
</script>

<div class="notice warn sim">
	<strong>Simulated checks.</strong> This system has no connection to the National Identification Authority (NIA) or to a sanctions list provider.
	You choose the outcome below to rehearse the process; every record is flagged as simulated and kept in the audit trail.
</div>

<div class="grid cols-2">
	<div class="panel">
		<h3>1. NIA verification of the Ghana Card</h3>
		<div class="row">
			<FormField label="Method">
				<select bind:value={method}>
					{#each methods as m (m)}<option value={m}>{label(m)}</option>{/each}
				</select>
			</FormField>
			<FormField label="Outcome to rehearse">
				<select bind:value={outcome}>
					<option value="MATCH">Match</option>
					<option value="NO_MATCH">No match</option>
				</select>
			</FormField>
		</div>
		<button class="btn small" type="button" disabled={busy !== ''} onclick={verify}>{#if busy === 'nia'}<Spinner />{/if} Record NIA check</button>
		{#if verifications.length}
			<ul class="hist">
				{#each verifications as v, i (i)}
					<li><StatusBadge status={v.result} /> {label(v.method)} · {formatDateTime(v.performed_at)}{#if v.nia_reference}&nbsp;· <span class="mono">{v.nia_reference}</span>{/if}{#if v.is_simulated}&nbsp;<span class="faint">(simulated)</span>{/if}</li>
				{/each}
			</ul>
		{/if}
	</div>
	<div class="panel">
		<h3>2. Sanctions screening <StatusBadge status={sanctionsStatus} /></h3>
		<FormField label="Result to rehearse">
			<select bind:value={screening}>
				<option value="CLEAR">Clear</option>
				<option value="POTENTIAL_MATCH">Potential match</option>
			</select>
		</FormField>
		<button class="btn small" type="button" disabled={busy !== ''} onclick={screen}>{#if busy === 'screen'}<Spinner />{/if} Record screening</button>
	</div>
</div>
{#if error}<div class="notice error" role="alert" style="margin-top: 12px">{error}</div>{/if}

<style>
	.sim { margin-bottom: 14px; }
	.panel { display: grid; gap: 10px; align-content: start; padding: 14px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--surface-2); }
	.panel button { justify-self: start; }
	.row > :global(*) { flex: 1; min-width: 130px; }
	.hist { margin: 0; padding-left: 18px; font-size: 13px; display: grid; gap: 4px; }
</style>
