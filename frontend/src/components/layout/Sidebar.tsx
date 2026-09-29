import {
  TrendingUp,
  ShoppingCart,
  Boxes,
  ChevronRight,
  ChevronLeft,
  BadgeDollarSign,
  UserCog,
  Shield,
  Database,
  X,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { useAuth } from '@/contexts/AuthContext'
import { NavTree, type NavItem } from './NavTree'

/**
 * Menu principal.
 *
 * Las secciones con subsecciones se despliegan al tocarlas; las que todavia no
 * tienen, navegan directo. Cuando Compras o Stock sumen subsecciones, se les
 * cambia `href` por `children` y no hay que tocar nada mas.
 */
const navigation: NavItem[] = [
  {
    name: 'Ventas',
    icon: TrendingUp,
    children: [
      { name: 'Informe Diario GRIDO', href: '/ventas/informe-grido' },
      { name: 'Estadistica Ventas', href: '/ventas/estadistica' },
      // Va al final de Ventas y no en una seccion propia: se decide sobre lo
      // que se acaba de mirar en las dos de arriba.
      { name: 'Estrategia', href: '/ventas/estrategia' },
    ],
  },
  { name: 'Compras', icon: ShoppingCart, href: '/compras' },
  { name: 'Stock', icon: Boxes, href: '/stock' },
  {
    name: 'ABMs',
    icon: Database,
    children: [{ name: 'Fichero de Articulos', href: '/abm/articulos' }],
  },
  { name: 'Tipos de Cambio', icon: BadgeDollarSign, href: '/admin/tipos-cambio' },
]

const adminNavigation: NavItem[] = [
  { name: 'Usuarios', icon: UserCog, href: '/admin/usuarios' },
]

interface SidebarProps {
  collapsed?: boolean
  onToggle?: () => void
  isMobile?: boolean
  mobileOpen?: boolean
  onMobileClose?: () => void
}

function Marca({ colapsado = false }: { colapsado?: boolean }) {
  return (
    <div className={cn('flex items-center', colapsado ? 'justify-center' : 'gap-3')}>
      <div className="w-8 h-8 rounded-full bg-grido-blue flex items-center justify-center flex-shrink-0">
        <span className="text-white font-bold text-sm">DF</span>
      </div>
      {!colapsado && (
        <div>
          <h1 className="font-semibold text-lg tracking-tight">DF Group</h1>
          <p className="text-[10px] text-gray-400 -mt-0.5">Central de Franquicias</p>
        </div>
      )}
    </div>
  )
}

function TituloAdmin({ colapsado = false }: { colapsado?: boolean }) {
  if (colapsado) return <div className="pt-2 border-t border-white/10 mt-2" />
  return (
    <div className="pt-4 pb-2">
      <div className="flex items-center gap-2 px-3 text-xs font-semibold text-gray-500 uppercase tracking-wider">
        <Shield className="w-3 h-3" aria-hidden="true" />
        <span>Administración</span>
      </div>
    </div>
  )
}

export function Sidebar({
  collapsed = false,
  onToggle,
  isMobile = false,
  mobileOpen = false,
  onMobileClose,
}: SidebarProps) {
  const { user } = useAuth()
  const isAdmin = user?.rol?.codigo === 'ADMIN'

  // ---------------------------------------------------------------- mobile
  if (isMobile) {
    return (
      <>
        <div
          className={cn(
            'fixed inset-0 bg-black/50 z-40 transition-opacity lg:hidden',
            mobileOpen ? 'opacity-100' : 'opacity-0 pointer-events-none'
          )}
          onClick={onMobileClose}
        />

        <aside
          className={cn(
            'fixed left-0 top-0 h-full w-72 bg-dfgroup-charcoal text-white flex flex-col z-50 transform transition-transform duration-300 ease-in-out lg:hidden',
            mobileOpen ? 'translate-x-0' : '-translate-x-full'
          )}
        >
          <div className="h-16 flex items-center justify-between px-4 border-b border-white/10">
            <Marca />
            <button
              onClick={onMobileClose}
              className="p-2 rounded-lg hover:bg-white/10 transition-colors"
              aria-label="Cerrar menú"
            >
              <X className="w-5 h-5" />
            </button>
          </div>

          <nav className="flex-1 px-3 py-4 space-y-1 overflow-y-auto">
            <NavTree items={navigation} onNavegar={onMobileClose} />
            {isAdmin && (
              <>
                <TituloAdmin />
                <NavTree items={adminNavigation} onNavegar={onMobileClose} />
              </>
            )}
          </nav>

          <div className="p-4 border-t border-white/10">
            <div className="px-3 py-2 rounded-lg bg-white/5">
              <p className="text-xs text-gray-400">Sistema de Gestion</p>
              <p className="text-sm font-medium">v1.2.0</p>
            </div>
          </div>
        </aside>
      </>
    )
  }

  // ------------------------------------------------------------- escritorio
  return (
    <aside
      className={cn(
        'bg-dfgroup-charcoal text-white flex-col hidden lg:flex transition-all duration-300',
        collapsed ? 'w-16' : 'w-64'
      )}
    >
      <div className="h-16 flex items-center justify-center border-b border-white/10">
        <Marca colapsado={collapsed} />
      </div>

      <nav className="flex-1 px-2 py-4 space-y-1 overflow-y-auto">
        <NavTree items={navigation} colapsado={collapsed} onExpandirSidebar={onToggle} />
        {isAdmin && (
          <>
            <TituloAdmin colapsado={collapsed} />
            <NavTree items={adminNavigation} colapsado={collapsed} onExpandirSidebar={onToggle} />
          </>
        )}
      </nav>

      <div className="p-2 border-t border-white/10">
        <button
          onClick={onToggle}
          className={cn(
            'w-full flex items-center justify-center p-2 rounded-lg hover:bg-white/10 transition-colors text-gray-400 hover:text-white',
            collapsed ? '' : 'gap-2'
          )}
          title={collapsed ? 'Expandir menú' : 'Contraer menú'}
        >
          {collapsed ? (
            <ChevronRight className="w-5 h-5" />
          ) : (
            <>
              <ChevronLeft className="w-5 h-5" />
              <span className="text-sm">Contraer</span>
            </>
          )}
        </button>
      </div>

      {!collapsed && (
        <div className="p-4 border-t border-white/10">
          <div className="px-3 py-2 rounded-lg bg-white/5">
            <p className="text-xs text-gray-400">Sistema de Gestion</p>
            <p className="text-sm font-medium">v1.2.0</p>
          </div>
        </div>
      )}
    </aside>
  )
}
