<script lang="ts">
	import { untrack } from 'svelte';
	import Card from '$lib/components/Card.svelte';
	import FormField from '$lib/components/FormField.svelte';
	import AccountLookup from '$lib/components/AccountLookup.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import Money from '$lib/components/Money.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Tabs from '$lib/components/Tabs.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api, ApiError } from '$lib/api';
	import { toast } from '$lib/toast.svelte';
	import { formatMoney } from '$lib/format';
	import type { AccountDetail } from '$lib/types';

	const TABS = [
		{ id: 'deposits', label: 'Cash deposit' },
		{ id: 'withdrawals', label: 'Cash withdrawal' },
		{ id: 'transfers', label: 'Transfer' }
	];

	let mode = $state('deposits');
	let previousMode = 'deposits';
	let fromNo = $state('');
	let from = $state<AccountDetail | null>(null);
	let toNo = $state('');
	let to = $state<AccountDetail | null>(null);
	let amount = $state('');
	let narration = $state('');
	let touched = $state(false);
	let confirm = $state(false);
	let formError = $state('');
	let result = $state<{ txn_ref: string; status: string; message: string; summary: string } | null>(null);

	const amountNum = $derived(Number(amount));
	const amountBad = $derived(!amount || !(amountNum > 0) || !/^\d+(\.\d{1,2})?$/.test(amount));
	const currency = $derived(from?.account.currency_code ?? 'GHS');

	const problems = $derived.by(() => {
		const p: string[] = [];
		if (!from) p.push(mode === 'transfers' ? 'Look up the account to debit.' : 'Look up the account first.');
		if (mode === 'transfers') {
			if (!to) p.push('Look up the account to credit.');
			if (from && to && from.account.account_no === to.account.account_no) p.push('The two accounts are the same.');
			if (from && to && from.account.currency_code !== to.account.currency_code) p.push('Transfers need two accounts in the same currency.');
		}
		if (amountBad) p.push('Enter an amount above zero with at most two decimals.');
		return p;
	});

	const overdrawn = $derived((mode !== 'deposits' && from && amountNum > from.account.available_balance) || false);

	// A different tab starts a clean form.
	$effect(() => {
		if (mode !== previousMode) {
			previousMode = mode;
			untrack(() => reset(false));
		}
	});

	function reset(clearResult = true) {
		fromNo = toNo = amount = narration = '';
		from = to = null;
		touched = false;
		formError = '';
		if (clearResult) result = null;
	}

	function review(e: SubmitEvent) {
		e.preventDefault();
		touched = true;
		formError = '';
		if (problems.length) return;
		confirm = true;
	}

	const summary = $derived(
		mode === 'deposits'
			? `Deposit ${formatMoney(amountNum, currency)} into ${from?.account.account_name ?? ''} (${fromNo})`
			: mode === 'withdrawals'
				? `Pay out ${formatMoney(amountNum, currency)} from ${from?.account.account_name ?? ''} (${fromNo})`
				: `Transfer ${formatMoney(amountNum, currency)} from ${from?.account.account_name ?? ''} (${fromNo}) to ${to?.account.account_name ?? ''} (${toNo})`
	);

	async function post() {
		const text = summary;
		try {
			const body =
				mode === 'transfers'
					? { from_account_no: fromNo, to_account_no: toNo, amount: amountNum, narration: narration.trim() || null }
					: { account_no: fromNo, amount: amountNum, narration: narration.trim() || null };
			const r = await api.post<{ txn_ref: string; status: string; message: string }>(`/transactions/${mode}`, body);
			result = { ...r, summary: text };
			confirm = false;
			if (r.status === 'POSTED') toast.success(`Posted: ${r.txn_ref}`, { href: `/transactions/${r.txn_ref}`, text: 'View' });
			else toast.info(`${r.txn_ref} was sent to a supervisor for approval.`);
			reset(false);
		} catch (e) {
			confirm = false;
			formError = e instanceof ApiError ? e.message : 'The transaction failed.';
		}
	}
</script>

<Title text="Counter" subtitle="Cash deposits, withdrawals and transfers" />

<RoleGate roles={['WB_TELLER']}>
	<div class="stack wrap">
		{#if result}
			<div class="notice {result.status === 'POSTED' ? 'success' : 'warn'} res" role="status">
				<div>
					<StatusBadge status={result.status} />
					<strong>{result.status === 'POSTED' ? 'Posted' : 'Sent to a supervisor'}</strong> · {result.message}
					<div class="muted">{result.summary}</div>
				</div>
				<div class="row">
					<a class="btn small" href="/transactions/{result.txn_ref}">{result.txn_ref}</a>
					<button class="btn small ghost" type="button" onclick={() => (result = null)}>Dismiss</button>
				</div>
			</div>
		{/if}

		<Tabs tabs={TABS} bind:active={mode} label="Counter transactions" />
		<div role="tabpanel" id="panel-{mode}" aria-labelledby="tab-{mode}">
			<Card title={mode === 'deposits' ? 'Cash deposit' : mode === 'withdrawals' ? 'Cash withdrawal' : 'Transfer between accounts'} subtitle="Above your limit the transaction waits for a supervisor (maker-checker).">
				<form class="stack" onsubmit={review} novalidate>
					<AccountLookup label={mode === 'transfers' ? 'From account (debit)' : 'Account'} bind:accountNo={fromNo} bind:account={from} />
					{#if mode === 'transfers'}
						<AccountLookup label="To account (credit)" bind:accountNo={toNo} bind:account={to} />
					{/if}
					<div class="grid cols-2">
						<FormField label="Amount ({currency})" required error={touched && amountBad ? 'Enter an amount above zero with at most two decimals.' : ''}>
							<input type="text" inputmode="decimal" bind:value={amount} placeholder="0.00" aria-invalid={touched && amountBad} />
						</FormField>
						<FormField label="Narration" hint="Shown on the statement (up to 140 characters).">
							<input type="text" bind:value={narration} maxlength="140" />
						</FormField>
					</div>
					{#if overdrawn && from}
						<div class="notice warn">The amount is above the available balance (<Money value={from.account.available_balance} currency={currency} />). The system will refuse it unless an overdraft applies.</div>
					{/if}
					{#if touched && problems.length}
						<div class="notice error" role="alert"><ul>{#each problems as p (p)}<li>{p}</li>{/each}</ul></div>
					{/if}
					{#if formError}<div class="notice error" role="alert">{formError}</div>{/if}
					<div class="row">
						<button class="btn primary" type="submit">Review and post…</button>
						<button class="btn" type="button" onclick={() => reset()}>Clear</button>
					</div>
				</form>
			</Card>
		</div>
	</div>

	<ConfirmDialog bind:open={confirm} title="Confirm the transaction" confirmLabel="Post transaction" onconfirm={post}>
		<p><strong>{summary}</strong></p>
		{#if narration}<p class="muted">Narration: {narration}</p>{/if}
		<p class="muted">Posting writes the double-entry lines to the ledger. A posted transaction can only be undone by a reversal that a supervisor approves.</p>
	</ConfirmDialog>
</RoleGate>

<style>
	.wrap { max-width: 860px; }
	.res { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
	ul { margin: 0; padding-left: 18px; }
</style>
