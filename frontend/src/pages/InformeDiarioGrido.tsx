import { Fragment, useEffect, useMemo, useState } from 'react'
import { AlertTriangle } from 'lucide-react'
import { informeGridoApi, type InformeGridoFila } from '@/services/api'

/**
 * Informe Diario GRIDO.
 *
 * Reproduce en pantalla el Excel que sale por mail todos los dias: mismas
 * columnas, mismo orden de sucursales, mismos subtotales y la misma alerta por
 * %SV bajo. La diferencia es que aca se elige el rango de jornadas.
 *
 * Los subtotales se calculan en el front y no en el SP a proposito: el Excel
 * tambien los arma con formulas sobre las filas de cajero, asi que haciendo lo
 * mismo los dos no pueden separarse.
 */

// Minimo aceptable de sobreventas aceptadas sobre activadas. Es el mismo
// UMBRAL_SV que usa informe_grido.py; si alla cambia, cambiarlo aca.
const UMBRAL_SV = 0.15

type Fila = InformeGridoFila

// Colores por sucursal, tomados del Excel.
const COLOR_SUCURSAL: Record<string, { barra: string; fila: string }> = {
  Fiorito: { barra: 'bg-[#4A7C59]', fila: 'bg-[#EBF5EE] dark:bg-[#1b2a20]' },
  Escalada: { barra: 'bg-[#2E4053]', fila: 'bg-[#EAF0FB] dark:bg-[#1a2330]' },
  'Lanus Oeste': { barra: 'bg-[#784212]', fila: 'bg-[#FEF5E7] dark:bg-[#2a2115]' },
}

const hoy = () => new Date().toISOString().slice(0, 10)
const ayer = () => new Date(Date.now() - 864e5).toISOString().slice(0, 10)

const money = (n: number) =>
  '$' + Math.round(n).toLocaleString('es-AR')
const num = (n: number, d = 0) =>
  n.toLocaleString('es-AR', { minimumFractionDigits: d, maximumFractionDigits: d })
