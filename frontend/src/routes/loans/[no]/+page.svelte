<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import AccountLookup from '$lib/components/AccountLookup.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import FormField from '$lib/components/FormField.svelte';
	import Money from '$lib/components/Money.svelte';
	import StatCard from '$lib/components/StatCard.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api, ApiError } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { session } from '$lib/session.svelte';
	import { toast } from '$lib/toast.svelte';
	import { formatDate, formatMoney, formatNumber, label, parseDate } from '$lib/format';
	import type { AccountDetail, LoanDetail, ScheduleLine } from '$lib/types';

	const no = $derived(page.params.no ?? '');
	const res = new Resource<LoanDetail>();
	const load = (keep = false) => res.run(() => api.get<LoanDetail>(`/loans/${no}`), keep);
	$effect(() => {
		void no;
		void load();
	});

	const canRepay = $derived(session.has('WB_LOAN_OFFICER', 'WB_CREDIT'));
	let accNo = $state('');
	let acc = $state<AccountDetail | null>(null);
	let amount = $state('');
	let touched = $state(false);
	let confirm = $state(false);
	let formError = $state('');

	const amountBad = $derived(!/^\d+(\.\d{1,2})?$/.test(amount) || !(Number(amount) > 0));

	function startRepay(e: SubmitEvent) {
		e.preventDefault();
		touched = true;
		formError = '';
		if (!acc || amountBad) return;
		confirm = true;
	}

	async function repay() {
		try {
			const r = await api.post<{ txn_ref: string }>(`/loans/${no}/repayments`, { account_no: accNo, amount: Number(amount) });
			toast.success(`Repayment posted: ${r.txn_ref}`, { href: `/transactions/${r.txn_ref}`, text: 'View' });
			confirm = false;
			amount = '';
			touched = false;
			await load(true);
		} catch (e) {
			confirm = false;
			formError = e instanceof ApiError ? e.message : 'The repayment failed.';
		}
	}

	/** The schedule's own status is only updated by the nightly job, so past-due open lines are flagged here too. */
	function lineState(l: ScheduleLine): 'PAID' | 'OVERDUE' | 'PARTIAL' | 'DUE' {
		if (l.status === 'PAID') return 'PAID';
		const due = parseDate(l.due_date);
		if (l.status === 'OVERDUE' || (due && due.getTime() < new Date().setHours(0, 0, 0, 0))) return 'OVERDUE';
		return l.status === 'PARTIAL' ? 'PARTIAL' : 'DUE';
	}
</script>

<Title text="Loan {no}" subtitle={res.data?.loan.customer_name ?? ''} />

