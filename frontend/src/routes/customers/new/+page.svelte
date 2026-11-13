<script lang="ts">
	import Card from '$lib/components/Card.svelte';
	import FormField from '$lib/components/FormField.svelte';
	import FileUpload from '$lib/components/FileUpload.svelte';
	import VerificationPanel from '$lib/components/VerificationPanel.svelte';
	import RoleGate from '$lib/components/RoleGate.svelte';
	import Spinner from '$lib/components/Spinner.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Title from '$lib/components/Title.svelte';
	import ErrorNotice from '$lib/components/ErrorNotice.svelte';
	import { api, ApiError } from '$lib/api';
	import { reference } from '$lib/reference.svelte';
	import { toast } from '$lib/toast.svelte';
	import { isoDay, label } from '$lib/format';
	import type { CustomerDetail } from '$lib/types';

	const STEPS = ['Personal and identity', 'Address and contacts', 'Photo and signature', 'Verification', 'Submit'];

	let step = $state(1);
	let customerNo = $state('');
	let detail = $state<CustomerDetail | null>(null);
	let busy = $state(false);
	let formError = $state('');
	let errors = $state<Record<string, string>>({});
	let refError = $state<ApiError | null>(null);

	$effect(() => {
		reference.load().catch((e) => (refError = e instanceof ApiError ? e : null));
	});

	const f = $state({
		title: '',
		first_name: '',
		middle_name: '',
		last_name: '',
		sex: '',
		date_of_birth: '',
		place_of_birth: '',
		nationality: 'GHA',
		country_of_residence: 'GHA',
		doc_type: 'GHANA_CARD',
		doc_number: '',
		doc_country: 'GHA',
		doc_expiry: '',
		employment_status: '',
		occupation: '',
		employer_name: '',
		income_band: '',
		source_of_funds: '',
		account_purpose: '',
		expected_monthly_volume: '',
		is_pep: false,
		pep_details: '',
		data_consent: false,
		marketing_consent: false,
		mobile: '',
		email: '',
		address_type: 'RESIDENTIAL',
		address_line: '',
		town: '',
		region_id: '',
		country: 'GHA',
		digital_address: '',
		landmark: '',
		proof_type: '',
		proof_date: '',
		kin_name: '',
		kin_relationship: '',
		kin_phone: '',
		kin_address: ''
	});

	const enums = (name: string) => reference.enumValues(name);
	const nullIfEmpty = (v: string) => (v.trim() === '' ? null : v.trim());
	const today = isoDay();

	function validateStep1(): boolean {
		const e: Record<string, string> = {};
		const need = (key: keyof typeof f, text: string) => {
			if (!String(f[key]).trim()) e[key] = text;
		};
		need('first_name', 'Enter the first name.');
		need('last_name', 'Enter the last name.');
		need('sex', 'Choose the sex.');
		need('date_of_birth', 'Enter the date of birth.');
		if (f.date_of_birth && f.date_of_birth > today) e.date_of_birth = 'The date of birth cannot be in the future.';
		need('doc_number', 'Enter the identity document number.');
		if (f.doc_number && f.doc_number.trim().length < 5) e.doc_number = 'The number needs at least 5 characters.';
		need('employment_status', 'Choose the employment status.');
		need('income_band', 'Choose the income band.');
		need('source_of_funds', 'Choose the source of funds.');
		need('account_purpose', 'Choose the purpose of the account.');
		if (f.expected_monthly_volume === '' || Number(f.expected_monthly_volume) < 0) e.expected_monthly_volume = 'Enter the expected monthly volume (0 or more).';
		if (f.is_pep && !f.pep_details.trim()) e.pep_details = 'Describe the public position.';
		if (!f.data_consent) e.data_consent = 'The customer must consent to the processing of their data.';
		errors = e;
		return Object.keys(e).length === 0;
	}

	function validateStep2(): boolean {
		const e: Record<string, string> = {};
		if (f.address_line.trim().length < 3) e['address.address_line'] = 'Enter the street or house address.';
		if (f.town.trim().length < 2) e['address.town'] = 'Enter the town.';
		if (f.country === 'GHA' && !f.region_id) e['address.region_id'] = 'Choose the region (required for an address in Ghana).';
		if (f.address_type === 'RESIDENTIAL' && f.country === 'GHA' && !f.digital_address.trim()) e['address.digital_address'] = 'A residential address in Ghana needs its GhanaPostGPS digital address.';
		if (f.mobile.trim().length < 7) e.mobile = 'Enter a mobile number, e.g. +233501234567.';
		if (f.email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email)) e.email = 'This is not a valid e-mail address.';
		if (f.kin_name.trim().length < 3) e['next_of_kin.full_name'] = 'Enter the next of kin\'s full name.';
		if (!f.kin_relationship) e['next_of_kin.relationship'] = 'Choose the relationship.';
		if (f.kin_phone.trim().length < 7) e['next_of_kin.phone'] = 'Enter the next of kin\'s phone number.';
		errors = e;
		return Object.keys(e).length === 0;
	}

	function next1() {
		formError = '';
		if (validateStep1()) step = 2;
		else focusFirstError();
	}

	function focusFirstError() {
		queueMicrotask(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());
	}

	async function register() {
		formError = '';
		if (!validateStep1()) {
			step = 1;
			focusFirstError();
			return;
		}
		if (!validateStep2()) {
			focusFirstError();
			return;
		}
		busy = true;
		try {
			const body = {
				title: nullIfEmpty(f.title),
				first_name: f.first_name.trim(),
				middle_name: nullIfEmpty(f.middle_name),
				last_name: f.last_name.trim(),
				sex: f.sex,
				date_of_birth: f.date_of_birth,
				place_of_birth: nullIfEmpty(f.place_of_birth),
				nationality: f.nationality,
				country_of_residence: f.country_of_residence,
				doc_type: f.doc_type,
				doc_number: f.doc_number.trim(),
				doc_country: f.doc_country,
				doc_expiry: nullIfEmpty(f.doc_expiry),
				employment_status: f.employment_status,
				occupation: nullIfEmpty(f.occupation),
				employer_name: nullIfEmpty(f.employer_name),
				income_band: f.income_band,
				source_of_funds: f.source_of_funds,
				account_purpose: f.account_purpose,
				expected_monthly_volume: Number(f.expected_monthly_volume),
				is_pep: f.is_pep,
				pep_details: f.is_pep ? nullIfEmpty(f.pep_details) : null,
				data_consent: f.data_consent,
				marketing_consent: f.marketing_consent,
				mobile: f.mobile.trim(),
				email: nullIfEmpty(f.email),
				address: {
					address_type: f.address_type,
					address_line: f.address_line.trim(),
					town: f.town.trim(),
					region_id: f.region_id ? Number(f.region_id) : null,
					country: f.country,
					digital_address: nullIfEmpty(f.digital_address),
					landmark: nullIfEmpty(f.landmark),
					proof_type: nullIfEmpty(f.proof_type),
					proof_date: nullIfEmpty(f.proof_date)
				},
				next_of_kin: {
					full_name: f.kin_name.trim(),
					relationship: f.kin_relationship,
					phone: f.kin_phone.trim(),
					address: nullIfEmpty(f.kin_address)
				}
			};
			const r = await api.post<{ customer_no: string }>('/customers', body);
			customerNo = r.customer_no;
			toast.success(`Customer ${r.customer_no} registered. Now add the photo and signature.`, { href: `/customers/${r.customer_no}`, text: 'Open customer' });
			await refreshDetail();
			step = 3;
		} catch (e) {
			if (e instanceof ApiError) {
				formError = e.message;
				if (e.status === 422) {
					errors = e.fieldErrors;
					// Show the step with the first problem.
					step = Object.keys(errors).some((k) => k.startsWith('address.') || k.startsWith('next_of_kin.') || k === 'mobile' || k === 'email') && !Object.keys(errors).some((k) => k in f) ? 2 : step;
				}
			} else formError = 'The customer could not be registered.';
		} finally {
			busy = false;
		}
	}

	async function refreshDetail() {
		if (!customerNo) return;
		try {
			detail = await api.get<CustomerDetail>(`/customers/${customerNo}`);
		} catch (e) {
			if (e instanceof ApiError) toast.error(e.message);
		}
	}

	const hasFile = (kind: string) => !!detail?.identity?.files.some((x) => x.file_kind === kind);
	const verified = $derived(!!detail?.identity?.verifications.some((v) => v.result === 'MATCH'));
	const screened = $derived(detail?.customer.sanctions_status === 'CLEAR');

	let submitted = $state(false);
	async function submit() {
		busy = true;
		formError = '';
		try {
			await api.post(`/customers/${customerNo}/submission`);
			submitted = true;
			toast.success(`KYC of ${customerNo} submitted. A branch manager will approve it.`, { href: `/customers/${customerNo}`, text: 'Open customer' });
			await refreshDetail();
		} catch (e) {
			formError = e instanceof ApiError ? e.message : 'The submission failed.';
		} finally {
			busy = false;
		}
	}

	function reset() {
		location.href = '/customers/new';
	}

	const e = (key: string) => errors[key] ?? '';
	const regionOptions = $derived(reference.data?.regions ?? []);
