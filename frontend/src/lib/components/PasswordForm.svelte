<script lang="ts">
	// Change-password form: Oracle checks the rules (length, complexity, no reuse), its message is shown as is.
	import FormField from './FormField.svelte';
	import Spinner from './Spinner.svelte';
	import { api, ApiError } from '$lib/api';

	let {
		username = $bindable(''),
		lockUsername = false,
		ondone
	}: { username?: string; lockUsername?: boolean; ondone: () => void } = $props();

	let current = $state('');
	let next = $state('');
	let again = $state('');
	let busy = $state(false);
	let error = $state('');
	let touched = $state(false);

	const mismatch = $derived(again !== next);
	const tooShort = $derived(next.length < 8);

	async function submit(e: SubmitEvent) {
		e.preventDefault();
		touched = true;
		error = '';
		if (mismatch || tooShort || !current || !username) return;
		busy = true;
		try {
			await api.post('/auth/password', { username: username.trim().toUpperCase(), current_password: current, new_password: next }, { quiet401: true });
			ondone();
		} catch (e) {
			error = e instanceof ApiError ? e.message : 'The password could not be changed.';
		} finally {
			busy = false;
		}
	}
</script>

<form class="form" onsubmit={submit} novalidate>
	<FormField label="User name" required>
		<input type="text" bind:value={username} readonly={lockUsername} autocomplete="username" required />
	</FormField>
	<FormField label="Current password" required error={touched && !current ? 'Enter your current password.' : ''}>
		<input type="password" bind:value={current} autocomplete="current-password" aria-invalid={touched && !current} />
	</FormField>
	<FormField label="New password" required hint="At least 8 characters; Oracle also requires a mix of letters, digits and symbols." error={touched && tooShort ? 'The new password needs at least 8 characters.' : ''}>
		<input type="password" bind:value={next} autocomplete="new-password" aria-invalid={touched && tooShort} />
	</FormField>
	<FormField label="Repeat the new password" required error={touched && mismatch ? 'The two passwords differ.' : ''}>
		<input type="password" bind:value={again} autocomplete="new-password" aria-invalid={touched && mismatch} />
	</FormField>
	{#if error}<div class="notice error" role="alert">{error}</div>{/if}
	<button class="btn primary" type="submit" disabled={busy}>{#if busy}<Spinner />{/if} Change password</button>
</form>

<style>
	.form { display: grid; gap: 14px; }
</style>
