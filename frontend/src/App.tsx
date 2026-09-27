import { Routes, Route, Navigate } from 'react-router-dom'
import { MainLayout } from './components/layout/MainLayout'
import { ProtectedRoute, useAuth } from './contexts/AuthContext'
import { Login } from './pages/Login'
import { InformeDiarioGrido } from './pages/InformeDiarioGrido'
import { EstadisticaVentas } from './pages/EstadisticaVentas'
import { Compras } from './pages/Compras'
import { Stock } from './pages/Stock'
import { TiposCambio } from './pages/TiposCambio'
import { Usuarios } from './pages/Usuarios'

// Redirect to dashboard if already authenticated
function PublicRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth()

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-screen">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-primary"></div>
      </div>
    )
  }

  if (isAuthenticated) {
    return <Navigate to="/" replace />
  }

  return <>{children}</>
}

function App() {
  return (
    <Routes>
      {/* Public routes */}
      <Route
        path="/login"
        element={
          <PublicRoute>
            <Login />
          </PublicRoute>
        }
      />

      {/* Protected routes */}
      <Route
        path="/"
        element={
          <ProtectedRoute>
            <MainLayout />
          </ProtectedRoute>
        }
      >
        {/* La raiz ya no es un dashboard: la primera seccion del menu es Ventas. */}
        <Route index element={<Navigate to="/ventas" replace />} />
        {/* Ventas no tiene pagina propia: en el menu es una rama que se
            despliega. Entrar por URL cae en su primera subseccion. */}
        <Route path="ventas" element={<Navigate to="/ventas/informe-grido" replace />} />
        <Route path="ventas/informe-grido" element={<InformeDiarioGrido />} />
        <Route path="ventas/estadistica" element={<EstadisticaVentas />} />
        <Route path="compras" element={<Compras />} />
        <Route path="stock" element={<Stock />} />
        <Route path="admin/tipos-cambio" element={<TiposCambio />} />
        {/* Admin-only routes */}
        <Route
          path="admin/usuarios"
          element={
            <ProtectedRoute requiredRoles={['ADMIN']}>
              <Usuarios />
            </ProtectedRoute>
          }
        />
      </Route>

      {/* Catch all - redirect to home */}
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}

export default App
