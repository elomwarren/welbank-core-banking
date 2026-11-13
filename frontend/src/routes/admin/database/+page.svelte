<script lang="ts">
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import StatCard from '$lib/components/StatCard.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Title from '$lib/components/Title.svelte';
	import { api } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { formatDateTime, formatNumber, label } from '$lib/format';
	import type { DatabaseStatus } from '$lib/types';

	const res = new Resource<DatabaseStatus>();
	const load = () => res.run(() => api.get<DatabaseStatus>('/admin/database'));
	$effect(() => void load());

	const tone = (ok: boolean) => (ok ? 'good' : 'bad');
	const truthy = (v: string | boolean) => v === true || v === 'YES' || v === 'TRUE' || v === 'ENABLED';
</script>

<Title text="Database" subtitle="Recovery readiness" />

<RoleGate roles={['WB_BACKUP_ADMIN']}>
	<Async {res} onretry={load} rows={8}>
		{#snippet children(d)}
			{@const db = d.database}
			<div class="stack">
				{#if db}
					<div class="grid cols-4">
						<StatCard label="Archive log mode" tone={tone(db.log_mode === 'ARCHIVELOG')} hint="Needed for point-in-time recovery">{db.log_mode}</StatCard>
						<StatCard label="Flashback" tone={tone(db.flashback_on === 'YES')} hint="Rewinds the database to a restore point">{db.flashback_on === 'YES' ? 'On' : db.flashback_on}</StatCard>
						<StatCard label="Force logging" tone={tone(db.force_logging === 'YES')} hint="No operation skips the redo log">{db.force_logging === 'YES' ? 'On' : db.force_logging}</StatCard>
						<StatCard label="Open mode">{db.open_mode}</StatCard>
					</div>
					<Card title="Instance">
						<dl class="facts">
							<dt>Database</dt><dd class="mono">{db.name}</dd>
							<dt>Version</dt><dd>{db.version_full}</dd>
							<dt>Host</dt><dd class="mono">{db.host_name}</dd>
							<dt>Started</dt><dd>{formatDateTime(db.startup_time)}</dd>
						</dl>
					</Card>
				{/if}

				<div class="grid cols-2">
					<Card title="Transparent Data Encryption: wallet" flush>
						{#if d.encryption.wallet.length === 0}<Empty title="No wallet information" />{:else}
							<div class="table-wrap"><table class="table">
								<thead><tr><th>Type</th><th>Status</th><th>Wallet type</th><th>Keystore mode</th></tr></thead>
								<tbody>{#each d.encryption.wallet as w, i (i)}<tr><td>{w.wrl_type}</td><td><StatusBadge status={w.status === 'OPEN' ? 'OPEN' : 'FAILED'} text={w.status} /></td><td>{w.wallet_type}</td><td>{w.keystore_mode}</td></tr>{/each}</tbody>
							</table></div>
						{/if}
					</Card>
					<Card title="Encrypted tablespaces" flush>
						{#if d.encryption.tablespaces.length === 0}<Empty title="No encrypted tablespaces">Data at rest is not yet encrypted.</Empty>{:else}
							<div class="table-wrap"><table class="table">
								<thead><tr><th>Tablespace</th><th>Algorithm</th><th>Encrypted</th></tr></thead>
								<tbody>{#each d.encryption.tablespaces as t (t.tablespace_name)}<tr><td class="mono">{t.tablespace_name}</td><td>{t.encryptionalg}</td><td><StatusBadge status={t.encryptedts === 'YES' ? 'YES' : 'NO'} text={t.encryptedts} /></td></tr>{/each}</tbody>
							</table></div>
						{/if}
					</Card>
				</div>

				<Card title="Backup runs" flush>
					{#if d.backups.length === 0}
						<Empty title="No backups recorded yet">Run <code>./scripts/db-backup.sh</code> to take the first backup; each run appears here.</Empty>
					{:else}
						<div class="table-wrap"><table class="table">
							<thead><tr><th class="num">Run</th><th>Type</th><th>Status</th><th>Started</th><th>Finished</th><th class="num">Size</th><th>Details</th></tr></thead>
							<tbody>
								{#each d.backups as b (b.run_id)}
									<tr><td class="num">{b.run_id}</td><td>{label(b.run_type)}</td><td><StatusBadge status={b.status} /></td><td>{formatDateTime(b.started_at)}</td><td>{formatDateTime(b.finished_at)}</td><td class="num">{b.output_mb !== null ? `${formatNumber(b.output_mb, 1)} MB` : '—'}</td><td>{b.details ?? '—'}</td></tr>
								{/each}
							</tbody>
						</table></div>
					{/if}
				</Card>

				<Card title="Restore points" flush>
					{#if d.restore_points.length === 0}
						<Empty title="No restore points">A guaranteed restore point lets you flash the database back before a risky change.</Empty>
					{:else}
						<div class="table-wrap"><table class="table">
							<thead><tr><th>Name</th><th class="num">SCN</th><th>Created</th><th>Guaranteed</th><th class="num">Storage</th></tr></thead>
							<tbody>{#each d.restore_points as r (r.name)}<tr><td class="mono">{r.name}</td><td class="num">{r.scn}</td><td>{formatDateTime(r.time)}</td><td>{r.guarantee_flashback_database}</td><td class="num">{formatNumber(r.storage_size / 1048576, 1)} MB</td></tr>{/each}</tbody>
						</table></div>
					{/if}
				</Card>

				<Card title="Scheduler jobs" flush>
					{#if d.jobs.length === 0}<Empty title="No scheduler jobs" />{:else}
						<div class="table-wrap"><table class="table">
							<thead><tr><th>Job</th><th>Enabled</th><th>State</th><th>Schedule</th><th>Last run</th><th>Next run</th><th class="num">Runs</th><th class="num">Failures</th><th>Last result</th></tr></thead>
							<tbody>
								{#each d.jobs as j (j.job_name)}
									<tr>
										<td class="mono">{j.job_name}</td>
										<td><StatusBadge status={truthy(j.enabled) ? 'ENABLED' : 'DISABLED'} /></td>
										<td>{label(j.state)}</td>
										<td class="mono small">{j.repeat_interval ?? '—'}</td>
										<td>{formatDateTime(j.last_start_date)}</td>
										<td>{formatDateTime(j.next_run_date)}</td>
										<td class="num">{formatNumber(j.run_count)}</td>
										<td class="num">{formatNumber(j.failure_count)}</td>
										<td>{#if j.last_status}<StatusBadge status={j.last_status} />{:else}—{/if}</td>
									</tr>
								{/each}
							</tbody>
						</table></div>
					{/if}
				</Card>
			</div>
		{/snippet}
	</Async>
</RoleGate>

<style>
	.small { font-size: 12px; }
</style>
