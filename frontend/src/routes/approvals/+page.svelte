<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import Dialog from '$lib/components/Dialog.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import FormField from '$lib/components/FormField.svelte';
	import Money from '$lib/components/Money.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import Spinner from '$lib/components/Spinner.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Tabs from '$lib/components/Tabs.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api, ApiError } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { toast } from '$lib/toast.svelte';
	import { setParams } from '$lib/query';
	import { formatDateTime, hoursText, inline, label } from '$lib/format';
	import type { ApprovalItem } from '$lib/types';

	const TYPES = ['TXN_APPROVAL', 'TXN_REVERSAL', 'KYC_APPROVAL', 'ACCOUNT_OPENING', 'LOAN_DECISION'];
	const scope = $derived(page.url.searchParams.get('scope') === 'all' ? 'all' : 'branch');

	const res = new Resource<ApprovalItem[]>();
	let kind = $state('ALL');
	const load = (keep = false) => res.run(() => api.get<ApprovalItem[]>('/approvals', { scope }), keep);
	$effect(() => {
		void scope;
		void load();
	});

	function link(i: ApprovalItem): string | null {
		switch (i.request_type) {
			case 'TXN_APPROVAL':
			case 'TXN_REVERSAL':
				return `/transactions/${i.target_ref}`;
			case 'KYC_APPROVAL':
				return `/customers/${i.target_ref}`;
			case 'ACCOUNT_OPENING':
				return `/accounts/${i.target_ref}`;
			case 'LOAN_DECISION':
				return '/loans/applications';
			default:
				return null;
		}
	}

	// ---- decisions ----
	let current = $state<ApprovalItem | null>(null);
	let approveOpen = $state(false);
	let rejectOpen = $state(false);
	let risk = $state('MEDIUM');
	let margin = $state('10');
	let amount = $state('');
	let term = $state('');
	let busy = $state(false);
	let error = $state('');

	function startApprove(i: ApprovalItem) {
		current = i;
		risk = 'MEDIUM';
		margin = '10';
		amount = '';
		term = '';
		error = '';
		approveOpen = true;
	}
	function startReject(i: ApprovalItem) {
		current = i;
		rejectOpen = true;
	}

	const marginBad = $derived(current?.request_type === 'LOAN_DECISION' && (margin === '' || Number(margin) < 0 || Number(margin) > 40));

	async function approve() {
		if (!current || marginBad) return;
		busy = true;
		error = '';
		const body: Record<string, unknown> = {};
		if (current.request_type === 'KYC_APPROVAL') body.risk_rating = risk;
		if (current.request_type === 'LOAN_DECISION') {
			body.margin_pct = Number(margin);
			if (amount) body.amount = Number(amount);
			if (term) body.term_months = Number(term);
		}
		try {
			const r = await api.post<{ reversal_txn_ref?: string }>(`/approvals/${current.request_id}/approve`, body);
			const what = inline(current.request_type);
			toast.success(
				r.reversal_txn_ref ? `Approved: reversal posted as ${r.reversal_txn_ref}.` : `Approved the ${what} of ${current.target_ref}.`,
				r.reversal_txn_ref ? { href: `/transactions/${r.reversal_txn_ref}`, text: 'View' } : undefined
			);
			approveOpen = false;
			await load(true);
		} catch (e) {
			error = e instanceof ApiError ? e.message : 'The approval failed.';
		} finally {
			busy = false;
		}
	}

	async function reject(reason: string) {
		if (!current) return;
		try {
			await api.post(`/approvals/${current.request_id}/reject`, { reason });
			toast.success(`Rejected the ${inline(current.request_type)} of ${current.target_ref}.`);
			rejectOpen = false;
			await load(true);
		} catch (e) {
			rejectOpen = false;
			toast.error(e instanceof ApiError ? e.message : 'The rejection failed.');
		}
	}
</script>

<Title text="Approval queue" subtitle="Maker-checker" />

