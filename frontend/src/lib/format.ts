// Display helpers: money, dates and readable labels.

const moneyFormats = new Map<string, Intl.NumberFormat>();

export function formatMoney(value: number | null | undefined, currency = 'GHS'): string {
	if (value === null || value === undefined) return '—';
	let fmt = moneyFormats.get(currency);
	if (!fmt) {
		fmt = new Intl.NumberFormat('en-GH', { style: 'currency', currency });
		moneyFormats.set(currency, fmt);
	}
	return fmt.format(value);
}

export function formatNumber(value: number | null | undefined, digits = 0): string {
	if (value === null || value === undefined) return '—';
	return new Intl.NumberFormat('en-GH', { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value);
}

const ISO = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$/;

/** Parse an API date. Values without a time zone are local wall-clock (Oracle DATEs). */
export function parseDate(value: string | null | undefined): Date | null {
	if (!value) return null;
	const m = ISO.exec(value);
	if (!m) {
		const d = new Date(value);
		return Number.isNaN(d.getTime()) ? null : d;
	}
	if (m[8]) return new Date(value);
	return new Date(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0), +(m[6] ?? 0));
}

const dateFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
const timeFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const monthFmt = new Intl.DateTimeFormat('en-GB', { month: 'short', year: '2-digit' });

export function formatDate(value: string | null | undefined): string {
	const d = parseDate(value);
	return d ? dateFmt.format(d) : '—';
}

export function formatDateTime(value: string | null | undefined): string {
	const d = parseDate(value);
	return d ? timeFmt.format(d) : '—';
}

/** "2026-11" to "Nov 26". */
export function formatMonth(value: string): string {
	const d = parseDate(`${value}-01`);
	return d ? monthFmt.format(d) : value;
}

/** Date for an <input type="date"> value (YYYY-MM-DD), today plus an offset of days. */
export function isoDay(offsetDays = 0): string {
	const d = new Date();
	d.setDate(d.getDate() + offsetDays);
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** "CASH_DEPOSIT" to "Cash deposit"; "1K_5K" to "1K 5K" is handled by the special cases. */
const SPECIAL: Record<string, string> = {
	UNDER_1K: 'Under GH₵1,000',
	'1K_5K': 'GH₵1,000 – 5,000',
	'5K_10K': 'GH₵5,000 – 10,000',
	'10K_50K': 'GH₵10,000 – 50,000',
	OVER_50K: 'Over GH₵50,000',
	GHANA_CARD: 'Ghana Card',
	NIA: 'NIA',
	KYC_APPROVAL: 'KYC approval',
	PENDING_KYC: 'Pending KYC',
	PENDING_VERIFICATION: 'Pending verification',
	REVIEW_DUE: 'Review due',
	TXN_APPROVAL: 'Transaction approval',
	TXN_REVERSAL: 'Reversal request',
	ACCOUNT_OPENING: 'Account opening',
	LOAN_DECISION: 'Loan decision',
	OLEM: 'OLEM',
	PEP: 'PEP',
	GHA: 'Ghana'
};

export function label(value: string | null | undefined): string {
	if (!value) return '—';
	if (SPECIAL[value]) return SPECIAL[value];
	const text = value.replaceAll('_', ' ').toLowerCase();
	return text.charAt(0).toUpperCase() + text.slice(1);
}

export function fullName(c: { title?: string | null; first_name: string; middle_name?: string | null; last_name: string }): string {
	return [c.first_name, c.middle_name, c.last_name].filter(Boolean).join(' ');
}

export function hoursText(hours: number): string {
	if (hours < 1) return 'under an hour';
	if (hours < 48) return `${Math.floor(hours)} h`;
	return `${Math.floor(hours / 24)} days`;
}

/** Label for use inside a sentence: "Account opening" becomes "account opening", "KYC approval" stays. */
export function inline(value: string | null | undefined): string {
	const text = label(value);
	return /^[A-Z]{2,}/.test(text) ? text : text.charAt(0).toLowerCase() + text.slice(1);
}
