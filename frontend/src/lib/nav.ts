import type { Role } from './types';

export interface NavItem {
	href: string;
	label: string;
	/** Visible only to employees with one of these roles (everyone when absent). */
	roles?: Role[];
	/** Icon path data (24x24 stroke icon). */
	icon: string;
}

export interface NavGroup {
	title: string;
	items: NavItem[];
}

const I = {
	home: 'M3 11l9-8 9 8M5 10v10h5v-6h4v6h5V10',
	people: 'M16 11a4 4 0 10-8 0 4 4 0 008 0zM4 21c0-4 3.5-6 8-6s8 2 8 6',
	plus: 'M12 5v14M5 12h14',
	cash: 'M3 7h18v10H3zM12 9.5a2.5 2.5 0 100 5 2.5 2.5 0 000-5zM6 10v4M18 10v4',
	list: 'M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01',
	check: 'M5 12l4 4L19 7M3 3h18v18H3z',
	loan: 'M4 20V10l8-6 8 6v10M9 20v-6h6v6',
	doc: 'M6 3h9l4 4v14H6zM14 3v5h5M9 13h6M9 17h6',
	chart: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
	shield: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z',
	db: 'M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3zM4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3',
	badge: 'M5 4h14v16H5zM9 9h6M9 13h6M9 17h3'
};

export const NAV: NavGroup[] = [
	{ title: 'Overview', items: [{ href: '/', label: 'Dashboard', icon: I.home }] },
	{
		title: 'Customers',
		items: [
			{ href: '/customers', label: 'Customers', icon: I.people },
			{ href: '/customers/new', label: 'New customer', roles: ['WB_CUSTOMER_SERVICE'], icon: I.plus }
		]
	},
	{
		title: 'Counter',
		items: [
			{ href: '/counter', label: 'Counter', roles: ['WB_TELLER'], icon: I.cash },
			{ href: '/transactions', label: 'Transactions', icon: I.list }
		]
	},
	{
		title: 'Approvals',
		items: [{ href: '/approvals', label: 'Approval queue', roles: ['WB_SUPERVISOR', 'WB_KYC_APPROVER', 'WB_CREDIT'], icon: I.check }]
	},
	{
		title: 'Lending',
		items: [
			{ href: '/loans', label: 'Loan book', roles: ['WB_LOAN_OFFICER', 'WB_CREDIT', 'WB_REPORTS', 'WB_AUDITOR'], icon: I.loan },
			{ href: '/loans/applications', label: 'Applications', roles: ['WB_LOAN_OFFICER', 'WB_CREDIT'], icon: I.doc }
		]
	},
	{
		title: 'Reports',
		items: [{ href: '/reports', label: 'Management reports', roles: ['WB_REPORTS', 'WB_AUDITOR'], icon: I.chart }]
	},
	{
		title: 'Administration',
		items: [
			{ href: '/admin/audit', label: 'Audit trail', roles: ['WB_AUDITOR'], icon: I.shield },
			{ href: '/admin/database', label: 'Database', roles: ['WB_BACKUP_ADMIN'], icon: I.db },
			{ href: '/staff', label: 'Staff directory', icon: I.badge }
		]
	}
];
