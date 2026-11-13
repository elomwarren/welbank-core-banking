<script lang="ts">
	import Card from '$lib/components/Card.svelte';
	import StatCard from '$lib/components/StatCard.svelte';
	import Money from '$lib/components/Money.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import BarChart from '$lib/components/BarChart.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { session } from '$lib/session.svelte';
	import { formatDate, formatMonth, formatNumber, label } from '$lib/format';
	import type { Dashboard } from '$lib/types';

	const res = new Resource<Dashboard>();
	const load = () => res.run(() => api.get<Dashboard>('/dashboard'));
	$effect(() => void load());

	const COLORS: Record<string, string> = { CASH_DEPOSIT: '#1b7f4b', CASH_WITHDRAWAL: '#b3261e', TRANSFER: '#1b4d8c' };

	function chart(data: Dashboard) {
		const months = [...new Set(data.monthly_activity.map((m) => m.month))].sort();
		const types = ['CASH_DEPOSIT', 'CASH_WITHDRAWAL', 'TRANSFER'];
		return {
			categories: months.map(formatMonth),
			series: types.map((t) => ({
				name: label(t),
				color: COLORS[t],
				values: months.map((m) => data.monthly_activity.find((a) => a.month === m && a.txn_type === t)?.amount ?? 0)
			}))
		};
	}

	const greeting = $derived.by(() => {
		const h = new Date().getHours();
		return h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
	});
</script>

<Title text="Dashboard" subtitle={session.employee?.branch_name ?? ''} />

<div class="stack">
	<p class="hello">{greeting}, <strong>{session.employee?.full_name.split(' ')[0]}</strong>. Here is {session.employee?.branch_name ?? 'your branch'} today.</p>

	<Async {res} onretry={load}>
		{#snippet children(d)}
			{@const s = d.stats}
			<div class="grid cols-4">
				<StatCard label="Customers">{formatNumber(s.customers)}</StatCard>
				<StatCard label="Active accounts">{formatNumber(s.active_accounts)}</StatCard>
				<StatCard label="Pending approvals" tone={s.pending_approvals ? 'warn' : 'good'} hint={s.pending_approvals ? 'waiting for a checker' : 'nothing waiting'}>{formatNumber(s.pending_approvals)}</StatCard>
				<StatCard label="Loans in arrears" tone={s.loans_in_arrears ? 'bad' : 'good'}>{formatNumber(s.loans_in_arrears)}</StatCard>
				<StatCard label="Transactions today">{formatNumber(s.transactions_today)}</StatCard>
				<StatCard label="Posted volume today"><Money value={s.volume_today_ghs} /></StatCard>
				<StatCard label="Branch deposits"><Money value={s.deposits_ghs} /></StatCard>
			</div>

			<div class="grid two">
				<Card title="Branch activity, last 6 months" subtitle="Posted GHS volume by transaction type">
					{@const c = chart(d)}
					<BarChart categories={c.categories} series={c.series} title="Branch activity by month" />
				</Card>
				<Card title="My recent transactions" flush>
					{#snippet actions()}<a class="btn small" href="/transactions?scope=mine">See all</a>{/snippet}
					{#if d.recent_transactions.length === 0}
						<Empty title="No transactions yet">Transactions you start at the counter appear here.</Empty>
					{:else}
						<div class="table-wrap">
							<table class="table">
								<thead><tr><th>Reference</th><th>Type</th><th class="num">Amount</th><th>Status</th></tr></thead>
								<tbody>
									{#each d.recent_transactions as t (t.txn_ref)}
										<tr>
											<td><a href="/transactions/{t.txn_ref}" class="mono">{t.txn_ref}</a><br /><span class="faint">{formatDate(t.value_date)}</span></td>
											<td>{label(t.txn_type)}</td>
											<td class="num"><Money value={t.amount} currency={t.currency_code} /></td>
											<td><StatusBadge status={t.status} /></td>
										</tr>
									{/each}
								</tbody>
							</table>
						</div>
					{/if}
				</Card>
			</div>
		{/snippet}
	</Async>
</div>

<style>
	.hello { margin: 0; font-size: 15px; color: var(--text-muted); }
	.two { grid-template-columns: 1.3fr 1fr; align-items: start; }
	@media (max-width: 1100px) { .two { grid-template-columns: 1fr; } }
</style>
