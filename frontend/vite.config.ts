import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    // El puerto del front y el de la API se pueden mover por variable de
    // entorno para poder tener desarrollo corriendo al mismo tiempo que el
    // deploy, que vive en el 7100 y es el que ve gente de afuera. Sin las
    // variables, el comportamiento es el de siempre.
    port: Number(process.env.VITE_PORT) || 3000,
    proxy: {
      '/api': {
        target: process.env.VITE_API_PROXY || 'http://localhost:7100',
        changeOrigin: true,
      },
    },
  },
})
