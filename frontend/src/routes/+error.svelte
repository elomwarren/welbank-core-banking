<script lang="ts">
	import { page } from '$app/state';
	import Title from '$lib/components/Title.svelte';
</script>

<Title text="Page not found" />

<div class="nf">
	<div class="big" aria-hidden="true">{page.status}</div>
	<h2>{page.status === 404 ? 'This page does not exist' : 'Something went wrong'}</h2>
	<p class="muted">{page.error?.message ?? 'Unexpected error.'}</p>
	<a class="btn primary" href="/">Back to the dashboard</a>
</div>

<style>
	.nf { display: grid; justify-items: center; gap: 8px; padding: 56px 16px; text-align: center; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); }
	.big { font-size: 56px; font-weight: 800; color: var(--gold-500); line-height: 1; }
</style>