<Async {res} onretry={() => load()}>
	{#snippet children(d)}
		{@const l = d.loan}
		<div class="stack">
			<div class="grid cols-4">
				<StatCard label="Outstanding"><Money value={l.outstanding} /></StatCard>
				<StatCard label="Due now" tone={d.due_now > 0 ? 'bad' : 'good'} hint={d.due_now > 0 ? 'installments past their due date' : 'nothing overdue'}><Money value={d.due_now} /></StatCard>
				<StatCard label="Days past due" tone={l.days_past_due > 0 ? 'bad' : 'good'}>{l.days_past_due}</StatCard>
				<StatCard label="Classification"><StatusBadge status={l.classification} /></StatCard>
			</div>

			<div class="grid cols-2">
				<Card title="Loan">
					<dl class="facts">
						<dt>Customer</dt><dd><a href="/customers/{l.customer_no}">{l.customer_name}</a> <span class="faint mono">{l.customer_no}</span></dd>
						<dt>Product</dt><dd>{l.product_name}</dd>
						<dt>Application</dt><dd class="mono">{l.application_no}</dd>
						<dt>Principal</dt><dd><Money value={l.principal} /></dd>
						<dt>Interest rate</dt><dd>{formatNumber(l.interest_rate, 2)}% a year ({label(l.rate_type).toLowerCase()}{#if l.reference_rate !== null}: reference {formatNumber(l.reference_rate, 2)}% + margin {formatNumber(l.margin_pct, 2)}%{/if})</dd>
						<dt>Term</dt><dd>{l.term_months} months</dd>
						<dt>Status</dt><dd><StatusBadge status={l.status} />{#if l.closed_on}&nbsp;closed {formatDate(l.closed_on)}{/if}</dd>
					</dl>
				</Card>
				<Card title="Dates and accounts">
					<dl class="facts">
						<dt>Disbursed</dt><dd>{formatDate(l.disbursed_on)}</dd>
						<dt>First installment</dt><dd>{formatDate(l.first_due_date)}</dd>
						<dt>Matures</dt><dd>{formatDate(l.maturity_date)}</dd>
						<dt>Loan account</dt><dd class="mono">{l.loan_account_no}</dd>
						<dt>Paid out to</dt><dd>{#if l.disbursement_account_no}<a class="mono" href="/accounts/{l.disbursement_account_no}">{l.disbursement_account_no}</a>{:else}—{/if}</dd>
						<dt>Branch</dt><dd>{l.branch_code}</dd>
					</dl>
				</Card>
			</div>

			{#if canRepay && l.status === 'ACTIVE'}
				<Card title="Take a repayment" subtitle="Debits the customer's account; interest is paid first, then principal.">
					<form class="stack" onsubmit={startRepay} novalidate>
						<div class="grid cols-2">
							<AccountLookup label="Customer account to debit" bind:accountNo={accNo} bind:account={acc} />
							<div class="stack">
								<FormField label="Amount (GH₵)" required error={touched && amountBad ? 'Enter an amount above zero with at most two decimals.' : touched && !acc ? 'Look up the account first.' : ''}>
									<input type="text" inputmode="decimal" bind:value={amount} placeholder={d.due_now > 0 ? d.due_now.toFixed(2) : '0.00'} aria-invalid={touched && amountBad} />
								</FormField>
								{#if d.due_now > 0}<button class="btn small" type="button" onclick={() => (amount = d.due_now.toFixed(2))}>Use the amount due now ({formatMoney(d.due_now)})</button>{/if}
							</div>
						</div>
						{#if formError}<div class="notice error" role="alert">{formError}</div>{/if}
						<div><button class="btn primary" type="submit">Review repayment…</button></div>
					</form>
				</Card>
			{/if}

			<Card title="Repayment schedule" flush>
				<div class="table-wrap"><table class="table">
					<thead><tr><th class="num">#</th><th>Due date</th><th class="num">Principal</th><th class="num">Interest</th><th class="num">Installment</th><th class="num">Paid</th><th>Status</th><th>Paid on</th></tr></thead>
					<tbody>
						{#each d.schedule as s (s.installment_no)}
							{@const st = lineState(s)}
							<tr class:row-warn={st === 'OVERDUE'}>
								<td class="num">{s.installment_no}</td>
								<td>{formatDate(s.due_date)}</td>
								<td class="num"><Money value={s.principal_due} /></td>
								<td class="num"><Money value={s.interest_due} /></td>
								<td class="num"><strong><Money value={s.total_due} /></strong></td>
								<td class="num"><Money value={s.principal_paid + s.interest_paid} /></td>
								<td><StatusBadge status={st} /></td>
								<td>{formatDate(s.paid_on)}</td>
							</tr>
						{/each}
					</tbody>
				</table></div>
			</Card>

			<Card title="Repayments" flush>
				{#if d.repayments.length === 0}
					<Empty title="No repayments yet" />
				{:else}
					<div class="table-wrap"><table class="table">
						<thead><tr><th>Reference</th><th>Date</th><th class="num">Installment</th><th class="num">Principal</th><th class="num">Interest</th></tr></thead>
						<tbody>
							{#each d.repayments as r, i (i)}
								<tr><td><a class="mono" href="/transactions/{r.txn_ref}">{r.txn_ref}</a></td><td>{formatDate(r.value_date)}</td><td class="num">{r.installment_no ?? '—'}</td><td class="num"><Money value={r.principal_amount} /></td><td class="num"><Money value={r.interest_amount} /></td></tr>
							{/each}
						</tbody>
					</table></div>
				{/if}
			</Card>
		</div>
	{/snippet}
</Async>

<ConfirmDialog bind:open={confirm} title="Confirm the repayment" confirmLabel="Post repayment" onconfirm={repay}>
	<p>Debit <strong>{formatMoney(Number(amount))}</strong> from <strong>{acc?.account.account_name}</strong> (<span class="mono">{accNo}</span>) to repay loan <span class="mono">{no}</span>.</p>
	<p class="muted">The repayment is posted to the ledger at once.</p>
</ConfirmDialog>
