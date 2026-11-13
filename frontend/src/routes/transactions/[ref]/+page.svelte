<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import Money from '$lib/components/Money.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api, ApiError } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { session } from '$lib/session.svelte';
	import { toast } from '$lib/toast.svelte';
	import { formatDate, formatDateTime, label } from '$lib/format';
	import type { TxnDetail } from '$lib/types';

	const ref = $derived(page.params.ref ?? '');
	const res = new Resource<TxnDetail>();
	const load = (keep = false) => res.run(() => api.get<TxnDetail>(`/transactions/${ref}`), keep);
	$effect(() => {
		void ref;
		void load();
	});

	let reverse = $state(false);
	async function requestReversal(reason: string) {
		try {
			await api.post(`/transactions/${ref}/reversal-requests`, { reason });
			toast.success(`Reversal of ${ref} requested. A supervisor must approve it.`, { href: '/approvals', text: 'Approval queue' });
			reverse = false;
			await load(true);
		} catch (e) {
			reverse = false;
			toast.error(e instanceof ApiError ? e.message : 'The reversal could not be requested.');
		}
	}

	const canReverse = $derived(session.has('WB_TELLER', 'WB_SUPERVISOR'));
</script>

<Title text={ref} subtitle="Transaction" />

<Async {res} onretry={() => load()}>
	{#snippet children(d)}
		{@const t = d.transaction}
		{@const debits = d.lines.filter((l) => l.direction === 'DR').reduce((s, l) => s + l.amount, 0)}
		{@const credits = d.lines.filter((l) => l.direction === 'CR').reduce((s, l) => s + l.amount, 0)}
		<div class="stack">
			<div class="grid cols-2">
				<Card title="Transaction">
					{#snippet actions()}
						<StatusBadge status={t.status} />
						{#if canReverse && t.status === 'POSTED' && !t.reverses_txn_ref}<button class="btn small danger" type="button" onclick={() => (reverse = true)}>Request reversal</button>{/if}
					{/snippet}
					<dl class="facts">
						<dt>Reference</dt><dd class="mono">{t.txn_ref}</dd>
						<dt>Type</dt><dd>{label(t.txn_type)} · {label(t.channel)}</dd>
						<dt>Amount</dt><dd><strong><Money value={t.amount} currency={t.currency_code} /></strong></dd>
						<dt>Value date</dt><dd>{formatDate(t.value_date)}</dd>
						<dt>Posted</dt><dd>{formatDateTime(t.posted_at)}</dd>
						<dt>Narration</dt><dd>{t.narration ?? '—'}</dd>
						<dt>Branch</dt><dd>{t.branch_code ?? '—'}</dd>
						{#if t.reverses_txn_ref}<dt>Reverses</dt><dd><a class="mono" href="/transactions/{t.reverses_txn_ref}">{t.reverses_txn_ref}</a></dd>{/if}
					</dl>
				</Card>
				<Card title="Maker and checker">
					<dl class="facts">
						<dt>Started by</dt><dd>{t.initiated_by ?? '—'}</dd>
						<dt>Checked by</dt><dd>{t.checked_by ?? (t.status === 'PENDING' ? 'Waiting for a supervisor' : '—')}</dd>
						<dt>Checked at</dt><dd>{formatDateTime(t.checked_at)}</dd>
						{#if t.rejection_reason}<dt>Rejection reason</dt><dd>{t.rejection_reason}</dd>{/if}
					</dl>
					{#if t.status === 'PENDING'}<div class="notice warn" style="margin-top: 12px">Above the teller's limit: the ledger is not changed until a supervisor approves.</div>{/if}
				</Card>
			</div>

			<Card title="Double-entry lines" subtitle="Every transaction posts equal debits and credits" flush>
				{#if d.lines.length === 0}
					<div style="padding: 18px" class="muted">No ledger lines yet: the transaction is not posted.</div>
				{:else}
					<div class="table-wrap"><table class="table">
						<thead><tr><th>Account</th><th>Name</th><th>Class</th><th class="num">Debit</th><th class="num">Credit</th></tr></thead>
						<tbody>
							{#each d.lines as l, i (i)}
								<tr>
									<td>{#if l.account_class === 'CUSTOMER'}<a class="mono" href="/accounts/{l.account_no}">{l.account_no}</a>{:else}<span class="mono">{l.account_no}</span>{/if}</td>
									<td>{l.account_name}</td>
									<td>{label(l.account_class)}</td>
									<td class="num">{#if l.direction === 'DR'}<Money value={l.amount} currency={t.currency_code} />{/if}</td>
									<td class="num">{#if l.direction === 'CR'}<Money value={l.amount} currency={t.currency_code} />{/if}</td>
								</tr>
							{/each}
						</tbody>
						<tfoot>
							<tr>
								<td colspan="3">Totals {#if Math.abs(debits - credits) < 0.005}<StatusBadge status="POSTED" text="Debits = credits" />{:else}<StatusBadge status="REJECTED" text="Out of balance" />{/if}</td>
								<td class="num"><Money value={debits} currency={t.currency_code} /></td>
								<td class="num"><Money value={credits} currency={t.currency_code} /></td>
							</tr>
						</tfoot>
					</table></div>
				{/if}
			</Card>
		</div>
	{/snippet}
</Async>

<ConfirmDialog bind:open={reverse} title="Request a reversal" confirmLabel="Request reversal" danger reasonLabel="Reason for the reversal" onconfirm={requestReversal}>
	<p>Ask a supervisor to reverse <strong class="mono">{ref}</strong>. The original stays in the ledger; a counter-entry is posted when the supervisor approves.</p>
</ConfirmDialog>
