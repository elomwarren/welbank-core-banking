<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import Logo from '$lib/components/Logo.svelte';
	import FormField from '$lib/components/FormField.svelte';
	import PasswordForm from '$lib/components/PasswordForm.svelte';
	import Spinner from '$lib/components/Spinner.svelte';
	import { ApiError } from '$lib/api';
	import { session } from '$lib/session.svelte';
	import { toast } from '$lib/toast.svelte';

	let username = $state('');
	let password = $state('');
	let busy = $state(false);
	let error = $state<ApiError | null>(null);
	let mode = $state<'login' | 'change'>('login');
	let expired = $state(false);

	/** Only same-site paths are accepted as the place to return to. */
	function nextPath(): string {
		const next = page.url.searchParams.get('next') ?? '/';
		return next.startsWith('/') && !next.startsWith('//') && !next.startsWith('/login') ? next : '/';
	}

	async function submit(e: SubmitEvent) {
		e.preventDefault();
		if (!username.trim() || !password) return;
		busy = true;
		error = null;
		try {
			const result = await session.login(username.trim().toUpperCase(), password);
			if (result.password_warning) toast.show('info', result.password_warning, { href: '/account/password', text: 'Change it now' }, 20000);
			await goto(nextPath());
		} catch (e) {
			error = e instanceof ApiError ? e : new ApiError(0, 'UNEXPECTED', 'Login failed.');
			if (error.code === 'PASSWORD_EXPIRED') {
				expired = true;
				mode = 'change';
				error = null;
			}
		} finally {
			busy = false;
			password = '';
		}
	}
</script>

<svelte:head><title>WEL Bank · Log in</title></svelte:head>

<div class="screen">
	<div class="hero">
		<Logo size={56} />
		<h1>Core banking for WEL Bank staff</h1>
		<p>Customers, accounts, the counter, lending and reporting on one ledger, protected by Oracle roles and a full audit trail.</p>
		<ul>
			<li>Every action is recorded with who did it and what changed.</li>
			<li>Maker-checker: you cannot approve your own work.</li>
			<li>Five wrong passwords lock the account for 15 minutes.</li>
		</ul>
	</div>
	<div class="panel">
		<div class="box">
			{#if mode === 'login'}
				<h2>Log in</h2>
				<p class="muted">Use your Oracle staff user name and password.</p>
				<form onsubmit={submit} novalidate>
					<FormField label="User name" required>
						<input type="text" bind:value={username} autocomplete="username" autocapitalize="characters" spellcheck="false" required />
					</FormField>
					<FormField label="Password" required>
						<input type="password" bind:value={password} autocomplete="current-password" required />
					</FormField>
					{#if error}
						<div class="notice {error.status === 423 ? 'warn' : 'error'}" role="alert">{error.message}</div>
					{/if}
					<button class="btn primary wide" type="submit" disabled={busy || !username || !password}>{#if busy}<Spinner />{/if} Log in</button>
				</form>
				<p class="alt"><button class="link" type="button" onclick={() => (mode = 'change')}>Change my password</button></p>
			{:else}
				<h2>{expired ? 'Your password has expired' : 'Change password'}</h2>
				<p class="muted">{expired ? 'Choose a new password to continue.' : 'Enter your current and new password.'}</p>
				<PasswordForm
					bind:username
					ondone={() => {
						toast.success('Password changed. Log in with the new password.');
						mode = 'login';
						expired = false;
					}}
				/>
				<p class="alt"><button class="link" type="button" onclick={() => (mode = 'login')}>Back to log in</button></p>
			{/if}
		</div>
	</div>
</div>

<style>
	.screen { min-height: 100vh; display: grid; grid-template-columns: 1.1fr 1fr; }
	.hero {
		background: radial-gradient(circle at 20% 10%, var(--navy-700), var(--navy-950) 70%);
		color: #d7e2f2;
		padding: 56px 8%;
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 18px;
		border-right: 4px solid var(--gold-500);
	}
	.hero h1 { color: #fff; font-size: 30px; max-width: 520px; }
	.hero p { max-width: 520px; font-size: 16px; }
	.hero ul { margin: 0; padding-left: 18px; display: grid; gap: 6px; color: #a9bddb; }
	.panel { display: grid; place-items: center; padding: 24px; }
	.box { width: min(400px, 100%); background: var(--surface); padding: 28px; border-radius: 12px; border: 1px solid var(--border); box-shadow: var(--shadow); display: grid; gap: 8px; }
	form { display: grid; gap: 14px; margin-top: 8px; }
	.wide { width: 100%; padding: 10px; }
	.alt { margin: 6px 0 0; text-align: center; }
	.link { background: none; border: 0; color: var(--navy-700); text-decoration: underline; cursor: pointer; font: inherit; }
	@media (max-width: 860px) { .screen { grid-template-columns: 1fr; } .hero { padding: 28px; } .hero ul { display: none; } }
</style>
