<script lang="ts">
	// Accessible tab list (arrow keys move between tabs). The caller renders the active panel.
	let {
		tabs,
		active = $bindable(),
		label = 'Sections'
	}: { tabs: { id: string; label: string; count?: number }[]; active: string; label?: string } = $props();

	function onkey(e: KeyboardEvent, index: number) {
		let next = index;
		if (e.key === 'ArrowRight') next = (index + 1) % tabs.length;
		else if (e.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
		else return;
		e.preventDefault();
		active = tabs[next].id;
		(e.currentTarget as HTMLElement).parentElement?.querySelectorAll<HTMLElement>('[role=tab]')[next]?.focus();
	}
</script>

<div class="tabs" role="tablist" aria-label={label}>
	{#each tabs as tab, i (tab.id)}
		<button
			type="button"
			role="tab"
			id="tab-{tab.id}"
			aria-selected={active === tab.id}
			aria-controls="panel-{tab.id}"
			tabindex={active === tab.id ? 0 : -1}
			class:on={active === tab.id}
			onclick={() => (active = tab.id)}
			onkeydown={(e) => onkey(e, i)}
		>
			{tab.label}{#if tab.count !== undefined}<span class="count">{tab.count}</span>{/if}
		</button>
	{/each}
</div>

<style>
	.tabs { display: flex; gap: 2px; border-bottom: 2px solid var(--border); overflow-x: auto; overflow-y: hidden; }
	button {
		font: inherit;
		font-weight: 600;
		padding: 9px 16px;
		background: none;
		border: 0;
		border-bottom: 3px solid transparent;
		margin-bottom: -2px;
		color: var(--text-muted);
		cursor: pointer;
		white-space: nowrap;
	}
	button:hover { color: var(--navy-900); background: var(--navy-50); }
	button.on { color: var(--navy-900); border-bottom-color: var(--gold-500); }
	.count { margin-left: 7px; padding: 0 7px; border-radius: 999px; background: var(--navy-100); color: var(--navy-900); font-size: 12px; }
</style>
