import type { Role } from './types';

export const ROLE_LABELS: Record<Role, string> = {
	WB_STAFF: 'Staff',
	WB_TELLER: 'Teller',
	WB_SUPERVISOR: 'Teller supervisor',
	WB_CUSTOMER_SERVICE: 'Customer service',
	WB_KYC_APPROVER: 'KYC and account approver',
	WB_LOAN_OFFICER: 'Loan officer',
	WB_CREDIT: 'Credit',
	WB_REPORTS: 'Reports',
	WB_AUDITOR: 'Auditor',
	WB_HR: 'Human resources',
	WB_BACKUP_ADMIN: 'Backup administrator'
};

/** Which roles may decide which approval type (mirrors the API). */
export const DECIDER_ROLE: Record<string, Role> = {
	TXN_APPROVAL: 'WB_SUPERVISOR',
	TXN_REVERSAL: 'WB_SUPERVISOR',
	KYC_APPROVAL: 'WB_KYC_APPROVER',
	ACCOUNT_OPENING: 'WB_KYC_APPROVER',
	LOAN_DECISION: 'WB_CREDIT'
};
