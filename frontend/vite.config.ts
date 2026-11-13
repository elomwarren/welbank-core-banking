import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [
		sveltekit({
			// Single-page app: every route is served by index.html and rendered in the browser.
			adapter: adapter({ fallback: 'index.html' }),
			// SvelteKit 3 no longer defines $lib by itself.
			alias: { $lib: 'src/lib' }
		})
	],
	server: {
		port: 5173,
		// The browser always talks to its own origin; /api goes to the FastAPI backend.
		proxy: { '/api': 'http://127.0.0.1:8000' }
	},
	preview: { proxy: { '/api': 'http://127.0.0.1:8000' } }
});
