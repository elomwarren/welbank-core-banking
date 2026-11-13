<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import Money from '$lib/components/Money.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Pagination from '$lib/components/Pagination.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { reference } from '$lib/reference.svelte';
	import { session } from '$lib/session.svelte';
	import { intParam, setParams } from '$lib/query';
	import { formatDate, formatNumber, label } from '$lib/format';
	import type { Loan } from '$lib/types';

	const TAKE = 25;
	const res = new Resource<Loan[]>();
	const status = $derived(page.url.searchParams.get('status') ?? 'ACTIVE');
	const cls = $derived(page.url.searchParams.get('classification') ?? '');
	const branch = $derived(page.url.searchParams.get('branch') ?? '');
	const skip = $derived(intParam('skip', 0));

	$effect(() => {
		const query = { status, classification: cls, branch, skip, take: TAKE };
		void res.run(() => api.get<Loan[]>('/loans', query), true);
	});
	$effect(() => void reference.load().catch(() => {}));
</script>

<Title text="Loan book" subtitle="Worst arrears first" />

<RoleGate roles={['WB_LOAN_OFFICER', 'WB_CREDIT', 'WB_REPORTS', 'WB_AUDITOR']}>
	<div class="stack">
		<Card>
			<div class="filters">
				<label>Status
					<select value={status} onchange={(e) => setParams({ status: e.currentTarget.value === 'ACTIVE' ? '' : e.currentTarget.value })}>
						{#each ['ACTIVE', 'CLOSED', 'WRITTEN_OFF', 'ALL'] as s (s)}<option value={s}>{label(s)}</option>{/each}
					</select>
				</label>
				<label>Classification
					<select value={cls} onchange={(e) => setParams({ classification: e.currentTarget.value })}>
						<option value="">All classes</option>
						{#each ['CURRENT', 'OLEM', 'SUBSTANDARD', 'DOUBTFUL', 'LOSS'] as c (c)}<option value={c}>{label(c)}</option>{/each}
					</select>
				</label>
				<label>Branch
					<select value={branch} onchange={(e) => setParams({ branch: e.currentTarget.value })}>
						<option value="">All branches</option>
						{#each reference.data?.branches ?? [] as b (b.branch_id)}<option value={b.branch_code}>{b.branch_name}</option>{/each}
					</select>
				</label>
				<span style="flex: 1"></span>
				{#if session.has('WB_LOAN_OFFICER', 'WB_CREDIT')}<a class="btn gold" href="/loans/applications">Applications</a>{/if}
			</div>
		</Card>

		<Async {res}>
			{#snippet children(rows)}
				{#if rows.length === 0}
					<Card><Empty title="No loans match">Change the filters to see other loans.</Empty></Card>
				{:else}
					<div class="table-wrap">
						<table class="table">
							<thead><tr><th>Loan</th><th>Customer</th><th>Product</th><th class="num">Principal</th><th class="num">Rate</th><th class="num">Outstanding</th><th class="num">Days past due</th><th>Class</th><th>Branch</th><th>Matures</th></tr></thead>
							<tbody>
								{#each rows as l (l.loan_no)}
									<tr>
										<td><a class="mono" href="/loans/{l.loan_no}">{l.loan_no}</a></td>
										<td><a href="/customers/{l.customer_no}">{l.customer_name}</a></td>
										<td>{l.product_name}</td>
										<td class="num"><Money value={l.principal} /></td>
										<td class="num">{formatNumber(l.interest_rate, 2)}%</td>
										<td class="num"><Money value={l.outstanding} /></td>
										<td class="num" class:late={l.days_past_due > 0}>{l.days_past_due}</td>
										<td><StatusBadge status={l.classification} /></td>
										<td>{l.branch_code}</td>
										<td>{formatDate(l.maturity_date)}</td>
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
</RoleGate>

<style>
	.late { color: var(--red); font-weight: 700; }
</style>
