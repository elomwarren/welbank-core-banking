<script lang="ts">
	import { goto } from '$app/navigation';
	import Card from '$lib/components/Card.svelte';
	import PasswordForm from '$lib/components/PasswordForm.svelte';
	import Title from '$lib/components/Title.svelte';
	import { session } from '$lib/session.svelte';
	import { toast } from '$lib/toast.svelte';

	let username = $state(session.employee?.username ?? '');

	async function done() {
		// The API ends every session of this employee after a password change.
		session.employee = null;
		toast.success('Password changed. Log in with the new password.');
		await goto('/login');
	}
</script>

<Title text="Change password" subtitle="Oracle enforces the password rules" />

<div class="narrow">
	<Card title="Change your password">
		<p class="muted">After the change all your sessions end and you log in again with the new password.</p>
		<PasswordForm bind:username lockUsername ondone={done} />
	</Card>
</div>

<style>
	.narrow { max-width: 480px; }
</style>
