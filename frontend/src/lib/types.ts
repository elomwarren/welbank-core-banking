// Shapes of the API's answers (see backend/app/routers). Numbers are JSON numbers, dates ISO strings.

export type Role =
	| 'WB_STAFF'
	| 'WB_TELLER'
	| 'WB_SUPERVISOR'
	| 'WB_CUSTOMER_SERVICE'
	| 'WB_KYC_APPROVER'
	| 'WB_LOAN_OFFICER'
	| 'WB_CREDIT'
	| 'WB_REPORTS'
	| 'WB_AUDITOR'
	| 'WB_HR'
	| 'WB_BACKUP_ADMIN';

export interface Employee {
	username: string;
	employee_id: number;
	full_name: string;
	job_title: string;
	department_name: string;
	branch_id: number | null;
	branch_code: string | null;
	branch_name: string | null;
	roles: Role[];
}

export interface LoginResult {
	employee: Employee;
	password_warning: string | null;
}

export interface Reference {
	account_products: {
		product_code: string;
		product_name: string;
		account_type: string;
		currency_code: string;
		interest_rate: number;
		min_opening_balance: number;
		monthly_fee: number;
		overdraft_allowed: number | boolean;
		term_months: number | null;
	}[];
	loan_products: {
		product_code: string;
		product_name: string;
		currency_code: string;
		interest_rate: number;
		min_amount: number;
		max_amount: number;
		max_term_months: number;
	}[];
	branches: { branch_id: number; branch_code: string; branch_name: string; region_name: string; status: string }[];
	regions: { region_id: number; region_name: string }[];
	countries: { country_code: string; country_name: string }[];
	currencies: { currency_code: string; currency_name: string; symbol: string }[];
	enums: Record<string, string[]>;
}

export interface Txn {
	txn_ref: string;
	txn_type: string;
	channel?: string;
	amount: number;
	currency_code: string;
	status: string;
	value_date: string;
	posted_at: string | null;
	narration: string | null;
	initiated_by?: string | null;
	checked_by?: string | null;
	rejection_reason?: string | null;
}

export interface Dashboard {
	employee: Employee;
	stats: {
		customers: number;
		active_accounts: number;
		pending_approvals: number;
		transactions_today: number;
		volume_today_ghs: number;
		deposits_ghs: number;
		loans_in_arrears: number;
	};
	recent_transactions: Txn[];
	monthly_activity: { month: string; txn_type: string; transactions: number; amount: number }[];
}

export interface CustomerRow {
	customer_no: string;
	title: string | null;
	first_name: string;
	middle_name: string | null;
	last_name: string;
	sex: string;
	date_of_birth: string;
	nationality: string;
	kyc_status: string;
	status: string;
	risk_rating: string | null;
	branch_code: string;
	branch_name: string;
	created_at: string;
	mobile: string | null;
}

