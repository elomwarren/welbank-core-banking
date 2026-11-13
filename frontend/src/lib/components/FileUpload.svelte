<script lang="ts">
	// Upload a customer's photo or signature (PNG/JPEG, up to 2 MB) with a preview of the current file.
	import Spinner from './Spinner.svelte';
	import { api, ApiError } from '$lib/api';
	import { toast } from '$lib/toast.svelte';

	let {
		customerNo,
		kind,
		present = false,
		onuploaded
	}: { customerNo: string; kind: 'PHOTO' | 'SIGNATURE'; present?: boolean; onuploaded: () => void } = $props();

	const MAX = 2 * 1024 * 1024;
	let file = $state<File | null>(null);
	let busy = $state(false);
	let error = $state('');
	let version = $state(0);
	let broken = $state(false);
	const inputId = $props.id();
	const name = $derived(kind === 'PHOTO' ? 'photo' : 'signature');

	function pick(e: Event) {
		const f = (e.currentTarget as HTMLInputElement).files?.[0] ?? null;
		error = '';
		file = null;
		if (!f) return;
		if (!['image/png', 'image/jpeg'].includes(f.type)) error = 'Choose a PNG or JPEG image.';
		else if (f.size > MAX) error = 'The file is larger than 2 MB.';
		else file = f;
	}

	async function upload() {
		if (!file) return;
		busy = true;
		error = '';
		const form = new FormData();
		form.set('kind', kind);
		form.set('file', file);
		try {
			await api.upload(`/customers/${customerNo}/files`, form);
			toast.success(`The ${name} of ${customerNo} was saved.`);
			file = null;
			version++;
			broken = false;
			onuploaded();
		} catch (e) {
			error = e instanceof ApiError ? e.message : 'The upload failed.';
		} finally {
			busy = false;
		}
	}
</script>

<div class="up">
	<div class="preview" class:sig={kind === 'SIGNATURE'}>
		{#if present && !broken}
			<img src="/api/customers/{customerNo}/files/{kind}?v={version}" alt="Current {name} of the customer" onerror={() => (broken = true)} />
		{:else}
			<span class="faint">No {name} yet</span>
		{/if}
	</div>
	<div class="ctl">
		<label for={inputId}><strong>{kind === 'PHOTO' ? 'Photo' : 'Signature'}</strong></label>
		<input id={inputId} type="file" accept="image/png,image/jpeg" onchange={pick} aria-invalid={!!error} />
		<span class="faint">PNG or JPEG, up to 2 MB</span>
		{#if error}<span class="err" role="alert">{error}</span>{/if}
		<button class="btn small" type="button" disabled={!file || busy} onclick={upload}>{#if busy}<Spinner />{/if} {present ? 'Replace' : 'Upload'} {name}</button>
	</div>
</div>

<style>
	.up { display: flex; gap: 16px; align-items: flex-start; }
	.preview { width: 110px; height: 130px; flex: none; border: 1px dashed var(--border-strong); border-radius: 6px; display: grid; place-items: center; text-align: center; font-size: 12px; background: var(--surface-2); overflow: hidden; }
	.preview.sig { width: 150px; height: 80px; }
	img { width: 100%; height: 100%; object-fit: contain; }
	.ctl { display: grid; gap: 6px; justify-items: start; min-width: 0; }
	.ctl input[type='file'] { max-width: 100%; }
	.err { color: var(--red); font-weight: 600; font-size: 12.5px; }
</style>