</script>

<Title text="New customer" subtitle="Onboarding with due diligence" />

<RoleGate roles={['WB_CUSTOMER_SERVICE']}>
	{#if refError}
		<ErrorNotice error={refError} />
	{:else if !reference.data}
		<div class="skeleton" style="height: 260px"></div>
	{:else}
		<div class="stack wizard">
			<ol class="steps" aria-label="Onboarding steps">
				{#each STEPS as s, i (s)}
					<li class:done={step > i + 1} class:on={step === i + 1} aria-current={step === i + 1 ? 'step' : undefined}>
						<span class="n">{step > i + 1 ? '✓' : i + 1}</span><span class="t">{s}</span>
					</li>
				{/each}
			</ol>

			{#if formError}<div class="notice error" role="alert">{formError}</div>{/if}

			{#if step === 1}
				<form class="stack" onsubmit={(ev) => (ev.preventDefault(), next1())} novalidate>
					<Card title="1. Personal details" subtitle="As on the identity document">
						<div class="grid cols-3">
							<FormField label="Title"><select bind:value={f.title}><option value="">None</option>{#each enums('title') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="First name" required error={e('first_name')}><input type="text" bind:value={f.first_name} maxlength="60" aria-invalid={!!e('first_name')} /></FormField>
							<FormField label="Middle name"><input type="text" bind:value={f.middle_name} maxlength="60" /></FormField>
							<FormField label="Last name" required error={e('last_name')}><input type="text" bind:value={f.last_name} maxlength="60" aria-invalid={!!e('last_name')} /></FormField>
							<FormField label="Sex" required error={e('sex')}><select bind:value={f.sex} aria-invalid={!!e('sex')}><option value="">Choose…</option>{#each enums('sex') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Date of birth" required error={e('date_of_birth')}><input type="date" bind:value={f.date_of_birth} max={today} aria-invalid={!!e('date_of_birth')} /></FormField>
							<FormField label="Place of birth"><input type="text" bind:value={f.place_of_birth} maxlength="80" /></FormField>
							<FormField label="Nationality" required><select bind:value={f.nationality}>{#each reference.data.countries as c (c.country_code)}<option value={c.country_code}>{c.country_name}</option>{/each}</select></FormField>
							<FormField label="Country of residence" required><select bind:value={f.country_of_residence}>{#each reference.data.countries as c (c.country_code)}<option value={c.country_code}>{c.country_name}</option>{/each}</select></FormField>
						</div>
					</Card>

					<Card title="Identity document" subtitle="The card itself is never stored; only its number and the NIA check">
						<div class="grid cols-4">
							<FormField label="Document type" required><select bind:value={f.doc_type}>{#each enums('doc_type') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Document number" required error={e('doc_number')}><input type="text" bind:value={f.doc_number} maxlength="30" placeholder="GHA-000000000-0" aria-invalid={!!e('doc_number')} /></FormField>
							<FormField label="Issuing country" required><select bind:value={f.doc_country}>{#each reference.data.countries as c (c.country_code)}<option value={c.country_code}>{c.country_name}</option>{/each}</select></FormField>
							<FormField label="Expiry date"><input type="date" bind:value={f.doc_expiry} min={today} /></FormField>
						</div>
					</Card>

					<Card title="Employment and source of funds">
						<div class="grid cols-3">
							<FormField label="Employment status" required error={e('employment_status')}><select bind:value={f.employment_status} aria-invalid={!!e('employment_status')}><option value="">Choose…</option>{#each enums('employment_status') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Occupation"><input type="text" bind:value={f.occupation} maxlength="80" /></FormField>
							<FormField label="Employer"><input type="text" bind:value={f.employer_name} maxlength="120" /></FormField>
							<FormField label="Monthly income band" required error={e('income_band')}><select bind:value={f.income_band} aria-invalid={!!e('income_band')}><option value="">Choose…</option>{#each enums('income_band') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Source of funds" required error={e('source_of_funds')}><select bind:value={f.source_of_funds} aria-invalid={!!e('source_of_funds')}><option value="">Choose…</option>{#each enums('source_of_funds') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Purpose of the account" required error={e('account_purpose')}><select bind:value={f.account_purpose} aria-invalid={!!e('account_purpose')}><option value="">Choose…</option>{#each enums('account_purpose') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Expected monthly volume (GH₵)" required error={e('expected_monthly_volume')}><input type="number" min="0" step="0.01" bind:value={f.expected_monthly_volume} aria-invalid={!!e('expected_monthly_volume')} /></FormField>
						</div>
					</Card>

					<Card title="Consent and politically exposed person">
						<div class="checks">
							<label class="check"><input type="checkbox" bind:checked={f.is_pep} /> The customer holds, or recently held, a prominent public position (PEP)</label>
							{#if f.is_pep}
								<FormField label="Position and details" required error={e('pep_details')}><input type="text" bind:value={f.pep_details} maxlength="400" aria-invalid={!!e('pep_details')} /></FormField>
							{/if}
							<label class="check"><input type="checkbox" bind:checked={f.data_consent} aria-invalid={!!e('data_consent')} /> The customer consents to the processing of their personal data (Data Protection Act, 2012) <span class="req">*</span></label>
							{#if e('data_consent')}<p class="errtext" role="alert">{e('data_consent')}</p>{/if}
							<label class="check"><input type="checkbox" bind:checked={f.marketing_consent} /> The customer agrees to receive marketing messages</label>
						</div>
					</Card>
					<div class="row end"><button class="btn primary" type="submit">Next: address and contacts →</button></div>
				</form>
			{:else if step === 2}
				<form class="stack" onsubmit={(ev) => (ev.preventDefault(), register())} novalidate>
					<Card title="2. Address">
						<div class="grid cols-3">
							<FormField label="Address type"><select bind:value={f.address_type}>{#each enums('address_type') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Street or house address" required error={e('address.address_line')}><input type="text" bind:value={f.address_line} maxlength="200" aria-invalid={!!e('address.address_line')} /></FormField>
							<FormField label="Town" required error={e('address.town')}><input type="text" bind:value={f.town} maxlength="80" aria-invalid={!!e('address.town')} /></FormField>
							<FormField label="Country" required><select bind:value={f.country}>{#each reference.data.countries as c (c.country_code)}<option value={c.country_code}>{c.country_name}</option>{/each}</select></FormField>
							<FormField label={f.country === 'GHA' ? 'Region' : 'Region (Ghana only)'} required={f.country === 'GHA'} error={e('address.region_id')}>
								<select bind:value={f.region_id} disabled={f.country !== 'GHA'} aria-invalid={!!e('address.region_id')}>
									<option value="">Choose…</option>{#each regionOptions as r (r.region_id)}<option value={String(r.region_id)}>{r.region_name}</option>{/each}
								</select>
							</FormField>
							<FormField label="Digital address (GhanaPostGPS)" required={f.address_type === 'RESIDENTIAL' && f.country === 'GHA'} error={e('address.digital_address')}><input type="text" bind:value={f.digital_address} maxlength="20" placeholder="GA-123-4567" aria-invalid={!!e('address.digital_address')} /></FormField>
							<FormField label="Landmark"><input type="text" bind:value={f.landmark} maxlength="120" /></FormField>
							<FormField label="Proof of address"><select bind:value={f.proof_type}><option value="">None yet</option>{#each enums('proof_type') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Date of the proof"><input type="date" bind:value={f.proof_date} max={today} /></FormField>
						</div>
					</Card>
					<Card title="Contacts">
						<div class="grid cols-2">
							<FormField label="Mobile number" required error={e('mobile')}><input type="tel" bind:value={f.mobile} maxlength="20" placeholder="+233501234567" aria-invalid={!!e('mobile')} /></FormField>
							<FormField label="E-mail" error={e('email')}><input type="email" bind:value={f.email} maxlength="120" aria-invalid={!!e('email')} /></FormField>
						</div>
					</Card>
					<Card title="Next of kin">
						<div class="grid cols-2">
							<FormField label="Full name" required error={e('next_of_kin.full_name')}><input type="text" bind:value={f.kin_name} maxlength="120" aria-invalid={!!e('next_of_kin.full_name')} /></FormField>
							<FormField label="Relationship" required error={e('next_of_kin.relationship')}><select bind:value={f.kin_relationship} aria-invalid={!!e('next_of_kin.relationship')}><option value="">Choose…</option>{#each enums('relationship') as t (t)}<option value={t}>{label(t)}</option>{/each}</select></FormField>
							<FormField label="Phone" required error={e('next_of_kin.phone')}><input type="tel" bind:value={f.kin_phone} maxlength="20" aria-invalid={!!e('next_of_kin.phone')} /></FormField>
							<FormField label="Address"><input type="text" bind:value={f.kin_address} maxlength="200" /></FormField>
						</div>
					</Card>
					<div class="row between">
						<button class="btn" type="button" onclick={() => (step = 1)} disabled={busy}>← Back</button>
						<button class="btn primary" type="submit" disabled={busy}>{#if busy}<Spinner />{/if} Register customer</button>
					</div>
				</form>
			{:else if step === 3}
				<Card title="3. Photo and signature" subtitle="Customer {customerNo} is registered. The photo and the signature are needed before the KYC can be submitted.">
					<div class="grid cols-2">
						<FileUpload {customerNo} kind="PHOTO" present={hasFile('PHOTO')} onuploaded={refreshDetail} />
						<FileUpload {customerNo} kind="SIGNATURE" present={hasFile('SIGNATURE')} onuploaded={refreshDetail} />
					</div>
				</Card>
				<div class="row between">
					<span class="muted">{hasFile('PHOTO') && hasFile('SIGNATURE') ? 'Both files are saved.' : 'You can also add them later from the customer page.'}</span>
					<button class="btn primary" type="button" onclick={() => (step = 4)}>Next: verification →</button>
				</div>
			{:else if step === 4}
				<Card title="4. Identity verification and sanctions screening">
					{#if detail?.identity}
						<VerificationPanel customerNo={customerNo} verifications={detail.identity.verifications} sanctionsStatus={detail.customer.sanctions_status} onrecorded={refreshDetail} />
					{:else}
						<div class="skeleton" style="height: 120px"></div>
					{/if}
				</Card>
				<div class="row between">
					<button class="btn" type="button" onclick={() => (step = 3)}>← Back</button>
					<button class="btn primary" type="button" onclick={() => (step = 5)}>Next: submit →</button>
				</div>
			{:else}
				<Card title="5. Submit for approval" subtitle="Maker-checker: a branch manager approves the KYC; you cannot approve your own work.">
					<ul class="check-list">
						<li class:ok={hasFile('PHOTO')}><StatusBadge status={hasFile('PHOTO') ? 'VERIFIED' : 'PENDING'} text={hasFile('PHOTO') ? 'Done' : 'Missing'} /> Photo</li>
						<li class:ok={hasFile('SIGNATURE')}><StatusBadge status={hasFile('SIGNATURE') ? 'VERIFIED' : 'PENDING'} text={hasFile('SIGNATURE') ? 'Done' : 'Missing'} /> Signature</li>
						<li><StatusBadge status={verified ? 'VERIFIED' : 'PENDING'} text={verified ? 'Matched' : 'Missing'} /> NIA verification (simulated)</li>
						<li><StatusBadge status={screened ? 'VERIFIED' : 'PENDING'} text={screened ? 'Clear' : (detail?.customer.sanctions_status ?? 'Missing')} /> Sanctions screening (simulated)</li>
					</ul>
					{#if detail?.kyc_missing}<div class="notice warn"><strong>Still missing:</strong> {detail.kyc_missing}</div>{/if}
					{#if submitted}
						<div class="notice success" style="margin-top: 12px">Submitted. {customerNo} now waits in the approval queue of a branch manager.</div>
						<div class="row" style="margin-top: 12px">
							<a class="btn primary" href="/customers/{customerNo}">Open customer {customerNo}</a>
							<button class="btn" type="button" onclick={reset}>Register another customer</button>
						</div>
					{:else}
						<div class="row between" style="margin-top: 14px">
							<button class="btn" type="button" onclick={() => (step = 4)} disabled={busy}>← Back</button>
							<button class="btn gold" type="button" onclick={submit} disabled={busy}>{#if busy}<Spinner />{/if} Submit KYC for approval</button>
						</div>
					{/if}
				</Card>
			{/if}
		</div>
	{/if}
</RoleGate>

<style>
	.wizard { max-width: 1080px; }
	.steps { list-style: none; display: flex; gap: 0; padding: 0; margin: 0; counter-reset: s; }
	.steps li { flex: 1; display: flex; align-items: center; gap: 8px; padding: 10px 12px; background: var(--surface); border: 1px solid var(--border); color: var(--text-muted); font-weight: 600; font-size: 13px; }
	.steps li:first-child { border-radius: 8px 0 0 8px; }
	.steps li:last-child { border-radius: 0 8px 8px 0; }
	.steps li.on { background: var(--navy-900); color: #fff; border-color: var(--navy-900); }
	.steps li.done { background: var(--green-bg); color: var(--green); }
	.n { width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; background: var(--grey-bg); color: var(--grey); flex: none; font-size: 12px; }
	.on .n { background: var(--gold-500); color: #2b1d00; }
	.done .n { background: var(--green); color: #fff; }
	@media (max-width: 900px) { .t { display: none; } .steps li { justify-content: center; } }
	.checks { display: grid; gap: 10px; }
	.check { display: flex; gap: 10px; align-items: flex-start; }
	.check input { margin-top: 3px; }
	.req { color: var(--red); }
	.errtext { color: var(--red); font-size: 12px; font-weight: 600; margin: 0; }
	.check-list { list-style: none; padding: 0; margin: 0 0 12px; display: grid; gap: 8px; }
</style>
