<script lang="ts">
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import BarChart from '$lib/components/BarChart.svelte';
	import Hbars from '$lib/components/Hbars.svelte';
	import Money from '$lib/components/Money.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import StatCard from '$lib/components/StatCard.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { formatMoney, formatMonth, formatNumber, label } from '$lib/format';
	import type { ReportSummary } from '$lib/types';

	const res = new Resource<ReportSummary>();
	const load = () => res.run(() => api.get<ReportSummary>('/reports/summary'));
	$effect(() => void load());

	const TYPE_COLORS: Record<string, string> = { CASH_DEPOSIT: '#1b7f4b', CASH_WITHDRAWAL: '#b3261e', TRANSFER: '#1b4d8c' };
	const CLASS_COLORS: Record<string, string> = { CURRENT: '#1b7f4b', OLEM: '#c8962e', SUBSTANDARD: '#d9731f', DOUBTFUL: '#b3261e', LOSS: '#7a0f1a' };
	const KYC_COLORS: Record<string, string> = { VERIFIED: '#1b7f4b', PENDING_VERIFICATION: '#c8962e', REVIEW_DUE: '#d9731f', DEFERRED: '#1b4d8c', REJECTED: '#b3261e' };

	function volume(r: ReportSummary) {
		const months = [...new Set(r.monthly_volume.map((m) => m.month))].sort();
		return {
			categories: months.map(formatMonth),
			series: Object.keys(TYPE_COLORS).map((t) => ({
				name: label(t),
				color: TYPE_COLORS[t],
				values: months.map((m) => r.monthly_volume.find((x) => x.month === m && x.txn_type === t)?.amount ?? 0)
			}))
		};
	}
</script>

<Title text="Management reports" subtitle="Whole bank" />

