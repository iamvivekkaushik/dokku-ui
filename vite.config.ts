import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

const target = `http://127.0.0.1:${process.env.DOKKU_UI_PORT ?? 4280}`;

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: Number(process.env.PORT ?? 5173),
    proxy: {
      '/api': { target },
      '/ws': { target: target.replace('http', 'ws'), ws: true },
    },
  },
});