const pct = (n: number | null) =>
  n === null ? '' : (n * 100).toLocaleString('es-AR', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + '%'

interface Totales {
  horas: number; kilos: number; ventas: number; tickets: number
  svAct: number; svAcep: number; promos: number; socios: number
  club: number; kilosClub: number; anuladas: number; dif: number
}

const cero = (): Totales => ({
  horas: 0, kilos: 0, ventas: 0, tickets: 0, svAct: 0, svAcep: 0,
  promos: 0, socios: 0, club: 0, kilosClub: 0, anuladas: 0, dif: 0,
})

function acumular(t: Totales, f: Fila): Totales {
  return {
    horas: t.horas + f.horas,
    kilos: t.kilos + f.kilos,
    ventas: t.ventas + f.ventas,
    tickets: t.tickets + f.tickets,
    svAct: t.svAct + f.sv_activadas,
    svAcep: t.svAcep + f.sv_aceptadas,
    promos: t.promos + f.promos,
    socios: t.socios + f.socios,
    club: t.club + f.ventas_club,
    kilosClub: t.kilosClub + f.kilos_club,
    anuladas: t.anuladas + f.anuladas,
    dif: t.dif + f.dif_caja,
  }
}

const div = (a: number, b: number) => (b === 0 ? null : a / b)

const grados = (n: number | null) => (n === null ? '' : num(n, 1) + '°')
const mm = (n: number | null) => (n === null ? '' : num(n, 1))

/**
 * Clima de una sucursal para su subtotal. No se arma con los turnos: dos
 * cajas trabajando a la vez sumarian dos veces la misma lluvia. Sale de los
 * valores de la jornada entera que manda el SP (suc_*), uno por dia: con un
 * solo dia es ese valor; con un rango, la lluvia se suma y la sensacion se
 * promedia entre dias.
 */
function climaSucursal(filas: Fila[]) {
  const porDia = new Map<string, Fila>()
  for (const f of filas) if (!porDia.has(f.fecha_operativa)) porDia.set(f.fecha_operativa, f)
  const dias = [...porDia.values()]
  const sens = dias.map((d) => d.suc_sensacion_termica).filter((v): v is number => v !== null)
  const lluvia = dias.map((d) => d.suc_lluvia_mm).filter((v): v is number => v !== null)
  return {
    sens: sens.length ? sens.reduce((a, b) => a + b, 0) / sens.length : null,
    lluvia: lluvia.length ? lluvia.reduce((a, b) => a + b, 0) : null,
  }
}

export function InformeDiarioGrido() {
  const [desde, setDesde] = useState(ayer())
  const [hasta, setHasta] = useState(ayer())
  const [filas, setFilas] = useState<Fila[]>([])
  const [cargando, setCargando] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelado = false
    setCargando(true)
    setError(null)
    informeGridoApi
      .getInforme(desde, hasta)
      .then((d) => { if (!cancelado) setFilas(d) })
      .catch((e) => {
        if (!cancelado) {
          setError(e?.response?.data?.error ?? 'No se pudo traer el informe.')
          setFilas([])
        }
      })
      .finally(() => { if (!cancelado) setCargando(false) })
    return () => { cancelado = true }
  }, [desde, hasta])

  const variosDias = desde !== hasta

  // Agrupado por sucursal, respetando el orden del informe.
  const grupos = useMemo(() => {
    const m = new Map<string, { rotulo: string; orden: number; filas: Fila[] }>()
    for (const f of filas) {
      const g = m.get(f.sucursal_rotulo)
      if (g) g.filas.push(f)
      else m.set(f.sucursal_rotulo, { rotulo: f.sucursal_rotulo, orden: f.orden_sucursal, filas: [f] })
    }
    return [...m.values()].sort((a, b) => a.orden - b.orden)
  }, [filas])

  const total = useMemo(() => filas.reduce(acumular, cero()), [filas])

  const COLS = 22

  return (
    <div className="space-y-5">
      {/* --- encabezado --- */}
      <div className="flex flex-wrap items-end gap-4">
        <div>
          {/* Migaja de pan, no un link: quien quiera volver usa el menu, que ya
              muestra donde esta parado. */}
          <p className="text-xs text-muted-foreground mb-1">Ventas</p>
          {/* Aca iba una leyenda que explicaba que son las mismas metricas del
              Excel y que la jornada va de 02:00 a 02:00. La saco a pedido de
              Damian: para quien usa el informe todos los dias es una linea que
              ya no aporta y le come lugar al titulo.

              La explicacion de la jornada no se pierde del todo: queda como
              ayuda emergente sobre las fechas, que es donde hace falta y solo
              para el que la busque. */}
          <h1 className="text-2xl font-semibold tracking-tight">Informe Diario GRIDO</h1>
        </div>

        <div className="flex flex-wrap items-end gap-3 ml-auto">
          <label
            className="flex flex-col gap-1"
            title="Jornada comercial: de las 02:00 de este dia a las 02:00 del siguiente."
          >
            <span className="text-[10px] font-semibold tracking-wider uppercase text-muted-foreground">Desde</span>
            <input
              type="date" value={desde} max={hasta}
              onChange={(e) => setDesde(e.target.value)}
              className="h-9 rounded-md border bg-background px-2.5 text-sm"
            />
          </label>
          <label
            className="flex flex-col gap-1"
            title="Jornada comercial: de las 02:00 de este dia a las 02:00 del siguiente."
          >
            <span className="text-[10px] font-semibold tracking-wider uppercase text-muted-foreground">Hasta</span>
            <input
              type="date" value={hasta} min={desde} max={hoy()}
              onChange={(e) => setHasta(e.target.value)}
              className="h-9 rounded-md border bg-background px-2.5 text-sm"
            />
          </label>
          <button
            onClick={() => { setDesde(ayer()); setHasta(ayer()) }}
            className="h-9 rounded-md border px-3 text-sm hover:bg-muted transition-colors"
          >
            Ultima jornada
          </button>
        </div>
      </div>

      {/* --- metricas clave, como el bloque de arriba del Excel --- */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        {[
          ['Ventas totales', money(total.ventas)],
          ['Transacciones', num(total.tickets)],
          ['Ticket promedio', total.tickets ? money(total.ventas / total.tickets) : '-'],
          ['Socios Club Grido', num(total.socios)],
        ].map(([k, v]) => (
          <div key={k} className="rounded-lg border bg-card px-4 py-3">
            <div className="text-[10px] font-semibold tracking-wider uppercase text-muted-foreground">{k}</div>
            <div className="text-xl font-semibold mt-0.5 tabular-nums">{v}</div>
          </div>
        ))}
      </div>

      {/* --- leyenda de la alerta --- */}
      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        <span className="inline-flex items-center gap-1.5 rounded px-2 py-1 bg-[#C0392B] text-white font-medium">
          <AlertTriangle className="w-3 h-3" aria-hidden="true" />
          ALERTA
        </span>
        <span>%SV por debajo del estandar ({pct(UMBRAL_SV)})</span>
      </div>

      {error && (
        <div className="rounded-lg border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm">
          {error}
        </div>
      )}

      {/* En celular la matriz se lee deslizando de costado. Se avisa porque el
          corte de la tabla no siempre deja ver que hay mas columnas. */}
      <p className="text-xs text-muted-foreground md:hidden">
        Desliza la tabla de costado para ver el resto de las columnas.
      </p>

      {/* --- la matriz ---
          A diferencia de Estadistica de Ventas, aca NO se pasa a tarjetas en
          celular: el valor de esta pantalla es ser la misma matriz que el
          Excel, con sus subtotales por sucursal y su fila de total. Romperla
          en tarjetas perderia justamente eso. Lo que se hace es acotar el alto
          en pantallas chicas y dejar el encabezado fijo, asi al desplazarse no
          se pierde de vista que columna se esta mirando. */}
      <div className="rounded-lg border bg-card overflow-x-auto max-h-[70vh] overflow-y-auto md:max-h-none md:overflow-y-visible">
        <table className="w-full text-[11.5px] border-collapse">
          <thead>
            <tr className="bg-[#455A64] text-white">
              {variosDias && <Th>Jornada</Th>}
              <Th className="text-left min-w-[150px]">Sucursal / Cajero</Th>
              <Th>Turno</Th><Th>Caja</Th><Th>Horario</Th><Th>Horas</Th><Th>Kilos</Th>
              <Th>Ventas ($)</Th><Th>Ticket Prom.</Th>
              <Th className="bg-[#8D5524]">Tickets</Th>
              <Th className="bg-[#8D5524]">SV Activadas</Th>
              <Th className="bg-[#8D5524]">SV Aceptadas</Th>
              <Th className="bg-[#8D5524]">%SV</Th>
              <Th>Promos ($)</Th><Th>%Promos</Th>
              <Th className="bg-[#1F618D]">Nuevos Socios</Th>
              <Th className="bg-[#1F618D]">Ventas Club Grido</Th>
              <Th className="bg-[#1F618D]">Kilos Club</Th>
              <Th className="bg-[#1F618D]">%VCG /Kilos</Th>
              <Th>Anuladas</Th><Th>Dif. de Caja</Th>
              <Th className="bg-[#117A65]">Sens. Térmica Prom.</Th>
              <Th className="bg-[#117A65]">Lluvia (mm)</Th>
            </tr>
          </thead>

          <tbody>
            {cargando && (
              <tr><Td colSpan={COLS + (variosDias ? 1 : 0)} className="text-center py-10 text-muted-foreground">
                Cargando...
              </Td></tr>
            )}

            {!cargando && filas.length === 0 && !error && (
              <tr><Td colSpan={COLS + (variosDias ? 1 : 0)} className="text-center py-10 text-muted-foreground">
                No hubo ventas en el rango elegido.
              </Td></tr>
            )}

            {!cargando && grupos.map((g) => {
              const sub = g.filas.reduce(acumular, cero())
              const climaSub = climaSucursal(g.filas)
              const color = COLOR_SUCURSAL[g.rotulo] ?? { barra: 'bg-slate-600', fila: 'bg-muted/40' }
              return (
                // La key va en el Fragment, que es el elemento que devuelve el
                // map; ponerla en el <tr> de adentro no le sirve a React para
                // identificar el grupo.
                <Fragment key={g.rotulo}>
                  {/* subtotal de la sucursal */}
                  <tr className={`${color.barra} text-white font-semibold`}>
                    {variosDias && <Td />}
                    <Td className="text-left">{g.rotulo}</Td>
                    <Td>Todos</Td><Td /><Td />
                    <Td>{num(sub.horas, 1)}</Td>
                    <Td>{num(sub.kilos, 1)}</Td>
                    <Td>{money(sub.ventas)}</Td>
                    <Td>{sub.tickets ? money(sub.ventas / sub.tickets) : ''}</Td>
                    <Td>{num(sub.tickets)}</Td>
                    <Td>{num(sub.svAct)}</Td>
                    <Td>{num(sub.svAcep)}</Td>
                    <Td>{pct(div(sub.svAcep, sub.svAct))}</Td>
                    <Td>{money(sub.promos)}</Td>
                    <Td>{pct(div(sub.promos, sub.ventas))}</Td>
                    <Td>{num(sub.socios)}</Td>
                    <Td>{money(sub.club)}</Td>
                    <Td>{num(sub.kilosClub, 1)}</Td>
                    <Td>{pct(div(sub.kilosClub, sub.kilos))}</Td>
                    <Td>{num(sub.anuladas)}</Td>
                    <Td>{money(sub.dif)}</Td>
                    <Td>{grados(climaSub.sens)}</Td>
                    <Td>{mm(climaSub.lluvia)}</Td>
                  </tr>

                  {/* cajeros */}
                  {g.filas.map((f) => {
                    const sv = div(f.sv_aceptadas, f.sv_activadas)
                    // Sin sobreventas activadas no hay nada que juzgar: marcar en
                    // rojo a quien no tuvo ninguna seria acusarlo de un bajo
                    // rendimiento que no ocurrio.
                    const alerta = sv !== null && sv < UMBRAL_SV
                    return (
                      <tr key={`${f.fecha_operativa}-${f.turno}-${f.caja}-${f.cajero}`} className={color.fila}>
                        {variosDias && <Td className="tabular-nums">{f.fecha_operativa.slice(0, 10)}</Td>}
                        <Td className="text-left pl-6">{f.cajero}</Td>
                        <Td>{f.turno}</Td>
                        {/* La caja de delivery dice DELI en lugar del numero, con el
                            mismo estilo que el resto (pedido de Damian). El numero
                            queda en la ayuda emergente. */}
                        <Td>
                          {f.es_caja_delivery
                            ? <span title={`Caja ${f.caja} - delivery`}>DELI</span>
                            : f.caja}
                        </Td>
                        <Td>{f.horario}</Td>
                        <Td>{num(f.horas, 1)}</Td>
                        <Td>{num(f.kilos, 1)}</Td>
                        <Td>{money(f.ventas)}</Td>
                        <Td>{f.tickets ? money(f.ventas / f.tickets) : ''}</Td>
                        <Td>{num(f.tickets)}</Td>
                        <Td>{num(f.sv_activadas)}</Td>
                        <Td>{num(f.sv_aceptadas)}</Td>
                        <Td className={alerta ? 'bg-[#C0392B] text-white font-semibold' : ''}>{pct(sv)}</Td>
                        <Td>{money(f.promos)}</Td>
                        <Td>{pct(div(f.promos, f.ventas))}</Td>
                        <Td>{num(f.socios)}</Td>
                        <Td>{money(f.ventas_club)}</Td>
                        <Td>{num(f.kilos_club, 1)}</Td>
                        <Td>{pct(div(f.kilos_club, f.kilos))}</Td>
                        <Td>{num(f.anuladas)}</Td>
                        <Td>{money(f.dif_caja)}</Td>
                        <Td>{grados(f.sensacion_termica)}</Td>
                        <Td>{mm(f.lluvia_mm)}</Td>
                      </tr>
                    )
                  })}
                </Fragment>
              )
            })}
          </tbody>

          {!cargando && filas.length > 0 && (
            <tfoot>
              <tr className="bg-[#1A252F] text-white font-semibold">
                {variosDias && <Td />}
                <Td className="text-left">TOTAL</Td>
                <Td /><Td /><Td />
                <Td>{num(total.horas, 1)}</Td>
                <Td>{num(total.kilos, 1)}</Td>
                <Td>{money(total.ventas)}</Td>
                <Td>{total.tickets ? money(total.ventas / total.tickets) : ''}</Td>
                <Td>{num(total.tickets)}</Td>
                <Td>{num(total.svAct)}</Td>
                <Td>{num(total.svAcep)}</Td>
                <Td>{pct(div(total.svAcep, total.svAct))}</Td>
                <Td>{money(total.promos)}</Td>
                <Td>{pct(div(total.promos, total.ventas))}</Td>
                <Td>{num(total.socios)}</Td>
                <Td>{money(total.club)}</Td>
                <Td>{num(total.kilosClub, 1)}</Td>
                <Td>{pct(div(total.kilosClub, total.kilos))}</Td>
                <Td>{num(total.anuladas)}</Td>
                <Td>{money(total.dif)}</Td>
                {/* El clima es de cada sucursal: un total entre zonas no dice nada. */}
                <Td /><Td />
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      <p className="text-xs text-muted-foreground max-w-4xl leading-relaxed">
        <strong className="font-medium">Promos</strong> es la venta de los articulos vendidos en una
        promocion, a precio de lista; no incluye sobreventas ni canjes de puntos.{' '}
        <strong className="font-medium">%VCG</strong> son los kilos vendidos a socios Club Grido sobre
        el total de kilos. <strong className="font-medium">Clima</strong>: sensacion termica promedio y
        lluvia en las horas en que el turno tuvo ventas; en el subtotal, las de la sucursal en toda la
        jornada. <strong className="font-medium">DELI</strong> es la caja de delivery.{' '}
        <strong className="font-medium">Nuevos socios</strong> se
        imputa al primer turno de cada cajero en la jornada: las altas de tarjeta no guardan en que
        turno se hicieron, asi que repartirlas entre todos duplicaria el total.
      </p>
    </div>
  )
}

function Th({ children, className = '' }: { children?: React.ReactNode; className?: string }) {
  /* El encabezado queda fijo arriba mientras se recorre la tabla, que en
     celular es lo que evita perder de vista que columna se esta mirando.
     Va en el <th> y no en el <thead> porque con border-collapse el navegador
     no fija el grupo. Y el fondo se pone por estilo en linea cuando la celda
     no trae uno propio: dos clases de Tailwind con color arbitrario compiten
     sin un orden garantizado, y una celda transparente dejaria ver las filas
     pasando por debajo. */
  const traeFondo = className.includes('bg-')
  return (
    <th
      style={traeFondo ? undefined : { backgroundColor: '#455A64' }}
      className={`sticky top-0 z-10 px-2 py-2 font-semibold text-[10px] uppercase tracking-wide whitespace-nowrap ${className}`}
    >
      {children}
    </th>
  )
}

function Td({
  children, className = '', colSpan,
}: { children?: React.ReactNode; className?: string; colSpan?: number }) {
  return (
    <td colSpan={colSpan} className={`px-2 py-1.5 text-right tabular-nums whitespace-nowrap border-t ${className}`}>
      {children}
    </td>
  )
}
