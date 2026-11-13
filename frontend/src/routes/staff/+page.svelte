<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { reference } from '$lib/reference.svelte';
	import { setParams } from '$lib/query';
	import { formatDate } from '$lib/format';
	import type { StaffMember } from '$lib/types';

	const res = new Resource<StaffMember[]>();
	let q = $state(page.url.searchParams.get('q') ?? '');

	$effect(() => {
		const sp = page.url.searchParams;
		q = sp.get('q') ?? '';
		const query = { q: sp.get('q'), branch: sp.get('branch'), take: 100 };
		void res.run(() => api.get<StaffMember[]>('/staff', query), true);
	});
	$effect(() => void reference.load().catch(() => {}));
	const branch = $derived(page.url.searchParams.get('branch') ?? '');
</script>

<Title text="Staff directory" subtitle="Names, jobs and branches" />

<div class="stack">
	<Card>
		<form class="filters" role="search" onsubmit={(e) => (e.preventDefault(), setParams({ q: q.trim() }))}>
			<label>Search<input type="search" bind:value={q} placeholder="Name, job or user name" style="min-width: 260px" /></label>
			<label>Branch
				<select value={branch} onchange={(e) => setParams({ branch: e.currentTarget.value })}>
					<option value="">All branches</option>
					{#each reference.data?.branches ?? [] as b (b.branch_id)}<option value={b.branch_code}>{b.branch_name}</option>{/each}
				</select>
			</label>
			<button class="btn primary" type="submit">Search</button>
		</form>
	</Card>

	<Async {res}>
		{#snippet children(rows)}
			{#if rows.length === 0}
				<Card><Empty title="Nobody found">Try a different name or branch.</Empty></Card>
			{:else}
				<div class="table-wrap"><table class="table">
					<thead><tr><th>Name</th><th>Job</th><th>Department</th><th>Branch</th><th>E-mail</th><th>Phone</th><th>Hired</th><th>Status</th></tr></thead>
					<tbody>
						{#each rows as s (s.employee_id)}
							<tr>
								<td><strong>{s.full_name}</strong><br /><span class="faint mono">{s.db_username}</span></td>
								<td>{s.job_title}</td><td>{s.department_name}</td><td>{s.branch_name}</td>
								<td>{#if s.work_email}<a href="mailto:{s.work_email}">{s.work_email}</a>{:else}—{/if}</td>
								<td class="mono">{s.phone ?? '—'}</td><td>{formatDate(s.hire_date)}</td><td><StatusBadge status={s.status} /></td>
							</tr>
						{/each}
					</tbody>
				</table></div>
				{#if rows.length >= 100}<p class="muted">Showing the first 100; narrow the search to see others.</p>{/if}
			{/if}
		{/snippet}
	</Async>
</div>
