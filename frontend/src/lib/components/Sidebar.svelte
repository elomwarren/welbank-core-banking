<script lang="ts">
	import { page } from '$app/state';
	import Logo from './Logo.svelte';
	import { NAV } from '$lib/nav';
	import { session } from '$lib/session.svelte';

	let { onnavigate }: { onnavigate?: () => void } = $props();

	const groups = $derived(
		NAV.map((g) => ({ ...g, items: g.items.filter((i) => !i.roles || session.has(...i.roles)) })).filter((g) => g.items.length)
	);

	// The most specific matching item wins (so /customers/new does not also light up /customers).
	const allHrefs = NAV.flatMap((g) => g.items.map((i) => i.href));
	function isActive(href: string): boolean {
		const path = page.url.pathname;
		if (href === '/') return path === '/';
		const matches = allHrefs.filter((h) => h !== '/' && (path === h || path.startsWith(h + '/')));
		const best = matches.sort((a, b) => b.length - a.length)[0];
		return best === href;
	}
</script>

<aside class="sidebar">
	<a class="brand" href="/" aria-label="WEL Bank home"><Logo size={38} /></a>
	<nav aria-label="Main">
		{#each groups as group (group.title)}
			<div class="group">
				<h2>{group.title}</h2>
				{#each group.items as item (item.href)}
					<a href={item.href} class:active={isActive(item.href)} aria-current={isActive(item.href) ? 'page' : undefined} onclick={onnavigate}>
						<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={item.icon} /></svg>
						{item.label}
					</a>
				{/each}
			</div>
		{/each}
	</nav>
	{#if session.employee}
		{@const e = session.employee}
		<div class="me">
			<div class="avatar" aria-hidden="true">{e.full_name.split(' ').map((p) => p[0]).slice(0, 2).join('')}</div>
			<div class="who">
				<strong>{e.full_name}</strong>
				<span>{e.job_title}</span>
				<span>{e.branch_name ?? 'Head office'}{e.branch_code ? ` · ${e.branch_code}` : ''}</span>
			</div>
			<div class="links">
				<a href="/account/password" onclick={onnavigate}>Password</a>
				<button type="button" onclick={() => session.logout()}>Log out</button>
			</div>
		</div>
	{/if}
</aside>

<style>
	.sidebar {
		width: var(--sidebar-w);
		background: linear-gradient(180deg, var(--navy-900), var(--navy-950));
		color: #d7e2f2;
		display: flex;
		flex-direction: column;
		height: 100%;
		overflow-y: auto;
	}
	.brand { padding: 18px 18px 14px; border-bottom: 3px solid var(--gold-500); text-decoration: none; display: block; }
	nav { padding: 8px 10px; flex: 1; }
	.group { margin-bottom: 8px; }
	h2 { color: #8fa6c6; font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; padding: 10px 10px 4px; font-weight: 700; }
	nav a {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 8px 10px;
		color: #d7e2f2;
		border-radius: 6px;
		text-decoration: none;
		font-weight: 500;
	}
	nav a:hover { background: rgb(255 255 255 / 8%); }
	nav a.active { background: rgb(200 150 46 / 22%); color: #fff; box-shadow: inset 3px 0 0 var(--gold-500); }
	nav a:focus-visible, .links a:focus-visible, .links button:focus-visible { outline-color: var(--gold-300); }
	.me { border-top: 1px solid rgb(255 255 255 / 14%); padding: 14px 16px; display: grid; grid-template-columns: auto 1fr; gap: 4px 10px; }
	.avatar { grid-row: span 2; width: 38px; height: 38px; border-radius: 50%; background: var(--gold-500); color: #2b1d00; display: grid; place-items: center; font-weight: 800; }
	.who { display: grid; font-size: 12.5px; line-height: 1.35; }
	.who strong { color: #fff; font-size: 13.5px; }
	.who span { color: #a9bddb; }
	.links { grid-column: 1 / -1; display: flex; gap: 8px; margin-top: 6px; }
	.links a, .links button { flex: 1; text-align: center; padding: 6px; border-radius: 5px; border: 1px solid rgb(255 255 255 / 25%); background: transparent; color: #fff; font: inherit; font-size: 13px; cursor: pointer; text-decoration: none; }
	.links a:hover, .links button:hover { background: rgb(255 255 255 / 12%); }
</style>
