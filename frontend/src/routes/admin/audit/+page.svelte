<script lang="ts">
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Tabs from '$lib/components/Tabs.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { formatDateTime, label } from '$lib/format';
	import type { AuditRow, AuditValues, DbAuditRow } from '$lib/types';

	let tab = $state('app');
	let entity = $state('');
	let username = $state('');
	let take = $state('100');
	let applied = $state({ entity: '', username: '', take: '100' });

	const app = new Resource<AuditRow[]>();
	const db = new Resource<DbAuditRow[]>();
	let open = $state<number | null>(null);

	$effect(() => {
		if (tab !== 'app') return;
		const q = { entity: applied.entity.trim(), username: applied.username.trim(), take: applied.take };
		void app.run(() => api.get<AuditRow[]>('/admin/audit-trail', q), true);
	});
	$effect(() => {
		if (tab !== 'db') return;
		const t = applied.take;
		void db.run(() => api.get<DbAuditRow[]>('/admin/database-audit', { take: t }), true);
	});

	function apply(e: SubmitEvent) {
		e.preventDefault();
		applied = { entity, username, take };
	}

	/** Old/new values are JSON objects (or JSON text); show them indented. */
	function pretty(value: AuditValues): string {
		if (value === null || value === '') return '—';
		if (typeof value !== 'string') return JSON.stringify(value, null, 2);
		try {
			return JSON.stringify(JSON.parse(value), null, 2);
		} catch {
			return value;
		}
	}
</script>

<Title text="Audit trail" subtitle="Immutable record of who did what" />

<RoleGate roles={['WB_AUDITOR']}>
	<div class="stack">
		<Tabs tabs={[{ id: 'app', label: 'Application audit trail' }, { id: 'db', label: 'Oracle Unified Audit' }]} bind:active={tab} label="Audit sources" />

		<Card>
			<form class="filters" onsubmit={apply}>
				{#if tab === 'app'}
					<label>Table<input type="text" bind:value={entity} placeholder="e.g. ACCOUNTS" /></label>
					<label>Database user<input type="text" bind:value={username} placeholder="e.g. AADONGO" /></label>
				{/if}
				<label>Rows
					<select bind:value={take}>{#each ['50', '100', '250', '500'] as n (n)}<option value={n}>{n}</option>{/each}</select>
				</label>
				<button class="btn primary" type="submit">Apply</button>
			</form>
		</Card>

		<div role="tabpanel" id="panel-{tab}" aria-labelledby="tab-{tab}">
			{#if tab === 'app'}
				<Async res={app}>
					{#snippet children(rows)}
						{#if rows.length === 0}
							<Card><Empty title="No audit records match" /></Card>
						{:else}
							<div class="table-wrap"><table class="table">
								<thead><tr><th></th><th>When</th><th>Event</th><th>Table</th><th>Record</th><th>Employee</th><th>DB user</th><th>Module</th></tr></thead>
								<tbody>
									{#each rows as a (a.audit_id)}
										<tr>
											<td><button class="btn small ghost" type="button" aria-expanded={open === a.audit_id} aria-label="Show old and new values of audit record {a.audit_id}" onclick={() => (open = open === a.audit_id ? null : a.audit_id)}>{open === a.audit_id ? '▾' : '▸'}</button></td>
											<td>{formatDateTime(a.event_time)}</td>
											<td><StatusBadge status={a.event_type === 'INSERT' ? 'POSTED' : a.event_type === 'DELETE' ? 'REJECTED' : 'PENDING'} text={a.event_type} /></td>
											<td class="mono">{a.entity_table}</td>
											<td class="mono">{a.entity_id ?? '—'}</td>
											<td>{a.employee ?? '—'}</td>
											<td class="mono">{a.db_user}{#if a.proxy_user}&nbsp;<span class="faint">via {a.proxy_user}</span>{/if}</td>
											<td>{a.module ?? '—'}</td>
										</tr>
										{#if open === a.audit_id}
											<tr class="detail">
												<td></td>
												<td colspan="7">
													<div class="grid cols-2">
														<div><strong>Old values</strong><pre>{pretty(a.old_values)}</pre></div>
														<div><strong>New values</strong><pre>{pretty(a.new_values)}</pre></div>
													</div>
													{#if a.client_identifier}<span class="faint">Client identifier: <span class="mono">{a.client_identifier}</span></span>{/if}
												</td>
											</tr>
										{/if}
									{/each}
								</tbody>
							</table></div>
						{/if}
					{/snippet}
				</Async>
			{:else}
				<Async res={db}>
					{#snippet children(rows)}
						{#if rows.length === 0}
							<Card><Empty title="No audited database events" /></Card>
						{:else}
							<div class="table-wrap"><table class="table">
								<thead><tr><th>When</th><th>Database user</th><th>Action</th><th>Object</th><th>Result</th><th>Policy</th></tr></thead>
								<tbody>
									{#each rows as r, i (i)}
										<tr>
											<td>{formatDateTime(r.event_timestamp)}</td>
											<td class="mono">{r.dbusername}{#if r.dbproxy_username}&nbsp;<span class="faint">via {r.dbproxy_username}</span>{/if}</td>
											<td>{label(r.action_name)}</td>
											<td class="mono">{r.object_schema ? `${r.object_schema}.` : ''}{r.object_name ?? '—'}</td>
											<td><StatusBadge status={r.return_code === 0 ? 'SUCCESS' : 'FAILED'} text={r.return_code === 0 ? 'Success' : `ORA-${String(r.return_code).padStart(5, '0')}`} /></td>
											<td class="mono">{r.unified_audit_policies}</td>
										</tr>
									{/each}
								</tbody>
							</table></div>
						{/if}
					{/snippet}
				</Async>
			{/if}
		</div>
	</div>
</RoleGate>

<style>
	.detail td { background: var(--surface-2); }
	pre { margin: 6px 0 0; padding: 10px; background: #0f1b2e; color: #d8e6fb; border-radius: 6px; font-size: 12px; max-height: 260px; overflow: auto; white-space: pre-wrap; word-break: break-word; }
</style>
