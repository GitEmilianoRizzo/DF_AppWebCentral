import { useEffect, useState } from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { ChevronRight, ChevronDown, type LucideIcon } from 'lucide-react'
import { cn } from '@/lib/utils'

/**
 * Arbol de navegacion del menu lateral.
 *
 * Un item puede ser hoja (tiene href y navega) o rama (tiene children y
 * despliega). Vive en su propio componente porque el Sidebar dibuja el menu dos
 * veces, para escritorio y para el cajon de mobile: tener la logica aca evita
 * que las dos versiones se vayan separando.
 */

export interface NavHijo {
  name: string
  href: string
}

export interface NavItem {
  name: string
  icon: LucideIcon
  /** Hoja: a donde va. Excluyente con children. */
  href?: string
  /** Rama: que se despliega al tocarla. */
  children?: NavHijo[]
}

interface NavTreeProps {
  items: NavItem[]
  /** Sidebar de escritorio contraida: solo iconos. */
  colapsado?: boolean
  /** Se llama cuando hay que expandir la sidebar contraida para poder desplegar. */
  onExpandirSidebar?: () => void
  /** En mobile, cerrar el cajon despues de navegar. */
  onNavegar?: () => void
}

const claseItem = (activo: boolean, colapsado: boolean) =>
  cn(
    'w-full flex items-center rounded-lg text-sm font-medium transition-colors',
    colapsado ? 'justify-center px-2 py-2.5' : 'gap-3 px-3 py-2.5',
    activo
      ? 'bg-dfgroup-gold/20 text-dfgroup-gold'
      : 'text-gray-300 hover:bg-white/5 hover:text-white'
  )

export function NavTree({ items, colapsado = false, onExpandirSidebar, onNavegar }: NavTreeProps) {
  const { pathname } = useLocation()

  const contieneRutaActiva = (item: NavItem) =>
    !!item.children?.some((h) => pathname === h.href || pathname.startsWith(h.href + '/'))

  // Las ramas que contienen la ruta actual arrancan abiertas, asi entrar por
  // URL directa deja el menu mostrando donde estas parado.
  const [abiertas, setAbiertas] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(items.filter(contieneRutaActiva).map((i) => [i.name, true]))
  )

  useEffect(() => {
    setAbiertas((prev) => {
      const siguiente = { ...prev }
      let cambio = false
      for (const item of items) {
        if (contieneRutaActiva(item) && !siguiente[item.name]) {
          siguiente[item.name] = true
          cambio = true
        }
      }
      return cambio ? siguiente : prev
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pathname])

  const alternar = (item: NavItem) => {
    // Con la sidebar contraida no hay lugar para el submenu: primero se expande.
    if (colapsado) {
      onExpandirSidebar?.()
      setAbiertas((p) => ({ ...p, [item.name]: true }))
      return
    }
    setAbiertas((p) => ({ ...p, [item.name]: !p[item.name] }))
  }

  return (
    <>
      {items.map((item) => {
        // --- hoja ---
        if (!item.children?.length) {
          return (
            <NavLink
              key={item.name}
              to={item.href!}
              title={colapsado ? item.name : undefined}
              onClick={onNavegar}
              className={({ isActive }) => claseItem(isActive, colapsado)}
            >
              {({ isActive }) => (
                <>
                  <item.icon className={cn('w-5 h-5 flex-shrink-0', isActive && 'text-dfgroup-gold')} />
                  {!colapsado && (
                    <>
                      <span className="flex-1 text-left">{item.name}</span>
                      <ChevronRight
                        className={cn('w-4 h-4 opacity-0 transition-opacity', isActive && 'opacity-100')}
                      />
                    </>
                  )}
                </>
              )}
            </NavLink>
          )
        }

        // --- rama ---
        const abierta = !!abiertas[item.name]
        const conRutaActiva = contieneRutaActiva(item)

        return (
          <div key={item.name}>
            <button
              type="button"
              onClick={() => alternar(item)}
              title={colapsado ? item.name : undefined}
              aria-expanded={colapsado ? undefined : abierta}
              className={claseItem(conRutaActiva && !abierta, colapsado)}
            >
              <item.icon
                className={cn('w-5 h-5 flex-shrink-0', conRutaActiva && 'text-dfgroup-gold')}
              />
              {!colapsado && (
                <>
                  <span className="flex-1 text-left">{item.name}</span>
                  {abierta ? (
                    <ChevronDown className="w-4 h-4 flex-shrink-0" aria-hidden="true" />
                  ) : (
                    <ChevronRight className="w-4 h-4 flex-shrink-0" aria-hidden="true" />
                  )}
                </>
              )}
            </button>

            {!colapsado && abierta && (
              // La guia vertical a la izquierda es lo que hace leer las hojas
              // como parte de la rama y no como items sueltos del menu.
              <div className="mt-1 ml-[22px] pl-3 border-l border-white/10 space-y-1">
                {item.children.map((hijo) => (
                  <NavLink
                    key={hijo.href}
                    to={hijo.href}
                    onClick={onNavegar}
                    className={({ isActive }) =>
                      cn(
                        'block rounded-md px-3 py-2 text-[13px] transition-colors',
                        isActive
                          ? 'bg-dfgroup-gold/20 text-dfgroup-gold font-medium'
                          : 'text-gray-400 hover:bg-white/5 hover:text-white'
                      )
                    }
                  >
                    {hijo.name}
                  </NavLink>
                ))}
              </div>
            )}
          </div>
        )
      })}
    </>
  )
}