export interface CustomerDetail {
	customer: CustomerRow & {
		previous_names: string | null;
		place_of_birth: string | null;
		country_of_residence: string;
		marital_status: string | null;
		employment_status: string;
		occupation: string | null;
		employer_name: string | null;
		income_band: string;
		source_of_funds: string;
		account_purpose: string;
		expected_monthly_volume: number;
		is_pep: number | boolean;
		pep_details: string | null;
		sanctions_status: string;
		due_diligence_level: string | null;
		kyc_deferral_until: string | null;
		kyc_approved_at: string | null;
		next_kyc_review_on: string | null;
		data_consent_at: string | null;
		marketing_consent: number | boolean;
		kyc_approved_by: string | null;
	};
	addresses: {
		address_type: string;
		address_line: string;
		town: string;
		region_name: string | null;
		country_code: string;
		digital_address: string | null;
		landmark: string | null;
		resident_since: string | null;
		proof_type: string | null;
		is_current: number | boolean;
	}[];
	contacts: { contact_type: string; phone: string | null; email: string | null; is_primary: number | boolean; is_verified: number | boolean }[];
	next_of_kin: { full_name: string; relationship: string; phone: string; address: string | null }[];
	accounts: {
		account_no: string;
		account_name: string;
		product_code: string | null;
		product_name: string | null;
		currency_code: string;
		status: string;
		post_no_debit: number | boolean;
		ledger_balance: number;
		available_balance: number;
		holder_role: string;
		opened_on: string;
	}[];
	loans: {
		loan_no: string;
		principal: number;
		interest_rate: number;
		term_months: number;
		disbursed_on: string;
		maturity_date: string;
		days_past_due: number;
		classification: string;
		status: string;
		outstanding: number;
	}[];
	loan_applications: {
		application_no: string;
		requested_amount: number;
		requested_term_months: number;
		purpose: string;
		status: string;
		submitted_at: string;
		approved_amount: number | null;
		decision_note: string | null;
	}[];
	cards: { masked_pan: string; card_scheme: string; card_type: string; status: string; block_reason: string | null; expires_on: string }[];
	identity: {
		documents: { doc_type: string; doc_number: string; issuing_country: string; expiry_date: string | null; is_primary: number | boolean }[];
		verifications: {
			purpose: string;
			method: string;
			result: string;
			nia_reference: string | null;
			error_code: string | null;
			is_simulated: number | boolean;
			performed_at: string;
		}[];
		files: { file_kind: string; mime_type: string; byte_size: number; captured_at: string }[];
	} | null;
	kyc_missing: string | null;
	kyc_pending_approval: boolean;
}

export interface Account {
	account_no: string;
	account_name: string;
	account_class: string;
	currency_code: string;
	mandate: string | null;
	status: string;
	post_no_debit: number | boolean;
	ledger_balance: number;
	available_balance: number;
	overdraft_limit: number | null;
	opened_on: string;
	closed_on: string | null;
	last_activity_at: string | null;
	product_code: string | null;
	product_name: string | null;
	account_type: string | null;
	interest_rate: number | null;
	branch_code: string;
	branch_name: string;
	opened_by: string | null;
	checked_by: string | null;
	checked_at: string | null;
}

export interface StatementLine {
	entry_id: number;
	txn_ref: string;
	txn_type: string;
	value_date: string;
	posted_at: string | null;
	narration: string | null;
	debit: number | null;
	credit: number | null;
	balance_after: number;
}

export interface AccountDetail {
	account: Account;
	holders: { customer_no: string; full_name: string; holder_role: string; kyc_status: string }[];
	statement: StatementLine[];
}

export interface TxnDetail {
	transaction: Txn & {
		branch_code: string | null;
		checked_at: string | null;
		reverses_txn_ref: string | null;
	};
	lines: { account_no: string; account_name: string; account_class: string; direction: 'DR' | 'CR'; amount: number }[];
}

export interface ApprovalItem {
	request_id: number;
	request_type: string;
	target_kind: string;
	target_ref: string;
	amount: number | null;
	currency_code: string | null;
	reason: string | null;
	requested_by: number;
	requested_by_name: string;
	requested_at: string;
	hours_waiting: number;
	branch_code: string | null;
	branch_name: string | null;
	can_decide: boolean;
}

export interface Loan {
	loan_no: string;
	application_no: string;
	customer_no: string;
	customer_name: string;
	product_code: string;
	product_name: string;
	principal: number;
	rate_type: string;
	reference_rate: number | null;
	margin_pct: number | null;
	interest_rate: number;
	term_months: number;
	disbursed_on: string;
	first_due_date: string;
	maturity_date: string;
	days_past_due: number;
	classification: string;
	status: string;
	closed_on: string | null;
	loan_account_no: string;
	outstanding: number;
	disbursement_account_no: string | null;
	branch_code: string;
}

