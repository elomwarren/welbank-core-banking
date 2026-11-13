<script lang="ts">
	import { ApiError } from '$lib/api';

	let { error, onretry }: { error: ApiError; onretry?: () => void } = $props();
</script>

{#if error.status === 403}
	<div class="forbidden">
		<div class="big" aria-hidden="true">403</div>
		<h2>You do not have access to this</h2>
		<p class="muted">{error.message}</p>
		<p class="muted">Your roles do not include this function. Ask your branch manager or the DBA if you need it.</p>
		<a class="btn" href="/">Back to the dashboard</a>
	</div>
{:else}
	<div class="notice error" role="alert">
		<strong>{error.status === 503 ? 'Database unavailable.' : error.status === 404 ? 'Not found.' : 'Something went wrong.'}</strong>
		{error.message}
		{#if onretry}<button class="btn small" type="button" onclick={onretry} style="margin-left: 10px">Try again</button>{/if}
	</div>
{/if}

<style>
	.forbidden { display: grid; justify-items: center; gap: 8px; padding: 48px 16px; text-align: center; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); }
	.big { font-size: 56px; font-weight: 800; color: var(--gold-500); line-height: 1; }
</style>
