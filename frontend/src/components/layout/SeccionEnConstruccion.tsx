import type { LucideIcon } from 'lucide-react'

interface SeccionEnConstruccionProps {
  titulo: string
  descripcion: string
  icono: LucideIcon
  pendientes?: string[]
}

/**
 * Estado vacio para una seccion que ya existe en el menu pero todavia no tiene
 * contenido.
 *
 * Dice explicitamente que falta definir, en vez de mostrar tarjetas con ceros:
 * un dashboard que muestra 0 se lee como "no hubo ventas", no como "todavia no
 * esta conectado", y eso es peor que no mostrar nada.
 */
export function SeccionEnConstruccion({
  titulo,
  descripcion,
  icono: Icono,
  pendientes = [],
}: SeccionEnConstruccionProps) {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{titulo}</h1>
        <p className="text-sm text-muted-foreground mt-1 max-w-2xl">{descripcion}</p>
      </div>

      <div className="rounded-xl border border-dashed bg-card px-6 py-12 flex flex-col items-center text-center">
        <div className="w-12 h-12 rounded-full bg-dfgroup-blue/10 flex items-center justify-center mb-4">
          <Icono className="w-6 h-6 text-dfgroup-blue" aria-hidden="true" />
        </div>

        <h2 className="text-base font-medium">Seccion todavia sin contenido</h2>
        <p className="text-sm text-muted-foreground mt-1.5 max-w-md">
          El menu ya esta, falta acordar que se muestra y contra que datos.
        </p>

        {pendientes.length > 0 && (
          <ul className="mt-6 text-left space-y-2 text-sm text-muted-foreground">
            {pendientes.map((p) => (
              <li key={p} className="flex gap-2.5">
                <span className="mt-2 w-1 h-1 rounded-full bg-dfgroup-gold flex-shrink-0" />
                <span>{p}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}