export interface ScheduleLine {
	installment_no: number;
	due_date: string;
	principal_due: number;
	interest_due: number;
	total_due: number;
	principal_paid: number;
	interest_paid: number;
	status: string;
	paid_on: string | null;
}

export interface LoanDetail {
	loan: Loan;
	due_now: number;
	schedule: ScheduleLine[];
	repayments: { txn_ref: string; value_date: string; installment_no: number | null; principal_amount: number; interest_amount: number }[];
}

export interface LoanApplication {
	application_no: string;
	customer_no: string;
	customer_name: string;
	product_code: string;
	requested_amount: number;
	requested_term_months: number;
	purpose: string;
	monthly_income: number;
	monthly_obligations: number;
	status: string;
	submitted_at: string;
	approved_amount: number | null;
	approved_term_months: number | null;
	approved_margin_pct: number | null;
	decision_note: string | null;
	loan_officer: string | null;
	branch_code: string;
	loan_no: string | null;
}

export interface SchedulePreview {
	installment: number | null;
	total_repaid: number;
	total_interest: number;
	schedule: { installment_no: number; due_date: string; principal_due: number; interest_due: number; total_due: number; balance_after: number }[];
}

export interface ReportSummary {
	customers_by_kyc: { kyc_status: string; customers: number }[];
	deposits_by_product: { product_code: string; product_name: string; currency_code: string; accounts: number; balance: number }[];
	loan_book: {
		class_code: string;
		class_name: string;
		provision_pct: number;
		is_non_performing: number | boolean;
		loans: number;
		principal: number;
		outstanding: number;
		provision: number;
	}[];
	monthly_volume: { month: string; txn_type: string; transactions: number; amount: number }[];
	branches: { branch_code: string; branch_name: string; region_name: string; customers: number; deposits_ghs: number; active_loans: number }[];
	ledger_check: { accounts_out_of_balance: number; accounts_checked: number; total_debits: number; total_credits: number };
	npl_ratio_pct: number;
}

export interface StaffMember {
	employee_id: number;
	full_name: string;
	job_title: string;
	department_name: string;
	branch_code: string;
	branch_name: string;
	work_email: string | null;
	phone: string | null;
	hire_date: string;
	status: string;
	db_username: string;
}

/** Audit values arrive as parsed JSON (or as JSON text from older rows). */
export type AuditValues = string | Record<string, unknown> | unknown[] | null;

export interface AuditRow {
	audit_id: number;
	event_time: string;
	event_type: string;
	entity_table: string;
	entity_id: string | number | null;
	employee: string | null;
	db_user: string;
	proxy_user: string | null;
	client_identifier: string | null;
	module: string | null;
	old_values: AuditValues;
	new_values: AuditValues;
}

export interface DbAuditRow {
	event_timestamp: string;
	dbusername: string;
	dbproxy_username: string | null;
	action_name: string;
	object_schema: string | null;
	object_name: string | null;
	return_code: number;
	unified_audit_policies: string;
	client_identifier: string | null;
}

export interface DatabaseStatus {
	database: {
		name: string;
		log_mode: string;
		flashback_on: string;
		open_mode: string;
		force_logging: string;
		version_full: string;
		startup_time: string;
		host_name: string;
	} | null;
	encryption: {
		wallet: { wrl_type: string; status: string; wallet_type: string; keystore_mode: string }[];
		tablespaces: { tablespace_name: string; encryptionalg: string; encryptedts: string }[];
	};
	backups: { run_id: number; run_type: string; status: string; started_at: string; finished_at: string | null; output_mb: number | null; details: string | null }[];
	restore_points: { name: string; scn: number; time: string; guarantee_flashback_database: string; storage_size: number }[];
	jobs: {
		owner: string;
		job_name: string;
		enabled: string | boolean;
		state: string;
		repeat_interval: string | null;
		last_start_date: string | null;
		next_run_date: string | null;
		run_count: number;
		failure_count: number;
		last_status: string | null;
	}[];
}
