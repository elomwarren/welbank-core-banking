// The logged-in employee: loaded once from /api/auth/me, cleared on logout or 401.
import { goto } from '$app/navigation';
import { api, ApiError, setUnauthorizedHandler } from './api';
import type { Employee, LoginResult, Role } from './types';

class Session {
	employee = $state<Employee | null>(null);
	/** True once the first /auth/me answer (or 401) has arrived. */
	ready = $state(false);
	/** Set when the API says the database is down while loading the session. */
	problem = $state<ApiError | null>(null);

	get loggedIn(): boolean {
		return this.employee !== null;
	}

	/** True when the employee has at least one of the roles. */
	has(...roles: Role[]): boolean {
		const mine = this.employee?.roles ?? [];
		return roles.some((r) => mine.includes(r));
	}

	async load(): Promise<void> {
		try {
			this.employee = await api.get<Employee>('/auth/me');
			this.problem = null;
		} catch (e) {
			this.employee = null;
			if (e instanceof ApiError && e.status !== 401) this.problem = e;
		} finally {
			this.ready = true;
		}
	}

	async login(username: string, password: string): Promise<LoginResult> {
		const result = await api.post<LoginResult>('/auth/login', { username, password }, { quiet401: true });
		this.employee = result.employee;
		this.ready = true;
		this.problem = null;
		return result;
	}

	async logout(): Promise<void> {
		try {
			await api.post('/auth/logout', {}, { quiet401: true });
		} catch {
			// The cookie is dropped by the server; if it cannot be reached, leave the screen anyway.
		}
		this.employee = null;
		await goto('/login');
	}

	/** Called on any 401: forget the employee and go to the login page, remembering where we were. */
	expire(): void {
		this.employee = null;
		this.ready = true;
		const here = location.pathname + location.search;
		if (!location.pathname.startsWith('/login')) {
			void goto(`/login?next=${encodeURIComponent(here)}`, { replace: true });
		}
	}
}

export const session = new Session();
setUnauthorizedHandler(() => session.expire());
