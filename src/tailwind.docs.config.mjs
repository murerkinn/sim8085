/** @type {import('tailwindcss').Config} */

import starlightPlugin from '@astrojs/starlight-tailwind';

export default {
	content: [
	  './src/content/docs/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'
	],
	darkMode: 'selector',
	theme: {
		extend: {},
	},
	plugins: [starlightPlugin()],
}
