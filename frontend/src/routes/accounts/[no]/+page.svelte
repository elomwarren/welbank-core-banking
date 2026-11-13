<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import Money from '$lib/components/Money.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Pagination from '$lib/components/Pagination.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { formatDate, formatDateTime, formatNumber, label } from '$lib/format';
	import type { AccountDetail, StatementLine } from '$lib/types';

	const TAKE = 25;
	const no = $derived(page.params.no ?? '');
	const res = new Resource<AccountDetail>();
	const stmt = new Resource<StatementLine[]>();
	let skip = $state(0);

	$effect(() => {
		const current = no;
		skip = 0;
		void res.run(() => api.get<AccountDetail>(`/accounts/${current}`));
	});
	$effect(() => {
		const current = no;
		const s = skip;
		void stmt.run(() => api.get<StatementLine[]>(`/accounts/${current}/statement`, { skip: s, take: TAKE }), true);
	});
</script>

<Title text={res.data?.account.account_name ?? 'Account'} subtitle={no} />

<Async {res}>
	{#snippet children(d)}
		{@const a = d.account}
		<div class="stack">
			<div class="grid cols-3">
				<Card title="Balances">
					<div class="bals">
						<div><span class="lbl">Ledger balance</span><strong class="big"><Money value={a.ledger_balance} currency={a.currency_code} /></strong></div>
						<div><span class="lbl">Available balance</span><strong class="big"><Money value={a.available_balance} currency={a.currency_code} /></strong></div>
						{#if a.overdraft_limit}<div><span class="lbl">Overdraft limit</span><Money value={a.overdraft_limit} currency={a.currency_code} /></div>{/if}
					</div>
				</Card>
				<Card title="Account">
					<dl class="facts">
						<dt>Number</dt><dd class="mono">{a.account_no}</dd>
						<dt>Status</dt><dd><StatusBadge status={a.status} />{#if a.post_no_debit}&nbsp;<StatusBadge status="BLOCKED" text="Post no debit" />{/if}</dd>
						<dt>Product</dt><dd>{a.product_name ?? label(a.account_class)}</dd>
						<dt>Interest rate</dt><dd>{a.interest_rate !== null ? `${formatNumber(a.interest_rate, 2)}% a year` : '—'}</dd>
						<dt>Currency</dt><dd>{a.currency_code}</dd>
						<dt>Mandate</dt><dd>{label(a.mandate)}</dd>
					</dl>
				</Card>
				<Card title="Opening">
					<dl class="facts">
						<dt>Branch</dt><dd>{a.branch_name} ({a.branch_code})</dd>
						<dt>Opened</dt><dd>{formatDate(a.opened_on)}</dd>
						<dt>Opened by</dt><dd>{a.opened_by ?? '—'}</dd>
						<dt>Approved by</dt><dd>{a.checked_by ?? '—'}{#if a.checked_at}{' · '}{formatDate(a.checked_at)}{/if}</dd>
						<dt>Last activity</dt><dd>{formatDateTime(a.last_activity_at)}</dd>
						{#if a.closed_on}<dt>Closed</dt><dd>{formatDate(a.closed_on)}</dd>{/if}
					</dl>
				</Card>
			</div>

			<Card title="Holders" flush>
				<div class="table-wrap"><table class="table">
					<thead><tr><th>Customer no.</th><th>Name</th><th>Role</th><th>KYC</th></tr></thead>
					<tbody>
						{#each d.holders as h (h.customer_no)}
							<tr><td><a class="mono" href="/customers/{h.customer_no}">{h.customer_no}</a></td><td>{h.full_name}</td><td>{label(h.holder_role)}</td><td><StatusBadge status={h.kyc_status} /></td></tr>
						{/each}
					</tbody>
				</table></div>
			</Card>

			<Card title="Statement" subtitle="Newest first, with the balance after each line" flush>
				<Async res={stmt}>
					{#snippet children(lines)}
						{#if lines.length === 0}
							<Empty title="No movements yet">Deposits, withdrawals and transfers will show here.</Empty>
						{:else}
							<div class="table-wrap"><table class="table">
								<thead><tr><th>Date</th><th>Reference</th><th>Type</th><th>Narration</th><th class="num">Debit</th><th class="num">Credit</th><th class="num">Balance after</th></tr></thead>
								<tbody>
									{#each lines as l (l.entry_id)}
										<tr>
											<td>{formatDate(l.value_date)}</td>
											<td><a class="mono" href="/transactions/{l.txn_ref}">{l.txn_ref}</a></td>
											<td>{label(l.txn_type)}</td>
											<td>{l.narration ?? '—'}</td>
											<td class="num">{#if l.debit}<Money value={l.debit} currency={a.currency_code} />{/if}</td>
											<td class="num">{#if l.credit}<Money value={l.credit} currency={a.currency_code} />{/if}</td>
											<td class="num"><Money value={l.balance_after} currency={a.currency_code} /></td>
										</tr>
									{/each}
								</tbody>
							</table></div>
							<Pagination {skip} take={TAKE} shown={lines.length} onchange={(s) => (skip = s)} />
						{/if}
					{/snippet}
				</Async>
			</Card>
		</div>
	{/snippet}
</Async>

<style>
	.bals { display: grid; gap: 12px; }
	.lbl { display: block; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; color: var(--text-muted); }
	.big { font-size: 24px; color: var(--navy-900); }
</style>
