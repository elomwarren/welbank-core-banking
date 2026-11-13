<script lang="ts">
	// Sets the top-bar title and the browser tab title for the current page.
	import { pageTitle } from '$lib/pageTitle.svelte';

	let { text, subtitle = '' }: { text: string; subtitle?: string } = $props();

	$effect(() => {
		pageTitle.text = text;
		pageTitle.subtitle = subtitle;
	});
</script>

<!-- The bank's name comes first, so it stays visible in a narrow browser tab. -->
<svelte:head><title>{text ? `WEL Bank · ${text}` : 'WEL Bank'}</title></svelte:head>
