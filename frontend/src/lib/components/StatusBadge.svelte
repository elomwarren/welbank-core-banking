<script lang="ts">
	import { label } from '$lib/format';

	let { status, text }: { status: string | null | undefined; text?: string } = $props();

	type Tone = 'green' | 'amber' | 'red' | 'darkred' | 'blue' | 'grey';
	const TONES: Record<string, Tone> = {
		// good
		POSTED: 'green', VERIFIED: 'green', ACTIVE: 'green', APPROVED: 'green', PAID: 'green', MATCH: 'green',
		CLEAR: 'green', CURRENT: 'green', SUCCESS: 'green', SUCCEEDED: 'green', LOW: 'green', OPEN: 'green',
		ENABLED: 'green', ARCHIVELOG: 'green', YES: 'green', OK: 'green', DISBURSED: 'green', COMPLETED: 'green',
		'READ WRITE': 'green', RUNNING: 'green', SCHEDULED: 'green', CLOSED_PAID: 'green',
		// waiting
		PENDING: 'amber', PENDING_APPROVAL: 'amber', SUBMITTED: 'amber', PENDING_REVIEW: 'amber', MEDIUM: 'amber',
		PARTIAL: 'amber', OLEM: 'amber', DUE: 'amber', UNVERIFIED: 'amber', IN_REVIEW: 'amber', DRAFT: 'amber',
		POTENTIAL_MATCH: 'amber', DEFERRED: 'amber', NOT_SCREENED: 'amber', NOT_SUBMITTED: 'amber', PENDING_KYC: 'amber',
		// bad
		REJECTED: 'red', FAILED: 'red', NO_MATCH: 'red', OVERDUE: 'red', SUBSTANDARD: 'red', HIGH: 'red',
		BLOCKED: 'red', FROZEN: 'red', SUSPENDED: 'red', DORMANT: 'red', EXPIRED: 'red', DISABLED: 'red', NO: 'red',
		DOUBTFUL: 'darkred', LOSS: 'darkred', WRITTEN_OFF: 'darkred',
		// neutral
		REVERSED: 'grey', CLOSED: 'grey', CANCELLED: 'grey', NA: 'grey', INACTIVE: 'grey', MATURED: 'grey',
		DR: 'blue', CR: 'blue', MOBILE: 'blue', EMAIL: 'blue'
	};

	const tone = $derived(TONES[(status ?? '').toUpperCase()] ?? 'grey');
	const shown = $derived(text ?? label(status));
</script>

<span class="badge {tone}">{shown}</span>

<style>
	.badge {
		display: inline-block;
		padding: 2px 9px;
		border-radius: 999px;
		font-size: 12px;
		font-weight: 650;
		white-space: nowrap;
		border: 1px solid transparent;
	}
	.green { background: var(--green-bg); color: var(--green); border-color: #b3dcc5; }
	.amber { background: var(--amber-bg); color: var(--amber); border-color: #ecd08c; }
	.red { background: var(--red-bg); color: var(--red); border-color: #efb7b3; }
	.darkred { background: var(--darkred-bg); color: var(--darkred); border-color: #dca2aa; }
	.blue { background: var(--blue-bg); color: var(--blue); border-color: #b9d1ee; }
	.grey { background: var(--grey-bg); color: var(--grey); border-color: #cfd6e1; }
</style>
