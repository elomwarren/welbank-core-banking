<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Pagination from '$lib/components/Pagination.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { session } from '$lib/session.svelte';
	import { reference } from '$lib/reference.svelte';
	import { intParam, setParams } from '$lib/query';
	import { formatDate, fullName, label } from '$lib/format';
	import type { CustomerRow } from '$lib/types';

	const TAKE = 25;
	const KYC = ['PENDING_VERIFICATION', 'VERIFIED', 'DEFERRED', 'REJECTED', 'REVIEW_DUE'];

	const res = new Resource<CustomerRow[]>();
	let q = $state(page.url.searchParams.get('q') ?? '');
	let kyc = $state(page.url.searchParams.get('kyc_status') ?? '');
	let branch = $state(page.url.searchParams.get('branch') ?? '');

	const skip = $derived(intParam('skip', 0));

	// The URL is the source of truth (so the global search, back button and bookmarks work).
	$effect(() => {
		const sp = page.url.searchParams;
		q = sp.get('q') ?? '';
		kyc = sp.get('kyc_status') ?? '';
		branch = sp.get('branch') ?? '';
		const query = { q: sp.get('q'), kyc_status: sp.get('kyc_status'), branch: sp.get('branch'), skip: intParam('skip', 0), take: TAKE };
		void res.run(() => api.get<CustomerRow[]>('/customers', query), true);
	});
	$effect(() => void reference.load().catch(() => {}));

	function search(e: SubmitEvent) {
		e.preventDefault();
		setParams({ q: q.trim(), kyc_status: kyc, branch });
	}
</script>

<Title text="Customers" subtitle="Search by customer number, name or phone" />

<div class="stack">
	<Card>
		<form class="filters" onsubmit={search} role="search">
			<label>Search<input type="search" bind:value={q} placeholder="CUS…, name or phone" style="min-width: 260px" /></label>
			<label>KYC status
				<select bind:value={kyc} onchange={() => setParams({ q: q.trim(), kyc_status: kyc, branch })}>
					<option value="">All</option>
					{#each KYC as k (k)}<option value={k}>{label(k)}</option>{/each}
				</select>
			</label>
			<label>Branch
				<select bind:value={branch} onchange={() => setParams({ q: q.trim(), kyc_status: kyc, branch })}>
					<option value="">All branches</option>
					{#each reference.data?.branches ?? [] as b (b.branch_id)}<option value={b.branch_code}>{b.branch_name} ({b.branch_code})</option>{/each}
				</select>
			</label>
			<button class="btn primary" type="submit">Search</button>
			{#if q || kyc || branch}<button class="btn" type="button" onclick={() => setParams({ q: '', kyc_status: '', branch: '' })}>Clear</button>{/if}
			<span class="grow"></span>
			{#if session.has('WB_CUSTOMER_SERVICE')}<a class="btn gold" href="/customers/new">+ New customer</a>{/if}
		</form>
	</Card>

	<Async {res}>
		{#snippet children(rows)}
			{#if rows.length === 0}
				<Card><Empty title="No customers found">Try another spelling, a phone number, or clear the filters.</Empty></Card>
			{:else}
				<div class="table-wrap">
					<table class="table">
						<thead>
							<tr><th>Customer no.</th><th>Name</th><th>Mobile</th><th>Date of birth</th><th>Branch</th><th>KYC</th><th>Risk</th><th>Status</th></tr>
						</thead>
						<tbody>
							{#each rows as c (c.customer_no)}
								<tr>
									<td><a class="mono" href="/customers/{c.customer_no}">{c.customer_no}</a></td>
									<td><strong>{fullName(c)}</strong></td>
									<td class="mono">{c.mobile ?? '—'}</td>
									<td>{formatDate(c.date_of_birth)}</td>
									<td>{c.branch_name}</td>
									<td><StatusBadge status={c.kyc_status} /></td>
									<td>{#if c.risk_rating}<StatusBadge status={c.risk_rating} />{:else}<span class="faint">—</span>{/if}</td>
									<td><StatusBadge status={c.status} /></td>
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

<style>
	.grow { flex: 1; }
</style>
