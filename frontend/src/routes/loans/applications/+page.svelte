<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import AccountLookup from '$lib/components/AccountLookup.svelte';
	import Dialog from '$lib/components/Dialog.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import FormField from '$lib/components/FormField.svelte';
	import Money from '$lib/components/Money.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import Spinner from '$lib/components/Spinner.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api, ApiError } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { reference } from '$lib/reference.svelte';
	import { session } from '$lib/session.svelte';
	import { toast } from '$lib/toast.svelte';
	import { setParams } from '$lib/query';
	import { formatDate, formatMoney, formatNumber, isoDay, label } from '$lib/format';
	import type { AccountDetail, CustomerDetail, LoanApplication, SchedulePreview } from '$lib/types';

	const res = new Resource<LoanApplication[]>();
	const status = $derived(page.url.searchParams.get('status') ?? '');
	const load = (keep = false) => res.run(() => api.get<LoanApplication[]>('/loan-applications', { status, take: 100 }), keep);
	$effect(() => {
		void status;
		void load();
	});
	$effect(() => void reference.load().catch(() => {}));

	// ---- new application (loan officer) ----
	const isOfficer = $derived(session.has('WB_LOAN_OFFICER'));
	let showForm = $state(false);
	let customerNo = $state('');
	let customer = $state<CustomerDetail | null>(null);
	let customerError = $state('');
	let productCode = $state('');
	let amount = $state('');
	let term = $state('');
	let purpose = $state('');
	let details = $state('');
	let income = $state('');
	let obligations = $state('0');
	let touched = $state(false);
	let busy = $state(false);
	let formError = $state('');

	const product = $derived(reference.data?.loan_products.find((p) => p.product_code === productCode) ?? null);
	const amountNum = $derived(Number(amount));
	const termNum = $derived(Number(term));
	const errors = $derived.by(() => {
		const e: Record<string, string> = {};
		if (!customer) e.customer = 'Look up the customer first.';
		else if (customer.customer.kyc_status !== 'VERIFIED' && customer.customer.kyc_status !== 'DEFERRED') e.customer = `KYC is ${label(customer.customer.kyc_status).toLowerCase()}: the customer must be verified.`;
		if (!product) e.product = 'Choose a loan product.';
		if (!(amountNum > 0)) e.amount = 'Enter the amount.';
		else if (product && (amountNum < product.min_amount || amountNum > product.max_amount)) e.amount = `This product allows ${formatMoney(product.min_amount)} to ${formatMoney(product.max_amount)}.`;
		if (!Number.isInteger(termNum) || termNum < 1) e.term = 'Enter the term in months.';
		else if (product && termNum > product.max_term_months) e.term = `At most ${product.max_term_months} months for this product.`;
		if (!purpose) e.purpose = 'Choose the purpose.';
		if (!(Number(income) > 0)) e.income = 'Enter the monthly income.';
		if (obligations === '' || Number(obligations) < 0) e.obligations = 'Enter 0 or more.';
		return e;
	});

	async function findCustomer() {
		customer = null;
		customerError = '';
		const no = customerNo.trim().toUpperCase();
		if (no.length < 4) {
			customerError = 'Enter the customer number.';
			return;
		}
		try {
			customer = await api.get<CustomerDetail>(`/customers/${encodeURIComponent(no)}`);
			customerNo = no;
		} catch (e) {
			customerError = e instanceof ApiError ? e.message : 'Lookup failed.';
		}
	}

	// Live quote: wait until typing pauses, ignore answers of older requests.
	const quote = new Resource<SchedulePreview>();
	let showSchedule = $state(false);
	$effect(() => {
		const p = product;
		const a = amountNum;
		const t = termNum;
		quote.data = null;
		if (!p || !(a > 0) || !Number.isInteger(t) || t < 1 || t > 360 || errors.amount || errors.term) return;
		const timer = setTimeout(() => void quote.run(() => api.get<SchedulePreview>('/loans/schedule-preview', { principal: a, annual_rate: p.interest_rate, term_months: t })), 350);
		return () => clearTimeout(timer);
	});

	async function submitApp(e: SubmitEvent) {
		e.preventDefault();
		touched = true;
		formError = '';
		if (Object.keys(errors).length) return;
		busy = true;
		try {
			const r = await api.post<{ application_no: string; message: string }>('/loan-applications', {
				customer_no: customerNo,
				product_code: productCode,
				amount: amountNum,
				term_months: termNum,
				purpose,
				purpose_details: details.trim() || null,
				monthly_income: Number(income),
				monthly_obligations: Number(obligations)
			});
			toast.success(`Application ${r.application_no} submitted. ${r.message}`);
			showForm = false;
			resetForm();
			await load(true);
		} catch (e) {
			formError = e instanceof ApiError ? e.message : 'The application could not be submitted.';
		} finally {
			busy = false;
		}
	}

	function resetForm() {
		customerNo = amount = term = purpose = details = income = '';
		obligations = '0';
		customer = null;
		touched = false;
		productCode = '';
	}

	// ---- disbursement (credit) ----
	const isCredit = $derived(session.has('WB_CREDIT'));
	let disburse = $state<LoanApplication | null>(null);
	let dOpen = $state(false);
	let dAccNo = $state('');
	let dAcc = $state<AccountDetail | null>(null);
	let dDate = $state('');
	let dRate = $state('VARIABLE');
	let dBusy = $state(false);
	let dError = $state('');

	function startDisburse(a: LoanApplication) {
		disburse = a;
		dAccNo = '';
		dAcc = null;
		dDate = '';
		dRate = 'VARIABLE';
		dError = '';
		dOpen = true;
	}

	async function doDisburse() {
		if (!disburse || !dAcc) {
			dError = 'Look up the customer account that receives the money.';
			return;
		}
		dBusy = true;
		dError = '';
		try {
			const r = await api.post<{ loan_no: string }>(`/loan-applications/${disburse.application_no}/disbursement`, {
				account_no: dAccNo,
				first_due_date: dDate || null,
				rate_type: dRate
			});
			toast.success(`Loan ${r.loan_no} disbursed.`, { href: `/loans/${r.loan_no}`, text: 'Open loan' });
			dOpen = false;
			await load(true);
		} catch (e) {
			dError = e instanceof ApiError ? e.message : 'The disbursement failed.';
		} finally {
			dBusy = false;
		}
	}