<RoleGate roles={['WB_REPORTS', 'WB_AUDITOR']}>
	<Async {res} onretry={load} rows={8}>
		{#snippet children(r)}
			{@const lc = r.ledger_check}
			{@const balanced = lc.accounts_out_of_balance === 0 && Math.abs(lc.total_debits - lc.total_credits) < 0.005}
			{@const totalOut = r.loan_book.reduce((s, x) => s + x.outstanding, 0)}
			{@const totalProv = r.loan_book.reduce((s, x) => s + x.provision, 0)}
			<div class="stack">
				<div class="grid cols-3">
					<Card title="Ledger integrity">
						<div class="integrity {balanced ? 'ok' : 'bad'}">
							<span class="mark" aria-hidden="true">{balanced ? '✓' : '!'}</span>
							<div>
								<strong>{balanced ? 'The ledger balances' : 'The ledger is OUT OF BALANCE'}</strong>
								<div class="muted">Total debits {balanced ? '=' : '≠'} total credits</div>
							</div>
						</div>
						<dl class="facts" style="margin-top: 12px">
							<dt>Total debits</dt><dd class="num"><Money value={lc.total_debits} /></dd>
							<dt>Total credits</dt><dd class="num"><Money value={lc.total_credits} /></dd>
							<dt>Accounts checked</dt><dd class="num">{formatNumber(lc.accounts_checked)}</dd>
							<dt>Accounts out of balance</dt><dd class="num"><StatusBadge status={lc.accounts_out_of_balance === 0 ? 'POSTED' : 'REJECTED'} text={String(lc.accounts_out_of_balance)} /></dd>
						</dl>
					</Card>
					<StatCard label="Non-performing loan ratio" tone={r.npl_ratio_pct > 10 ? 'bad' : r.npl_ratio_pct > 5 ? 'warn' : 'good'} hint="Substandard, doubtful and loss loans over the gross book">{formatNumber(r.npl_ratio_pct, 2)}%</StatCard>
					<div class="stack" style="align-content: start">
						<StatCard label="Gross loan book"><Money value={totalOut} /></StatCard>
						<StatCard label="Provisions required" tone="warn"><Money value={totalProv} /></StatCard>
					</div>
				</div>

				<Card title="Loan book by Bank of Ghana classification" subtitle="Provision = outstanding × the class's provision percentage" flush>
					<div class="table-wrap"><table class="table">
						<thead><tr><th>Class</th><th>Name</th><th class="num">Loans</th><th class="num">Principal</th><th class="num">Outstanding</th><th class="num">Provision %</th><th class="num">Provision</th></tr></thead>
						<tbody>
							{#each r.loan_book as b (b.class_code)}
								<tr>
									<td><StatusBadge status={b.class_code} /></td>
									<td>{b.class_name}{#if b.is_non_performing}&nbsp;<span class="faint">(non-performing)</span>{/if}</td>
									<td class="num">{formatNumber(b.loans)}</td>
									<td class="num"><Money value={b.principal} /></td>
									<td class="num"><Money value={b.outstanding} /></td>
									<td class="num">{formatNumber(b.provision_pct, 0)}%</td>
									<td class="num"><Money value={b.provision} /></td>
								</tr>
							{/each}
						</tbody>
						<tfoot><tr><td colspan="2">Total</td><td class="num">{formatNumber(r.loan_book.reduce((s, x) => s + x.loans, 0))}</td><td class="num"><Money value={r.loan_book.reduce((s, x) => s + x.principal, 0)} /></td><td class="num"><Money value={totalOut} /></td><td></td><td class="num"><Money value={totalProv} /></td></tr></tfoot>
					</table></div>
					<div class="inner">
						<Hbars items={r.loan_book.map((b) => ({ label: b.class_name.length > 22 ? label(b.class_code) : b.class_name, value: b.outstanding, color: CLASS_COLORS[b.class_code] }))} format={(v) => formatMoney(v)} />
					</div>
				</Card>

				<div class="grid cols-2">
					<Card title="Volume, last 12 months" subtitle="Posted GHS transactions by type">
						{@const v = volume(r)}
						<BarChart categories={v.categories} series={v.series} height={280} title="Monthly volume by type" />
					</Card>
					<div class="stack" style="align-content: start">
						<Card title="Customers by KYC status">
							<Hbars items={r.customers_by_kyc.map((k) => ({ label: label(k.kyc_status), value: k.customers, color: KYC_COLORS[k.kyc_status] }))} format={(n) => formatNumber(n)} />
						</Card>
						<Card title="Deposits by product" flush>
							<div class="table-wrap"><table class="table">
								<thead><tr><th>Product</th><th class="num">Accounts</th><th class="num">Balance</th></tr></thead>
								<tbody>{#each r.deposits_by_product as p (p.product_code)}<tr><td>{p.product_name}</td><td class="num">{formatNumber(p.accounts)}</td><td class="num"><Money value={p.balance} currency={p.currency_code} /></td></tr>{/each}</tbody>
							</table></div>
						</Card>
					</div>
				</div>

				<Card title="Branch league table" subtitle="Ranked by customer deposits (GHS)" flush>
					<div class="table-wrap"><table class="table">
						<thead><tr><th class="num">#</th><th>Branch</th><th>Region</th><th class="num">Customers</th><th class="num">Deposits</th><th class="num">Active loans</th></tr></thead>
						<tbody>
							{#each r.branches as b, i (b.branch_code)}
								<tr><td class="num">{i + 1}</td><td><strong>{b.branch_name}</strong> <span class="faint mono">{b.branch_code}</span></td><td>{b.region_name}</td><td class="num">{formatNumber(b.customers)}</td><td class="num"><Money value={b.deposits_ghs} /></td><td class="num">{formatNumber(b.active_loans)}</td></tr>
							{/each}
						</tbody>
					</table></div>
				</Card>
			</div>
		{/snippet}
	</Async>
</RoleGate>

<style>
	.integrity { display: flex; gap: 14px; align-items: center; padding: 12px; border-radius: var(--radius); }
	.integrity.ok { background: var(--green-bg); color: #12592f; }
	.integrity.bad { background: var(--red-bg); color: #7d1a14; }
	.mark { width: 40px; height: 40px; border-radius: 50%; display: grid; place-items: center; font-size: 22px; font-weight: 800; color: #fff; background: var(--green); flex: none; }
	.bad .mark { background: var(--red); }
	.inner { padding: 16px 18px; border-top: 1px solid var(--border); }
</style>
