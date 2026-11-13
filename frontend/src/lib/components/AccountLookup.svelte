<script lang="ts">
	// Type an account number, look it up, and see name, status and balance before using it.
	import FormField from './FormField.svelte';
	import Money from './Money.svelte';
	import StatusBadge from './StatusBadge.svelte';
	import Spinner from './Spinner.svelte';
	import { api, ApiError } from '$lib/api';
	import type { AccountDetail } from '$lib/types';

	let {
		label,
		accountNo = $bindable(''),
		account = $bindable(null)
	}: { label: string; accountNo: string; account: AccountDetail | null } = $props();

	let busy = $state(false);
	let error = $state('');

	async function lookup() {
		const no = accountNo.trim().toUpperCase();
		account = null;
		error = '';
		if (no.length < 6) {
			error = 'Enter the account number (at least 6 characters).';
			return;
		}
		busy = true;
		try {
			account = await api.get<AccountDetail>(`/accounts/${encodeURIComponent(no)}`);
			accountNo = no;
		} catch (e) {
			error = e instanceof ApiError ? e.message : 'The account could not be looked up.';
		} finally {
			busy = false;
		}
	}

	function changed() {
		// Editing the number invalidates the previous lookup.
		if (account && account.account.account_no !== accountNo.trim().toUpperCase()) account = null;
	}
</script>

<div class="look">
	<FormField {label} required {error}>
		<span class="inp">
			<input type="text" bind:value={accountNo} oninput={changed} onkeydown={(e) => e.key === 'Enter' && (e.preventDefault(), lookup())} placeholder="e.g. 1000000000123" autocomplete="off" aria-invalid={!!error} />
			<button class="btn" type="button" onclick={lookup} disabled={busy}>{#if busy}<Spinner />{:else}Look up{/if}</button>
		</span>
	</FormField>
	{#if account}
		{@const a = account.account}
		<div class="found" class:warn={a.status !== 'ACTIVE' || !!a.post_no_debit}>
			<div class="row between">
				<strong>{a.account_name}</strong>
				<span class="row" style="gap: 6px"><StatusBadge status={a.status} />{#if a.post_no_debit}<StatusBadge status="BLOCKED" text="No debit" />{/if}</span>
			</div>
			<div class="muted">{a.product_name ?? 'Account'} · {a.branch_name} · <a href="/accounts/{a.account_no}" target="_blank" rel="noopener">statement</a></div>
			<div class="bal">
				<span>Ledger <Money value={a.ledger_balance} currency={a.currency_code} /></span>
				<span>Available <Money value={a.available_balance} currency={a.currency_code} /></span>
			</div>
			<div class="faint">Holders: {account.holders.map((h) => h.full_name).join(', ') || '—'}</div>
		</div>
	{/if}
</div>

<style>
	.look { display: grid; gap: 8px; }
	.inp { display: flex; gap: 8px; }
	.found { padding: 10px 12px; border: 1px solid #a7d9bd; background: var(--green-bg); border-radius: var(--radius-sm); display: grid; gap: 4px; }
	.found.warn { background: var(--amber-bg); border-color: #e8c877; }
	.bal { display: flex; gap: 18px; font-weight: 650; flex-wrap: wrap; }
</style>
