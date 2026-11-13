<script lang="ts">
	// Shows the page only to employees holding one of the roles; others get the friendly 403 page.
	import type { Snippet } from 'svelte';
	import { session } from '$lib/session.svelte';
	import { ROLE_LABELS } from '$lib/roles';
	import type { Role } from '$lib/types';

	let { roles, children }: { roles: Role[]; children: Snippet } = $props();
</script>

{#if session.has(...roles)}
	{@render children()}
{:else}
	<div class="forbidden">
		<div class="big" aria-hidden="true">403</div>
		<h2>This page is not part of your job</h2>
		<p class="muted">It needs the role {roles.map((r) => ROLE_LABELS[r]).join(' or ')}.</p>
		<a class="btn" href="/">Back to the dashboard</a>
	</div>
{/if}

<style>
	.forbidden { display: grid; justify-items: center; gap: 8px; padding: 56px 16px; text-align: center; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); }
	.big { font-size: 56px; font-weight: 800; color: var(--gold-500); line-height: 1; }
</style>
