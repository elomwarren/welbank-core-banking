<script lang="ts">
	import '../app.css';
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { afterNavigate } from '$app/navigation';
	import Sidebar from '$lib/components/Sidebar.svelte';
	import GlobalSearch from '$lib/components/GlobalSearch.svelte';
	import Toasts from '$lib/components/Toasts.svelte';
	import Spinner from '$lib/components/Spinner.svelte';
	import { session } from '$lib/session.svelte';
	import { pageTitle } from '$lib/pageTitle.svelte';

	let { children } = $props();
	let menuOpen = $state(false);

	const bare = $derived(page.url.pathname.startsWith('/login'));

	onMount(() => void session.load());

	// Not logged in (no valid session cookie): go to the login page and come back afterwards.
	$effect(() => {
		if (session.ready && !session.loggedIn && !bare && !session.problem) session.expire();
	});

	afterNavigate(() => (menuOpen = false));
</script>

{#if bare}
	{@render children()}
{:else if !session.ready}
	<div class="boot"><Spinner /> Loading…</div>
{:else if session.problem}
	<div class="boot">
		<div class="notice error" role="alert"><strong>WEL Bank cannot start.</strong> {session.problem.message}</div>
		<button class="btn" onclick={() => location.reload()}>Try again</button>
	</div>
{:else if session.loggedIn}
	<a class="skip" href="#content">Skip to content</a>
	<div class="shell">
		<div class="side" class:open={menuOpen}><Sidebar onnavigate={() => (menuOpen = false)} /></div>
		{#if menuOpen}<button class="scrim" aria-label="Close menu" onclick={() => (menuOpen = false)}></button>{/if}
		<div class="main">
			<header class="top">
				<button class="burger btn ghost" type="button" aria-label="Open menu" onclick={() => (menuOpen = true)}>
					<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M4 6h16M4 12h16M4 18h16" /></svg>
				</button>
				<div class="title">
					<h1>{pageTitle.text}</h1>
					{#if pageTitle.subtitle}<span class="muted">{pageTitle.subtitle}</span>{/if}
				</div>
				<GlobalSearch />
			</header>
			<main id="content" tabindex="-1">{@render children()}</main>
		</div>
	</div>
{/if}
<Toasts />

<style>
	.shell { display: flex; min-height: 100vh; }
	.side { position: sticky; top: 0; height: 100vh; flex: none; }
	.main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
	.top {
		position: sticky;
		top: 0;
		z-index: 20;
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		padding: 10px 28px;
		min-height: 60px;
		background: var(--surface);
		border-bottom: 1px solid var(--border);
	}
	.title { display: flex; align-items: baseline; gap: 12px; min-width: 0; }
	.title h1 { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	main { padding: 24px 28px 48px; max-width: 1500px; width: 100%; outline: none; }
	.burger { display: none; padding: 4px 8px; }
	.scrim { display: none; }
	.boot { min-height: 100vh; display: grid; place-content: center; justify-items: center; gap: 14px; color: var(--text-muted); }
	.skip { position: absolute; left: -999px; top: 8px; background: var(--gold-500); padding: 8px 14px; z-index: 200; border-radius: 4px; color: #000; }
	.skip:focus { left: 8px; }
	@media (max-width: 960px) {
		.side { position: fixed; z-index: 60; transform: translateX(-100%); transition: transform 0.2s; }
		.side.open { transform: none; }
		.scrim { display: block; position: fixed; inset: 0; z-index: 50; background: rgb(6 26 53 / 50%); border: 0; }
		.burger { display: inline-flex; }
		.top { padding: 8px 16px; }
		main { padding: 16px; }
		.title span { display: none; }
	}
</style>
