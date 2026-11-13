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
	import { intParam, setParams } from '$lib/query';
	import { formatDate, label } from '$lib/format';
	import type { Txn } from '$lib/types';

	const TAKE = 25;
	const res = new Resource<Txn[]>();

	const scope = $derived(page.url.searchParams.get('scope') === 'mine' ? 'mine' : 'branch');
	const status = $derived(page.url.searchParams.get('status') ?? '');
	const skip = $derived(intParam('skip', 0));

	$effect(() => {
		const query = { scope, status, skip, take: TAKE };
		void res.run(() => api.get<Txn[]>('/transactions', query), true);
	});
</script>

<Title text="Transactions" subtitle={scope === 'mine' ? 'Started by me' : 'My branch'} />

<div class="stack">
	<Card>
		<div class="filters">
			<label>Show
				<select value={scope} onchange={(e) => setParams({ scope: e.currentTarget.value })}>
					<option value="branch">My branch</option>
					<option value="mine">Only my transactions</option>
				</select>
			</label>
			<label>Status
				<select value={status} onchange={(e) => setParams({ status: e.currentTarget.value })}>
					<option value="">All</option>
					{#each ['POSTED', 'PENDING', 'REJECTED', 'REVERSED'] as s (s)}<option value={s}>{label(s)}</option>{/each}
				</select>
			</label>
		</div>
	</Card>

	<Async {res}>
		{#snippet children(rows)}
			{#if rows.length === 0}
				<Card><Empty title="No transactions found">Nothing matches these filters.</Empty></Card>
			{:else}
				<div class="table-wrap">
					<table class="table">
						<thead><tr><th>Reference</th><th>Date</th><th>Type</th><th>Narration</th><th class="num">Amount</th><th>Status</th><th>By</th><th>Checked by</th></tr></thead>
						<tbody>
							{#each rows as t (t.txn_ref)}
								<tr>
									<td><a class="mono" href="/transactions/{t.txn_ref}">{t.txn_ref}</a></td>
									<td>{formatDate(t.value_date)}</td>
									<td>{label(t.txn_type)}</td>
									<td>{t.narration ?? '—'}</td>
									<td class="num"><Money value={t.amount} currency={t.currency_code} /></td>
									<td><StatusBadge status={t.status} />{#if t.rejection_reason}<br /><span class="faint">{t.rejection_reason}</span>{/if}</td>
									<td>{t.initiated_by ?? '—'}</td>
									<td>{t.checked_by ?? '—'}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
				<Pagination {skip} take={TAKE} shown={rows.length} onchange={(s) => setParams({ skip: s }, false)} />
			{/if}
		{/snippet}
	</Async>
</div>