</script>

<Title text="Loan applications" subtitle="Prepared by loan officers, decided by credit" />

<RoleGate roles={['WB_LOAN_OFFICER', 'WB_CREDIT']}>
	<div class="stack">
		<Card>
			<div class="filters">
				<label>Status
					<select value={status} onchange={(e) => setParams({ status: e.currentTarget.value })}>
						<option value="">All</option>
						{#each ['SUBMITTED', 'UNDER_REVIEW', 'APPROVED', 'REJECTED', 'WITHDRAWN'] as s (s)}<option value={s}>{label(s)}</option>{/each}
					</select>
				</label>
				<span style="flex: 1"></span>
				<a class="btn" href="/loans">Loan book</a>
				{#if isOfficer}<button class="btn gold" type="button" onclick={() => (showForm = !showForm)}>{showForm ? 'Close the form' : '+ New application'}</button>{/if}
			</div>
		</Card>

		{#if showForm && isOfficer}
			<Card title="New loan application" subtitle="The customer's KYC must be verified. Credit decides the final rate: reference rate plus a margin.">
				<form class="stack" onsubmit={submitApp} novalidate>
					<div class="grid cols-2">
						<div class="stack">
							<FormField label="Customer number" required error={customerError || (touched ? errors.customer : '')}>
								<span class="inline">
									<input type="text" bind:value={customerNo} placeholder="CUS00000000" onkeydown={(e) => e.key === 'Enter' && (e.preventDefault(), findCustomer())} aria-invalid={!!customerError || (touched && !!errors.customer)} />
									<button class="btn" type="button" onclick={findCustomer}>Look up</button>
								</span>
							</FormField>
							{#if customer}
								<div class="notice success"><strong>{customer.customer.first_name} {customer.customer.last_name}</strong> · KYC <StatusBadge status={customer.customer.kyc_status} /> · {customer.customer.branch_name}</div>
							{/if}
						</div>
						<FormField label="Loan product" required error={touched ? errors.product : ''}>
							<select bind:value={productCode} aria-invalid={touched && !!errors.product}>
								<option value="">Choose…</option>
								{#each reference.data?.loan_products ?? [] as p (p.product_code)}<option value={p.product_code}>{p.product_name} ({formatNumber(p.interest_rate, 2)}% indicative)</option>{/each}
							</select>
						</FormField>
						<FormField label="Amount (GH₵)" required hint={product ? `Between ${formatMoney(product.min_amount)} and ${formatMoney(product.max_amount)}` : ''} error={touched ? errors.amount : ''}>
							<input type="number" min="1" step="0.01" bind:value={amount} aria-invalid={touched && !!errors.amount} />
						</FormField>
						<FormField label="Term (months)" required hint={product ? `Up to ${product.max_term_months} months` : ''} error={touched ? errors.term : ''}>
							<input type="number" min="1" max="360" step="1" bind:value={term} aria-invalid={touched && !!errors.term} />
						</FormField>
						<FormField label="Purpose" required error={touched ? errors.purpose : ''}>
							<select bind:value={purpose} aria-invalid={touched && !!errors.purpose}><option value="">Choose…</option>{#each reference.enumValues('loan_purpose') as p (p)}<option value={p}>{label(p)}</option>{/each}</select>
						</FormField>
						<FormField label="Purpose details"><input type="text" bind:value={details} maxlength="400" /></FormField>
						<FormField label="Monthly income (GH₵)" required error={touched ? errors.income : ''}><input type="number" min="0" step="0.01" bind:value={income} aria-invalid={touched && !!errors.income} /></FormField>
						<FormField label="Monthly obligations (GH₵)" required hint="Other loan repayments and fixed commitments" error={touched ? errors.obligations : ''}><input type="number" min="0" step="0.01" bind:value={obligations} aria-invalid={touched && !!errors.obligations} /></FormField>
					</div>

					<div class="quote" aria-live="polite">
						<h3>Quote {#if product}<span class="faint">at the product's indicative {formatNumber(product.interest_rate, 2)}% a year</span>{/if}</h3>
						{#if quote.loading}
							<span class="muted"><Spinner /> Calculating…</span>
						{:else if quote.error}
							<span class="err">{quote.error.message}</span>
						{:else if quote.data}
							{@const q = quote.data}
							<div class="qgrid">
								<div><span class="lbl">Monthly installment</span><strong><Money value={q.installment} /></strong></div>
								<div><span class="lbl">Total interest</span><strong><Money value={q.total_interest} /></strong></div>
								<div><span class="lbl">Total repaid</span><strong><Money value={q.total_repaid} /></strong></div>
							</div>
							<button class="btn small" type="button" onclick={() => (showSchedule = !showSchedule)}>{showSchedule ? 'Hide' : 'Show'} the schedule</button>
							{#if showSchedule}
								<div class="table-wrap" style="max-height: 280px; overflow: auto"><table class="table">
									<thead><tr><th class="num">#</th><th>Due</th><th class="num">Principal</th><th class="num">Interest</th><th class="num">Installment</th><th class="num">Balance after</th></tr></thead>
									<tbody>{#each q.schedule as s (s.installment_no)}<tr><td class="num">{s.installment_no}</td><td>{formatDate(s.due_date)}</td><td class="num"><Money value={s.principal_due} /></td><td class="num"><Money value={s.interest_due} /></td><td class="num"><Money value={s.total_due} /></td><td class="num"><Money value={s.balance_after} /></td></tr>{/each}</tbody>
								</table></div>
							{/if}
						{:else}
							<span class="muted">Choose a product, an amount and a term to see the installment.</span>
						{/if}
					</div>

					{#if formError}<div class="notice error" role="alert">{formError}</div>{/if}
					<div class="row">
						<button class="btn primary" type="submit" disabled={busy}>{#if busy}<Spinner />{/if} Submit the application</button>
						<button class="btn" type="button" onclick={() => (showForm = false)}>Cancel</button>
					</div>
				</form>
			</Card>
		{/if}

		<Async {res} onretry={() => load()}>
			{#snippet children(rows)}
				{#if rows.length === 0}
					<Card><Empty title="No applications">{isOfficer ? 'Use "New application" to prepare one.' : 'Nothing matches this filter.'}</Empty></Card>
				{:else}
					<div class="table-wrap">
						<table class="table">
							<thead><tr><th>Application</th><th>Customer</th><th>Product</th><th class="num">Requested</th><th>Term</th><th>Purpose</th><th>Status</th><th class="num">Approved</th><th>Officer</th><th></th></tr></thead>
							<tbody>
								{#each rows as a (a.application_no)}
									<tr>
										<td class="mono">{a.application_no}<br /><span class="faint">{formatDate(a.submitted_at)}</span></td>
										<td><a href="/customers/{a.customer_no}">{a.customer_name}</a></td>
										<td>{a.product_code}</td>
										<td class="num"><Money value={a.requested_amount} /></td>
										<td>{a.requested_term_months} m</td>
										<td>{label(a.purpose)}</td>
										<td><StatusBadge status={a.status} />{#if a.decision_note}<br /><span class="faint">{a.decision_note}</span>{/if}</td>
										<td class="num">{#if a.approved_amount !== null}<Money value={a.approved_amount} />{:else}—{/if}{#if a.approved_margin_pct !== null}<br /><span class="faint">margin {formatNumber(a.approved_margin_pct, 2)}%</span>{/if}</td>
										<td>{a.loan_officer ?? '—'}</td>
										<td>
											{#if a.loan_no}<a class="btn small" href="/loans/{a.loan_no}">Loan {a.loan_no}</a>
											{:else if a.status === 'APPROVED' && isCredit}<button class="btn small primary" type="button" onclick={() => startDisburse(a)}>Disburse…</button>{/if}
										</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{/if}
			{/snippet}
		</Async>
	</div>

	<Dialog bind:open={dOpen} title="Disburse loan {disburse?.application_no ?? ''}">
		{#if disburse}
			<p>Pay <strong><Money value={disburse.approved_amount} /></strong> to <strong>{disburse.customer_name}</strong>. This opens the loan account, posts the payout and builds the repayment schedule.</p>
			<AccountLookup label="Customer account to credit" bind:accountNo={dAccNo} bind:account={dAcc} />
			<div class="grid cols-2">
				<FormField label="First installment date" hint="Empty: one month from today."><input type="date" bind:value={dDate} min={isoDay(1)} /></FormField>
				<FormField label="Rate type"><select bind:value={dRate}><option value="VARIABLE">Variable (follows the reference rate)</option><option value="FIXED">Fixed</option></select></FormField>
			</div>
			{#if dError}<div class="notice error" role="alert">{dError}</div>{/if}
		{/if}
		{#snippet actions()}
			<button class="btn" type="button" onclick={() => (dOpen = false)} disabled={dBusy}>Cancel</button>
			<button class="btn primary" type="button" onclick={doDisburse} disabled={dBusy}>{#if dBusy}<Spinner />{/if} Disburse</button>
		{/snippet}
	</Dialog>
</RoleGate>

<style>
	.inline { display: flex; gap: 8px; }
	.quote { background: var(--gold-100); border: 1px solid var(--gold-300); border-radius: var(--radius); padding: 14px 16px; display: grid; gap: 10px; }
	.qgrid { display: flex; gap: 32px; flex-wrap: wrap; }
	.qgrid > div { display: grid; }
	.qgrid strong { font-size: 20px; color: var(--navy-900); }
	.lbl { font-size: 12px; text-transform: uppercase; font-weight: 700; letter-spacing: 0.04em; color: var(--text-muted); }
	.err { color: var(--red); font-weight: 600; }
</style>
