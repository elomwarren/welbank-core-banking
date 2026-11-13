<script lang="ts">
	import { page } from '$app/state';
	import Card from '$lib/components/Card.svelte';
	import Async from '$lib/components/Async.svelte';
	import Empty from '$lib/components/Empty.svelte';
	import Money from '$lib/components/Money.svelte';
	import StatusBadge from '$lib/components/StatusBadge.svelte';
	import Tabs from '$lib/components/Tabs.svelte';
	import Title from '$lib/components/Title.svelte';
	import Dialog from '$lib/components/Dialog.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import FormField from '$lib/components/FormField.svelte';
	import FileUpload from '$lib/components/FileUpload.svelte';
	import VerificationPanel from '$lib/components/VerificationPanel.svelte';
	import Spinner from '$lib/components/Spinner.svelte';
	import { api, ApiError } from '$lib/api';
	import { Resource } from '$lib/resource.svelte';
	import { session } from '$lib/session.svelte';
	import { reference } from '$lib/reference.svelte';
	import { toast } from '$lib/toast.svelte';
	import { formatDate, formatDateTime, formatNumber, fullName, label } from '$lib/format';
	import type { CustomerDetail } from '$lib/types';

	const res = new Resource<CustomerDetail>();
	const no = $derived(page.params.no ?? '');
	let tab = $state('profile');
	let photoBroken = $state(false);

	const load = (keep = false) => res.run(() => api.get<CustomerDetail>(`/customers/${no}`), keep);
	$effect(() => {
		void no;
		tab = 'profile';
		photoBroken = false;
		void load();
	});
	$effect(() => void reference.load().catch(() => {}));

	const isService = $derived(session.has('WB_CUSTOMER_SERVICE'));

	// ---- open account ----
	let openAcc = $state(false);
	let product = $state('');
	let accName = $state('');
	let accBusy = $state(false);
	let accError = $state('');

	async function openAccount() {
		accBusy = true;
		accError = '';
		try {
			const r = await api.post<{ account_no: string }>('/accounts', { customer_no: no, product_code: product, account_name: accName.trim() || null });
			toast.success(`Account ${r.account_no} opened. It waits for a branch manager's approval.`, { href: `/accounts/${r.account_no}`, text: 'View account' });
			openAcc = false;
			await load(true);
		} catch (e) {
			accError = e instanceof ApiError ? e.message : 'The account could not be opened.';
		} finally {
			accBusy = false;
		}
	}

	// ---- submit KYC ----
	let confirmSubmit = $state(false);
	async function submitKyc() {
		try {
			await api.post(`/customers/${no}/submission`);
			toast.success(`KYC of ${no} sent to a branch manager for approval.`);
			confirmSubmit = false;
			await load(true);
		} catch (e) {
			confirmSubmit = false;
			toast.error(e instanceof ApiError ? e.message : 'Submission failed.');
		}
	}

	const hasFile = (d: CustomerDetail, kind: string) => !!d.identity?.files.some((f) => f.file_kind === kind);
	const yes = (v: number | boolean | null | undefined) => (v ? 'Yes' : 'No');
</script>

<Title text={res.data ? fullName(res.data.customer) : 'Customer'} subtitle={no} />

