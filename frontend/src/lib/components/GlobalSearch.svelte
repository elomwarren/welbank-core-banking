<script lang="ts">
	import { goto } from '$app/navigation';

	let q = $state('');

	function submit(e: SubmitEvent) {
		e.preventDefault();
		const text = q.trim();
		if (text) void goto(`/customers?q=${encodeURIComponent(text)}`);
	}
</script>

<form role="search" onsubmit={submit}>
	<label class="sr-only" for="global-search">Search customers</label>
	<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="11" cy="11" r="7" /><path d="M20 20l-4-4" /></svg>
	<input id="global-search" type="search" placeholder="Search customer number, name or phone" bind:value={q} />
</form>

<style>
	form { position: relative; width: min(380px, 100%); }
	svg { position: absolute; left: 10px; top: 50%; transform: translateY(-50%); color: var(--text-faint); }
	input { padding-left: 32px !important; border-radius: 999px !important; background: var(--bg) !important; }
</style>