<RoleGate roles={['WB_SUPERVISOR', 'WB_KYC_APPROVER', 'WB_CREDIT']}>
	<div class="stack">
		<div class="notice">
			<strong>Maker-checker.</strong> Someone prepares the work and someone else approves it: you cannot approve your own work, and each kind of request needs its own role.
			Requests you may not decide are shown without action buttons.
		</div>

		<Card>
			<div class="filters">
				<label>Scope
					<select value={scope} onchange={(e) => setParams({ scope: e.currentTarget.value })}>
						<option value="branch">My branch (and loan decisions)</option>
						<option value="all">All branches</option>
					</select>
				</label>
			</div>
		</Card>

		<Async {res} onretry={() => load()}>
			{#snippet children(all)}
				{@const counts = Object.fromEntries(TYPES.map((t) => [t, all.filter((x) => x.request_type === t).length]))}
				{@const tabs = [{ id: 'ALL', label: 'All', count: all.length }, ...TYPES.filter((t) => counts[t] > 0).map((t) => ({ id: t, label: label(t), count: counts[t] }))]}
				{@const rows = kind === 'ALL' ? all : all.filter((x) => x.request_type === kind)}
				<Tabs {tabs} bind:active={kind} label="Request types" />
				{#if rows.length === 0}
					<Card><Empty title="Nothing waiting">All requests in this scope have been decided.</Empty></Card>
				{:else}
					<div class="table-wrap">
						<table class="table">
							<thead><tr><th>Request</th><th>Reference</th><th class="num">Amount</th><th>Reason / note</th><th>Requested by</th><th>Branch</th><th>Waiting</th><th>Decision</th></tr></thead>
							<tbody>
								{#each rows as i (i.request_id)}
									<tr class:row-warn={i.hours_waiting > 72}>
										<td><StatusBadge status={i.request_type} text={label(i.request_type)} /></td>
										<td>{#if link(i)}<a class="mono" href={link(i)!}>{i.target_ref}</a>{:else}<span class="mono">{i.target_ref}</span>{/if}</td>
										<td class="num">{#if i.amount !== null}<Money value={i.amount} currency={i.currency_code ?? 'GHS'} />{:else}<span class="faint">—</span>{/if}</td>
										<td>{i.reason ?? '—'}</td>
										<td>{i.requested_by_name}<br /><span class="faint">{formatDateTime(i.requested_at)}</span></td>
										<td>{i.branch_code ?? '—'}</td>
										<td class="num">{hoursText(i.hours_waiting)}</td>
										<td>
											{#if i.can_decide}
												<span class="row" style="gap: 6px; flex-wrap: nowrap">
													<button class="btn small primary" type="button" onclick={() => startApprove(i)}>Approve</button>
													{#if i.request_type !== 'TXN_REVERSAL'}<button class="btn small" type="button" onclick={() => startReject(i)}>Reject</button>{/if}
												</span>
											{:else}
												<span class="faint" title="Either your roles do not cover this request type, or you made the request yourself.">Not yours to decide</span>
											{/if}
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

	<Dialog bind:open={approveOpen} title="Approve {current ? inline(current.request_type) : ''}">
		{#if current}
			<p>Request <strong class="mono">{current.target_ref}</strong>{#if current.amount !== null}&nbsp;for <strong><Money value={current.amount} currency={current.currency_code ?? 'GHS'} /></strong>{/if}, made by {current.requested_by_name}.</p>
			{#if current.request_type === 'KYC_APPROVAL'}
				<FormField label="Risk rating" required hint="Sets how often the customer is reviewed and how closely their activity is watched.">
					<select bind:value={risk}><option value="LOW">Low</option><option value="MEDIUM">Medium</option><option value="HIGH">High</option></select>
				</FormField>
			{:else if current.request_type === 'LOAN_DECISION'}
				<FormField label="Margin over the reference rate (%)" required hint="Added to the Ghana Reference Rate to give the customer's rate." error={marginBad ? 'Enter a margin between 0 and 40.' : ''}>
					<input type="number" min="0" max="40" step="0.01" bind:value={margin} aria-invalid={marginBad} />
				</FormField>
				<div class="grid cols-2">
					<FormField label="Approved amount (GH₵)" hint="Empty: as requested."><input type="number" min="1" step="0.01" bind:value={amount} /></FormField>
					<FormField label="Approved term (months)" hint="Empty: as requested."><input type="number" min="1" max="360" bind:value={term} /></FormField>
				</div>
			{:else if current.request_type === 'TXN_REVERSAL'}
				<p class="muted">The reversal posts a counter-entry. The original transaction stays in the ledger.</p>
			{:else if current.request_type === 'TXN_APPROVAL'}
				<p class="muted">Approving posts the transaction to the ledger now.</p>
			{:else if current.request_type === 'ACCOUNT_OPENING'}
				<p class="muted">The account becomes active; debits still need the customer's verified KYC.</p>
			{/if}
			{#if error}<div class="notice error" role="alert">{error}</div>{/if}
		{/if}
		{#snippet actions()}
			<button class="btn" type="button" onclick={() => (approveOpen = false)} disabled={busy}>Cancel</button>
			<button class="btn primary" type="button" onclick={approve} disabled={busy || marginBad}>{#if busy}<Spinner />{/if} Approve</button>
		{/snippet}
	</Dialog>

	<ConfirmDialog bind:open={rejectOpen} title="Reject the request" confirmLabel="Reject" danger reasonLabel="Reason for rejecting" onconfirm={reject}>
		{#if current}<p>Reject the {inline(current.request_type)} of <strong class="mono">{current.target_ref}</strong>. The reason is kept with the request and shown to the person who made it.</p>{/if}
	</ConfirmDialog>
</RoleGate>