<Async {res} onretry={() => load()}>
	{#snippet children(d)}
		{@const c = d.customer}
		{@const tabs = [
			{ id: 'profile', label: 'Profile and KYC' },
			{ id: 'addresses', label: 'Addresses', count: d.addresses.length },
			{ id: 'contacts', label: 'Contacts and next of kin', count: d.contacts.length + d.next_of_kin.length },
			{ id: 'accounts', label: 'Accounts', count: d.accounts.length },
			{ id: 'loans', label: 'Loans', count: d.loans.length + d.loan_applications.length },
			{ id: 'cards', label: 'Cards', count: d.cards.length },
			...(d.identity ? [{ id: 'identity', label: 'Identity' }] : [])
		]}
		<div class="stack">
			<Card>
				<div class="head">
					{#if d.identity && hasFile(d, 'PHOTO') && !photoBroken}
						<img class="photo" src="/api/customers/{c.customer_no}/files/PHOTO" alt="Photo of {fullName(c)}" onerror={() => (photoBroken = true)} />
					{:else}
						<div class="photo ph" aria-hidden="true">{c.first_name[0]}{c.last_name[0]}</div>
					{/if}
					<div class="who">
						<h2>{c.title ? c.title + ' ' : ''}{fullName(c)}</h2>
						<div class="row">
							<span class="mono">{c.customer_no}</span>
							<StatusBadge status={c.status} />
							<span class="faint">KYC</span><StatusBadge status={c.kyc_status} />
							{#if c.risk_rating}<span class="faint">Risk</span><StatusBadge status={c.risk_rating} />{/if}
							{#if c.is_pep}<StatusBadge status="HIGH" text="PEP" />{/if}
						</div>
						<span class="muted">{c.branch_name} · born {formatDate(c.date_of_birth)} · {label(c.sex)} · {label(c.nationality)}</span>
					</div>
					{#if isService}
						<div class="actions">
							<button class="btn gold" type="button" onclick={() => ((product = reference.data?.account_products[0]?.product_code ?? ''), (accName = ''), (accError = ''), (openAcc = true))}>Open account</button>
							{#if d.kyc_pending_approval}
									<span class="muted">KYC submitted: waiting for a branch manager</span>
								{:else if c.kyc_status === 'PENDING_VERIFICATION' || c.kyc_status === 'DEFERRED' || c.kyc_status === 'REVIEW_DUE'}
								<button class="btn" type="button" onclick={() => (confirmSubmit = true)}>Submit KYC for approval</button>
							{/if}
						</div>
					{/if}
				</div>
				{#if d.kyc_missing}
					<div class="notice warn" style="margin-top: 14px"><strong>KYC still missing:</strong> {d.kyc_missing}</div>
				{/if}
			</Card>

			<Tabs {tabs} bind:active={tab} label="Customer sections" />

			<div role="tabpanel" id="panel-{tab}" aria-labelledby="tab-{tab}" class="panel">
				{#if tab === 'profile'}
					<div class="grid cols-2">
						<Card title="Personal details">
							<dl class="facts">
								<dt>Full name</dt><dd>{fullName(c)}</dd>
								{#if c.previous_names}<dt>Previous names</dt><dd>{c.previous_names}</dd>{/if}
								<dt>Date of birth</dt><dd>{formatDate(c.date_of_birth)}</dd>
								<dt>Place of birth</dt><dd>{c.place_of_birth ?? '—'}</dd>
								<dt>Nationality</dt><dd>{label(c.nationality)}</dd>
								<dt>Resident in</dt><dd>{label(c.country_of_residence)}</dd>
								<dt>Marital status</dt><dd>{label(c.marital_status)}</dd>
								<dt>Customer since</dt><dd>{formatDate(c.created_at)}</dd>
								<dt>Data consent</dt><dd>{c.data_consent_at ? formatDate(c.data_consent_at) : 'Not recorded'}</dd>
								<dt>Marketing consent</dt><dd>{yes(c.marketing_consent)}</dd>
							</dl>
						</Card>
						<Card title="Due diligence (KYC)">
							<dl class="facts">
								<dt>KYC status</dt><dd><StatusBadge status={c.kyc_status} /></dd>
								<dt>Risk rating</dt><dd>{#if c.risk_rating}<StatusBadge status={c.risk_rating} />{:else}Not rated yet{/if}</dd>
								<dt>Due diligence</dt><dd>{label(c.due_diligence_level)}</dd>
								<dt>Sanctions screening</dt><dd><StatusBadge status={c.sanctions_status} /> <span class="faint">(simulated)</span></dd>
								<dt>Politically exposed</dt><dd>{yes(c.is_pep)}{#if c.pep_details}&nbsp;· {c.pep_details}{/if}</dd>
								<dt>Approved</dt><dd>{c.kyc_approved_at ? `${formatDate(c.kyc_approved_at)} by ${c.kyc_approved_by ?? '—'}` : 'Not yet'}</dd>
								<dt>Next review</dt><dd>{formatDate(c.next_kyc_review_on)}</dd>
								{#if c.kyc_deferral_until}<dt>Deferred until</dt><dd>{formatDate(c.kyc_deferral_until)}</dd>{/if}
							</dl>
						</Card>
						<Card title="Employment and funds">
							<dl class="facts">
								<dt>Employment</dt><dd>{label(c.employment_status)}</dd>
								<dt>Occupation</dt><dd>{c.occupation ?? '—'}</dd>
								<dt>Employer</dt><dd>{c.employer_name ?? '—'}</dd>
								<dt>Income band</dt><dd>{label(c.income_band)}</dd>
								<dt>Source of funds</dt><dd>{label(c.source_of_funds)}</dd>
								<dt>Account purpose</dt><dd>{label(c.account_purpose)}</dd>
								<dt>Expected monthly volume</dt><dd><Money value={c.expected_monthly_volume} /></dd>
							</dl>
						</Card>
					</div>
				{:else if tab === 'addresses'}
					{#if d.addresses.length === 0}
						<Card><Empty title="No address on file" /></Card>
					{:else}
						<div class="grid cols-2">
							{#each d.addresses as a, i (i)}
								<Card title="{label(a.address_type)} address">
									{#snippet actions()}{#if a.is_current}<StatusBadge status="ACTIVE" text="Current" />{:else}<StatusBadge status="CLOSED" text="Previous" />{/if}{/snippet}
									<dl class="facts">
										<dt>Address</dt><dd>{a.address_line}</dd>
										<dt>Town</dt><dd>{a.town}</dd>
										<dt>Region</dt><dd>{a.region_name ?? '—'}</dd>
										<dt>Country</dt><dd>{label(a.country_code)}</dd>
										<dt>Digital address</dt><dd class="mono">{a.digital_address ?? '—'}</dd>
										<dt>Landmark</dt><dd>{a.landmark ?? '—'}</dd>
										<dt>Proof of address</dt><dd>{label(a.proof_type)}</dd>
										<dt>Resident since</dt><dd>{formatDate(a.resident_since)}</dd>
									</dl>
								</Card>
							{/each}
						</div>
					{/if}
				{:else if tab === 'contacts'}
					<div class="grid cols-2">
						<Card title="Contacts" flush>
							{#if d.contacts.length === 0}<Empty title="No contacts" />{:else}
								<div class="table-wrap"><table class="table">
									<thead><tr><th>Type</th><th>Value</th><th>Primary</th><th>Verified</th></tr></thead>
									<tbody>{#each d.contacts as k, i (i)}<tr><td><StatusBadge status={k.contact_type} /></td><td class="mono">{k.phone ?? k.email}</td><td>{yes(k.is_primary)}</td><td>{yes(k.is_verified)}</td></tr>{/each}</tbody>
								</table></div>
							{/if}
						</Card>
						<Card title="Next of kin" flush>
							{#if d.next_of_kin.length === 0}<Empty title="No next of kin recorded" />{:else}
								<div class="table-wrap"><table class="table">
									<thead><tr><th>Name</th><th>Relationship</th><th>Phone</th><th>Address</th></tr></thead>
									<tbody>{#each d.next_of_kin as k, i (i)}<tr><td>{k.full_name}</td><td>{label(k.relationship)}</td><td class="mono">{k.phone}</td><td>{k.address ?? '—'}</td></tr>{/each}</tbody>
								</table></div>
							{/if}
						</Card>
					</div>
				{:else if tab === 'accounts'}
					<Card title="Accounts" flush>
						{#snippet actions()}{#if isService}<button class="btn small gold" type="button" onclick={() => ((product = reference.data?.account_products[0]?.product_code ?? ''), (accName = ''), (accError = ''), (openAcc = true))}>Open account</button>{/if}{/snippet}
						{#if d.accounts.length === 0}
							<Empty title="No accounts yet">{isService ? 'Use "Open account" once the customer is registered.' : 'Customer service can open an account.'}</Empty>
						{:else}
							<div class="table-wrap"><table class="table">
								<thead><tr><th>Account no.</th><th>Name</th><th>Product</th><th>Role</th><th>Status</th><th class="num">Ledger balance</th><th class="num">Available</th></tr></thead>
								<tbody>
									{#each d.accounts as a (a.account_no)}
										<tr>
											<td><a class="mono" href="/accounts/{a.account_no}">{a.account_no}</a></td>
											<td>{a.account_name}</td>
											<td>{a.product_name ?? a.product_code}</td>
											<td>{label(a.holder_role)}</td>
											<td><StatusBadge status={a.status} />{#if a.post_no_debit}&nbsp;<StatusBadge status="BLOCKED" text="No debit" />{/if}</td>
											<td class="num"><Money value={a.ledger_balance} currency={a.currency_code} /></td>
											<td class="num"><Money value={a.available_balance} currency={a.currency_code} /></td>
										</tr>
									{/each}
								</tbody>
							</table></div>
						{/if}
					</Card>
				{:else if tab === 'loans'}
					<div class="stack">
						<Card title="Loans" flush>
							{#if d.loans.length === 0}<Empty title="No loans" />{:else}
								<div class="table-wrap"><table class="table">
									<thead><tr><th>Loan no.</th><th class="num">Principal</th><th class="num">Rate</th><th>Term</th><th>Matures</th><th class="num">Days past due</th><th>Class</th><th>Status</th><th class="num">Outstanding</th></tr></thead>
									<tbody>
										{#each d.loans as l (l.loan_no)}
											<tr>
												<td><a class="mono" href="/loans/{l.loan_no}">{l.loan_no}</a></td>
												<td class="num"><Money value={l.principal} /></td>
												<td class="num">{formatNumber(l.interest_rate, 2)}%</td>
												<td>{l.term_months} months</td>
												<td>{formatDate(l.maturity_date)}</td>
												<td class="num">{l.days_past_due}</td>
												<td><StatusBadge status={l.classification} /></td>
												<td><StatusBadge status={l.status} /></td>
												<td class="num"><Money value={l.outstanding} /></td>
											</tr>
										{/each}
									</tbody>
								</table></div>
							{/if}
						</Card>
						{#if d.loan_applications.length}
							<Card title="Loan applications" flush>
								<div class="table-wrap"><table class="table">
									<thead><tr><th>Application</th><th>Purpose</th><th class="num">Requested</th><th>Term</th><th>Submitted</th><th>Status</th><th class="num">Approved</th></tr></thead>
									<tbody>
										{#each d.loan_applications as a (a.application_no)}
											<tr>
												<td class="mono">{a.application_no}</td><td>{label(a.purpose)}</td>
												<td class="num"><Money value={a.requested_amount} /></td><td>{a.requested_term_months} months</td>
												<td>{formatDate(a.submitted_at)}</td><td><StatusBadge status={a.status} /></td>
												<td class="num"><Money value={a.approved_amount} /></td>
											</tr>
										{/each}
									</tbody>
								</table></div>
							</Card>
						{/if}
					</div>
				{:else if tab === 'cards'}
					<Card title="Cards" flush>
						{#if d.cards.length === 0}<Empty title="No cards issued" />{:else}
							<div class="table-wrap"><table class="table">
								<thead><tr><th>Card number</th><th>Scheme</th><th>Type</th><th>Status</th><th>Expires</th></tr></thead>
								<tbody>{#each d.cards as k, i (i)}<tr><td class="mono">{k.masked_pan}</td><td>{label(k.card_scheme)}</td><td>{label(k.card_type)}</td><td><StatusBadge status={k.status} />{#if k.block_reason}&nbsp;<span class="faint">{k.block_reason}</span>{/if}</td><td>{formatDate(k.expires_on)}</td></tr>{/each}</tbody>
							</table></div>
						{/if}
					</Card>
				{:else if tab === 'identity' && d.identity}
					<div class="stack">
						<Card title="Identity documents" flush>
							{#if d.identity.documents.length === 0}<Empty title="No identity document" />{:else}
								<div class="table-wrap"><table class="table">
									<thead><tr><th>Document</th><th>Number</th><th>Issued by</th><th>Expires</th><th>Primary</th></tr></thead>
									<tbody>{#each d.identity.documents as x, i (i)}<tr><td>{label(x.doc_type)}</td><td class="mono">{x.doc_number}</td><td>{label(x.issuing_country)}</td><td>{formatDate(x.expiry_date)}</td><td>{yes(x.is_primary)}</td></tr>{/each}</tbody>
								</table></div>
							{/if}
						</Card>
						<Card title="Photo and signature" subtitle="ID cards themselves are never stored; PNG or JPEG up to 2 MB">
							{#if isService}
								<div class="grid cols-2">
									<FileUpload customerNo={c.customer_no} kind="PHOTO" present={hasFile(d, 'PHOTO')} onuploaded={() => load(true)} />
									<FileUpload customerNo={c.customer_no} kind="SIGNATURE" present={hasFile(d, 'SIGNATURE')} onuploaded={() => load(true)} />
								</div>
							{:else}
								<div class="row" style="gap: 24px; align-items: flex-start">
									{#each ['PHOTO', 'SIGNATURE'] as kind (kind)}
										<figure>
											{#if hasFile(d, kind)}<img class="file" src="/api/customers/{c.customer_no}/files/{kind}" alt="{label(kind)} of {fullName(c)}" />{:else}<div class="file none faint">No {label(kind).toLowerCase()}</div>{/if}
											<figcaption class="faint">{label(kind)}</figcaption>
										</figure>
									{/each}
								</div>
							{/if}
						</Card>
						<Card title="NIA verifications" flush>
							{#if d.identity.verifications.length === 0}<Empty title="Not verified yet" />{:else}
								<div class="table-wrap"><table class="table">
									<thead><tr><th>When</th><th>Purpose</th><th>Method</th><th>Result</th><th>NIA reference</th></tr></thead>
									<tbody>{#each d.identity.verifications as v, i (i)}<tr><td>{formatDateTime(v.performed_at)}</td><td>{label(v.purpose)}</td><td>{label(v.method)}</td><td><StatusBadge status={v.result} />{#if v.is_simulated}&nbsp;<span class="faint">simulated</span>{/if}</td><td class="mono">{v.nia_reference ?? v.error_code ?? '—'}</td></tr>{/each}</tbody>
								</table></div>
							{/if}
						</Card>
						{#if isService}
							<Card title="Verify and screen">
								<VerificationPanel customerNo={c.customer_no} verifications={d.identity.verifications} sanctionsStatus={c.sanctions_status} onrecorded={() => load(true)} />
							</Card>
						{/if}
					</div>
				{/if}
			</div>
		</div>
	{/snippet}
</Async>

<Dialog bind:open={openAcc} title="Open an account">
	<p class="muted">The account accepts deposits at once; debits need a branch manager's approval and verified KYC.</p>
	<FormField label="Product" required>
		<select bind:value={product}>
			{#each reference.data?.account_products ?? [] as p (p.product_code)}
				<option value={p.product_code}>{p.product_name} ({p.currency_code}, opening balance {formatNumber(p.min_opening_balance, 2)})</option>
			{/each}
		</select>
	</FormField>
	<FormField label="Account name" hint="Leave empty to use the customer's name.">
		<input type="text" bind:value={accName} maxlength="120" />
	</FormField>
	{#if accError}<div class="notice error" role="alert">{accError}</div>{/if}
	{#snippet actions()}
		<button class="btn" type="button" onclick={() => (openAcc = false)}>Cancel</button>
		<button class="btn primary" type="button" disabled={accBusy || !product} onclick={openAccount}>{#if accBusy}<Spinner />{/if} Open account</button>
	{/snippet}
</Dialog>

<ConfirmDialog bind:open={confirmSubmit} title="Submit KYC for approval" confirmLabel="Submit for approval" onconfirm={submitKyc}>
	<p>Send the KYC file of <strong>{no}</strong> to a branch manager. After that you cannot change it until it is decided.</p>
	<p class="muted">The package checks that photo, signature, NIA verification and screening are complete.</p>
</ConfirmDialog>

<style>
	.head { display: flex; gap: 18px; align-items: center; flex-wrap: wrap; }
	.photo { width: 84px; height: 100px; border-radius: 8px; object-fit: cover; border: 1px solid var(--border); flex: none; }
	.ph { display: grid; place-items: center; background: var(--navy-100); color: var(--navy-800); font-size: 28px; font-weight: 800; }
	.who { display: grid; gap: 6px; flex: 1; min-width: 240px; }
	.actions { display: flex; gap: 8px; flex-wrap: wrap; }
	.panel { display: grid; gap: 16px; }
	figure { margin: 0; text-align: center; }
	.file { width: 130px; height: 150px; object-fit: contain; border: 1px solid var(--border); border-radius: 6px; background: var(--surface-2); display: grid; place-items: center; }
</style>
