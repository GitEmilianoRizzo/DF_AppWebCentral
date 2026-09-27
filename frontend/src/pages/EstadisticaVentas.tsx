import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Area, AreaChart, Bar, BarChart, CartesianGrid, Cell, Legend, Pie, PieChart,
  ResponsiveContainer, Tooltip, XAxis, YAxis,
} from 'recharts'
import { AlertTriangle, ChevronDown, Loader2, Play, RotateCcw, SlidersHorizontal } from 'lucide-react'
import {
  estadisticaVentasApi,
  type EstadisticaDia,
  type EstadisticaFila,
  type EstadisticaVentasRespuesta,
} from '@/services/api'
import { cn } from '@/lib/utils'

/**
 * Estadistica de Ventas.
 *
 * Replica la pantalla homonima de SmartFran, que es con la que Damian valida
 * los numeros. Se mantiene a proposito su logica de uso: los filtros a la
 * izquierda, los totales a la derecha y las mismas solapas en el mismo orden
 * (Sucursales, Distribucion, Historia, Grupos, Productos, Promociones,
 * Sobreventas). Lo que cambia es la piel, no la forma de trabajar.
 *
 * DOS UTILIDADES EN LA MISMA GRILLA
 * ---------------------------------
 * "Utilidad" es Venta - Costo de mercaderia, que es lo que SmartFran llama
 * asi y permite cruzar contra esa pantalla. "C. Marginal" descuenta ademas
 * los insumos. Van las dos juntas justamente para que la comparacion no
 * parezca un error cuando dan distinto.
 *
 * EL "HASTA" ES INCLUSIVO ACA
 * ---------------------------
 * En SmartFran el campo Hasta muestra el instante en que se corrio la
 * consulta, y los datos llegan hasta el dia anterior completo: una captura que
 * decia "hasta 09-09 14:25" en realidad cubria hasta el 8. Aca se elige un dia
 * y se incluye entero; la conversion al limite exclusivo la hace el front.
 */

const SUCURSALES = [
  { id: 1, nombre: 'Lanus Oeste' },
  { id: 2, nombre: 'Escalada' },
  { id: 3, nombre: 'Fiorito' },
  { id: 4, nombre: 'Mayorista' },
]

const DIAS = [
  { id: 1, corto: 'Lun' }, { id: 2, corto: 'Mar' }, { id: 3, corto: 'Mie' },
  { id: 4, corto: 'Jue' }, { id: 5, corto: 'Vie' }, { id: 6, corto: 'Sab' },
  { id: 7, corto: 'Dom' },
]

const SOLAPAS = [
  { id: 'suc', rotulo: 'Sucursales' },
  { id: 'distr', rotulo: 'Distribucion' },
  { id: 'hist', rotulo: 'Historia' },
  { id: 'grupos', rotulo: 'Grupos' },
  { id: 'prod', rotulo: 'Productos' },
  { id: 'promo', rotulo: 'Promociones' },
  { id: 'sobre', rotulo: 'Sobreventas' },
] as const

type SolapaId = (typeof SOLAPAS)[number]['id']

// Paleta propia. Se aleja del verde fosforescente de SmartFran pero mantiene
// un color estable por sucursal, que es lo que se usa para leer los graficos.
const PALETA = ['#C9A227', '#2E6F8E', '#4A7C59', '#9B4F3F', '#6B5B95', '#B07D3C']
const COLOR_SUC: Record<string, string> = {
  'Lanus Oeste': '#B07D3C',
  Escalada: '#2E6F8E',
  Fiorito: '#4A7C59',
  Mayorista: '#6B5B95',
}

const money = (n: number | null) =>
  n === null || n === undefined ? '' : '$' + Math.round(n).toLocaleString('es-AR')
const moneyCorto = (n: number) =>
  n >= 1e6 ? '$' + (n / 1e6).toFixed(1) + 'M'
    : n >= 1e3 ? '$' + Math.round(n / 1e3) + 'k'
      : '$' + Math.round(n)
const num = (n: number | null, d = 0) =>
  n === null || n === undefined
    ? ''
    : n.toLocaleString('es-AR', { minimumFractionDigits: d, maximumFractionDigits: d })
const pct = (n: number | null, d = 2) =>
  n === null || n === undefined ? '' : num(n, d) + '%'

const hoyISO = () => new Date().toISOString().slice(0, 10)
const primerDiaMes = () => {
  const d = new Date()
  return new Date(d.getFullYear(), d.getMonth(), 1).toISOString().slice(0, 10)
}
/** El backend corta con "<", asi que el dia elegido entra entero sumandole uno. */
const diaSiguiente = (iso: string) => {
  const d = new Date(iso + 'T00:00:00')
  d.setDate(d.getDate() + 1)
  return d.toISOString().slice(0, 10)
}

export function EstadisticaVentas() {
  const [desde, setDesde] = useState(primerDiaMes())
  const [hasta, setHasta] = useState(hoyISO())
  const [sucursales, setSucursales] = useState<number[]>([1, 2, 3, 4])
  const [horaDesde, setHoraDesde] = useState(0)
  const [horaHasta, setHoraHasta] = useState(24)
  const [dias, setDias] = useState<number[]>([1, 2, 3, 4, 5, 6, 7])
  /**
   * Jornada comercial: el periodo va de las 02:00 del primer dia a las 02:00
   * del siguiente al ultimo, que es la convencion del Informe Diario y la que
   * usa el negocio para cerrar el dia.
   *
   * Es una ventana que CRUZA la medianoche, asi que no se puede pedir con el
   * filtro de Horarios: ese recorta una franja DENTRO de cada dia ("de 2 a 20
   * de todos los dias"), no un intervalo continuo. Poner 2 a 2 ahi no es la
   * jornada, y ademas es un rango vacio.
   *
   * Arranca apagado para no cambiarle los numeros a quien ya venia usando la
   * pantalla: con dia calendario es como se valido contra SmartFran.
   */
  const [jornada, setJornada] = useState(false)
  const [delivery, setDelivery] = useState<string>('')
  const [cajero, setCajero] = useState('')

  const [datos, setDatos] = useState<EstadisticaVentasRespuesta | null>(null)
  const [cargando, setCargando] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [solapa, setSolapa] = useState<SolapaId>('suc')
  // En celular los filtros arrancan plegados: ocupan una pantalla entera y lo
  // que se viene a ver son los numeros. En escritorio siempre estan a la vista.
  const [filtrosAbiertos, setFiltrosAbiertos] = useState(false)

  const calcular = useCallback(async () => {
    if (desde > hasta) {
      setError("La fecha 'desde' no puede ser posterior a 'hasta'.")
      return
    }
    setCargando(true)
    setError(null)
    try {
      // Con jornada comercial el corte es a las 02:00 y la franja horaria no
      // se aplica: las dos cosas juntas se pisarian.
      const corte = jornada ? 'T02:00' : 'T00:00'
      const r = await estadisticaVentasApi.getEstadistica({
        desde: desde + corte,
        hasta: diaSiguiente(hasta) + corte,
        sucursales: sucursales.length === SUCURSALES.length ? undefined : sucursales.join(','),
        horaDesde: jornada ? 0 : horaDesde,
        horaHasta: jornada ? 24 : horaHasta,
        diasSemana: dias.length === 7 ? undefined : dias.join(','),
        delivery: delivery === '' ? undefined : Number(delivery),
        cajero: cajero.trim() || undefined,
        topArticulos: 300,
      })
      setDatos(r)
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Error desconocido'
      setError('No se pudo calcular la estadistica: ' + msg)
    } finally {
      setCargando(false)
    }
  }, [desde, hasta, sucursales, horaDesde, horaHasta, dias, delivery, cajero, jornada])

  // Primera carga con los valores por defecto, para no mostrar una pantalla
  // vacia que obligue a adivinar que hay que apretar el boton.
  useEffect(() => {
    void calcular()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const alternar = (lista: number[], set: (v: number[]) => void, id: number) =>
    set(lista.includes(id) ? lista.filter((x) => x !== id) : [...lista, id].sort())

  const limpiar = () => {
    setDesde(primerDiaMes()); setHasta(hoyISO())
    setSucursales([1, 2, 3, 4]); setHoraDesde(0); setHoraHasta(24)
    setDias([1, 2, 3, 4, 5, 6, 7]); setDelivery(''); setCajero('')
  }

  const dist = useMemo(() => {
    const d = datos?.distribuciones ?? []
    return {
      hora: d.filter((x) => x.tipo === 'HORA'),
      diaSemana: d.filter((x) => x.tipo === 'DIASEMANA'),
      canal: d.filter((x) => x.tipo === 'CANAL'),
      entrega: d.filter((x) => x.tipo === 'ENTREGA'),
    }
  }, [datos])

  // Con los filtros plegados hay que poder saber que se esta mirando sin
  // desplegarlos. Se muestra el periodo y, si hay recortes, cuantos.
  const resumenFiltros = useMemo(() => {
    const dm = (iso: string) => iso.slice(8, 10) + '/' + iso.slice(5, 7)
    const recortes: string[] = []
    if (jornada) recortes.push('jornada 02-02')
    if (sucursales.length !== SUCURSALES.length) recortes.push(`${sucursales.length} suc.`)
    if (dias.length !== 7) recortes.push(`${dias.length} dias`)
    if (!jornada && (horaDesde !== 0 || horaHasta !== 24)) recortes.push(`${horaDesde}-${horaHasta}h`)
    if (delivery !== '') recortes.push(delivery === '1' ? 'delivery' : 'sin delivery')
    if (cajero.trim()) recortes.push(cajero.trim())
    return `${dm(desde)} a ${dm(hasta)}` + (recortes.length ? ` · ${recortes.join(' · ')}` : '')
  }, [desde, hasta, sucursales, dias, horaDesde, horaHasta, delivery, cajero, jornada])

  const t = datos?.totales

  return (
    <div className="space-y-5">
      <header>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Estadistica de Ventas</h1>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          Misma consulta que la pantalla de SmartFran, resuelta sobre la huella de venta.
        </p>
      </header>

      {error && (
        <div className="flex items-start gap-2 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
          <AlertTriangle className="mt-0.5 h-4 w-4 flex-shrink-0" />
          <span>{error}</span>
        </div>
      )}

      {/* Tres zonas como en SmartFran: filtros, contenido, totales.
          En una sola columna el orden cambia con `order`: primero los filtros
          (plegados, una linea), despues los totales y al final el detalle. Asi
          lo primero que se ve al entrar desde el celular son los numeros y no
          un formulario. El orden del DOM se mantiene para escritorio. */}
      <div className="grid grid-cols-1 gap-5 xl:grid-cols-[260px_minmax(0,1fr)_260px]">
        {/* ---------------------------------------------------------- filtros */}
        <aside className="order-1 space-y-4 xl:order-1 xl:sticky xl:top-4 xl:self-start">
          <button
            type="button"
            onClick={() => setFiltrosAbiertos((v) => !v)}
            aria-expanded={filtrosAbiertos}
            className="flex w-full items-center justify-between rounded-xl border border-gray-200 bg-white px-3 py-2.5 text-sm font-medium shadow-sm dark:border-gray-800 dark:bg-gray-900 xl:hidden"
          >
            <span className="flex items-center gap-2">
              <SlidersHorizontal className="h-4 w-4 text-dfgroup-gold" />
              Filtros
            </span>
            <span className="flex items-center gap-2 text-xs font-normal text-gray-400">
              {resumenFiltros}
              <ChevronDown className={cn('h-4 w-4 transition-transform', filtrosAbiertos && 'rotate-180')} />
            </span>
          </button>

          <div className={cn('space-y-4', !filtrosAbiertos && 'hidden xl:block')}>
          <Panel titulo="Periodo">
            <label className="block text-xs text-gray-500 dark:text-gray-400">Desde</label>
            <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} className={inputCls} />
            <label className="mt-2 block text-xs text-gray-500 dark:text-gray-400">Hasta (incluido)</label>
            <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} className={inputCls} />
            <label className="mt-3 flex cursor-pointer items-start gap-2 rounded-lg bg-gray-50 p-2 dark:bg-gray-800/60">
              <input
                type="checkbox"
                checked={jornada}
                onChange={(e) => setJornada(e.target.checked)}
                className="mt-0.5 h-3.5 w-3.5 rounded border-gray-300 text-dfgroup-gold focus:ring-dfgroup-gold"
              />
              <span className="text-xs leading-snug">
                <span className="font-medium text-gray-800 dark:text-gray-100">Jornada comercial</span>
                <span className="block text-[11px] text-gray-500 dark:text-gray-400">
                  De 02:00 a 02:00, igual que el Informe Diario
                </span>
              </span>
            </label>

            <p className="mt-2 text-[11px] leading-snug text-gray-400">
              {jornada
                ? 'El periodo va de las 02:00 del primer dia a las 02:00 del siguiente al ultimo. Con esto activado la franja de Horarios no se aplica.'
                : 'Dia calendario completo, de 00:00 a 24:00. Es el criterio con el que se valido contra SmartFran.'}
            </p>
          </Panel>

          <Panel titulo="Sucursal">
            <div className="space-y-1.5">
              {SUCURSALES.map((s) => (
                <label key={s.id} className="flex cursor-pointer items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={sucursales.includes(s.id)}
                    onChange={() => alternar(sucursales, setSucursales, s.id)}
                    className="h-3.5 w-3.5 rounded border-gray-300 text-dfgroup-gold focus:ring-dfgroup-gold"
                  />
                  <span className="flex items-center gap-1.5">
                    <span className="h-2.5 w-2.5 rounded-sm" style={{ background: COLOR_SUC[s.nombre] }} />
                    {s.nombre}
                  </span>
                </label>
              ))}
            </div>
          </Panel>

          <Panel titulo="Horarios">
            <div className={cn('flex items-center gap-2', jornada && 'opacity-40')}>
              <div className="flex-1">
                <label className="block text-xs text-gray-500 dark:text-gray-400">Desde</label>
                <input type="number" min={0} max={24} value={horaDesde} disabled={jornada}
                  onChange={(e) => setHoraDesde(Number(e.target.value))} className={inputCls} />
              </div>
              <div className="flex-1">
                <label className="block text-xs text-gray-500 dark:text-gray-400">Hasta</label>
                <input type="number" min={0} max={24} value={horaHasta} disabled={jornada}
                  onChange={(e) => setHoraHasta(Number(e.target.value))} className={inputCls} />
              </div>
            </div>
            <p className="mt-2 text-[11px] leading-snug text-gray-400">
              {jornada
                ? 'Sin efecto con la jornada comercial activada.'
                : 'Franja DENTRO de cada dia. Para un corte que cruza la medianoche, usar Jornada comercial.'}
            </p>
          </Panel>

          <Panel titulo="Dia de la semana">
            <div className="grid grid-cols-4 gap-1">
              {DIAS.map((d) => {
                const on = dias.includes(d.id)
                return (
                  <button key={d.id} type="button" onClick={() => alternar(dias, setDias, d.id)}
                    className={
                      'rounded px-1.5 py-1 text-[11px] font-medium transition-colors ' +
                      (on
                        ? 'bg-dfgroup-gold text-black'
                        : 'bg-gray-100 text-gray-500 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:hover:bg-gray-700')
                    }>
                    {d.corto}
                  </button>
                )
              })}
            </div>
          </Panel>

          <Panel titulo="Venta Delivery">
            <select value={delivery} onChange={(e) => setDelivery(e.target.value)} className={inputCls}>
              <option value="">Todos</option>
              <option value="1">Solo delivery</option>
              <option value="0">Sin delivery</option>
            </select>
          </Panel>

          <Panel titulo="Cajero">
            <input type="text" value={cajero} placeholder="Todos"
              onChange={(e) => setCajero(e.target.value)} className={inputCls} />
          </Panel>

          <div className="flex gap-2">
            <button type="button" onClick={() => void calcular()} disabled={cargando}
              className="flex flex-1 items-center justify-center gap-2 rounded-lg bg-dfgroup-gold px-3 py-2.5 text-sm font-semibold text-black transition-opacity hover:opacity-90 disabled:opacity-50">
              {cargando ? <Loader2 className="h-4 w-4 animate-spin" /> : <Play className="h-4 w-4" />}
              Calcular
            </button>
            <button type="button" onClick={limpiar} title="Volver a los valores por defecto"
              className="rounded-lg border border-gray-300 px-3 py-2.5 text-gray-500 transition-colors hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800">
              <RotateCcw className="h-4 w-4" />
            </button>
            </div>
          </div>
        </aside>

        {/* -------------------------------------------------------- contenido */}
        <main className="order-3 min-w-0 space-y-4 xl:order-2">
          {/* Las solapas no se envuelven en celular: se deslizan de costado,
              que mantiene el mismo orden que en SmartFran y evita que el
              encabezado ocupe tres renglones. */}
          <nav className="-mx-1 flex gap-1 overflow-x-auto rounded-lg bg-gray-100 p-1 dark:bg-gray-800 xl:flex-wrap xl:overflow-visible">
            {SOLAPAS.map((s) => (
              <button key={s.id} type="button" onClick={() => setSolapa(s.id)}
                className={
                  'flex-shrink-0 rounded-md px-3 py-1.5 text-sm font-medium transition-colors ' +
                  (solapa === s.id
                    ? 'bg-white text-gray-900 shadow-sm dark:bg-gray-900 dark:text-white'
                    : 'text-gray-500 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200')
                }>
                {s.rotulo}
              </button>
            ))}
          </nav>

          {cargando && !datos ? (
            <div className="flex h-64 items-center justify-center rounded-xl border border-gray-200 dark:border-gray-800">
              <Loader2 className="h-6 w-6 animate-spin text-dfgroup-gold" />
            </div>
          ) : !datos ? null : (
            <>
              {solapa === 'suc' && (
                <>
                  <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
                    <Tarjeta titulo="Ventas por sucursal">
                      <Torta datos={datos.por_sucursal.map((f) => ({ name: f.detalle, value: f.venta }))}
                        colorPorNombre={(n) => COLOR_SUC[n]} />
                    </Tarjeta>
                    <Tarjeta titulo="Ventas por lugar de entrega">
                      <Torta datos={dist.entrega.map((d) => ({ name: d.clave, value: d.venta }))} />
                    </Tarjeta>
                  </div>
                  <Grilla filas={datos.por_sucursal} conPedidos />
                </>
              )}

              {solapa === 'distr' && (
                <>
                  <Tarjeta titulo="Distribucion de ventas por hora">
                    <Barras datos={dist.hora.map((d) => ({ name: d.clave, venta: d.venta }))} />
                  </Tarjeta>
                  <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
                    <Tarjeta titulo="Por dia de la semana">
                      <Barras datos={dist.diaSemana.map((d) => ({ name: d.clave, venta: d.venta }))} color="#2E6F8E" />
                    </Tarjeta>
                    <Tarjeta titulo="Por canal">
                      <Torta datos={dist.canal.map((d) => ({ name: d.clave, value: d.venta }))} />
                    </Tarjeta>
                  </div>
                </>
              )}

              {solapa === 'hist' && (
                <>
                  <Tarjeta titulo="Historia de ventas por dia">
                    <ResponsiveContainer width="100%" height={280}>
                      <AreaChart data={datos.historia.map((d) => ({
                        name: d.dia.slice(8, 10) + '/' + d.dia.slice(5, 7),
                        Venta: d.venta, Utilidad: d.utilidad, 'C. Marginal': d.contrib_marginal,
                      }))}>
                        <defs>
                          <linearGradient id="gVenta" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="5%" stopColor="#C9A227" stopOpacity={0.7} />
                            <stop offset="95%" stopColor="#C9A227" stopOpacity={0.05} />
                          </linearGradient>
                        </defs>
                        <CartesianGrid strokeDasharray="3 3" opacity={0.15} />
                        <XAxis dataKey="name" tick={{ fontSize: 11 }} />
                        <YAxis tickFormatter={moneyCorto} tick={{ fontSize: 11 }} width={60} />
                        <Tooltip formatter={(v: number) => money(v)} />
                        <Legend />
                        <Area type="monotone" dataKey="Venta" stroke="#C9A227" fill="url(#gVenta)" strokeWidth={2} />
                        <Area type="monotone" dataKey="Utilidad" stroke="#4A7C59" fill="none" strokeWidth={2} />
                        <Area type="monotone" dataKey="C. Marginal" stroke="#9B4F3F" fill="none" strokeWidth={2} strokeDasharray="4 3" />
                      </AreaChart>
                    </ResponsiveContainer>
                  </Tarjeta>
                  <TablaHistoria filas={datos.historia} />
                </>
              )}

              {solapa === 'grupos' && (
                <>
                  <Tarjeta titulo="Resumen de ventas por grupo">
                    <Barras datos={datos.por_grupo.slice(0, 14).map((f) => ({ name: f.detalle, venta: f.venta }))}
                      color="#6B5B95" alto={300} />
                  </Tarjeta>
                  <Grilla filas={datos.por_grupo} />
                </>
              )}

              {solapa === 'prod' && (
                <>
                  <Tarjeta titulo="Top 15 articulos por venta">
                    <Barras datos={datos.por_articulo.slice(0, 15).map((f) => ({ name: f.detalle, venta: f.venta }))}
                      color="#2E6F8E" alto={320} />
                  </Tarjeta>
                  <Grilla filas={datos.por_articulo} />
                </>
              )}

              {solapa === 'promo' && (
                <>
                  <Tarjeta titulo="Resumen de ventas por promocion">
                    <Barras datos={datos.por_promocion.slice(0, 14).map((f) => ({ name: f.detalle, venta: f.venta }))}
                      color="#B07D3C" alto={300} />
                  </Tarjeta>
                  <GrillaSimple filas={datos.por_promocion} />
                </>
              )}

              {solapa === 'sobre' && (
                <>
                  <Tarjeta titulo="Resumen de ventas por sobreventa">
                    <Barras datos={datos.por_sobreventa.slice(0, 14).map((f) => ({ name: f.detalle, venta: f.venta }))}
                      color="#9B4F3F" alto={300} />
                  </Tarjeta>
                  <GrillaSimple filas={datos.por_sobreventa} />
                </>
              )}
            </>
          )}
        </main>

        {/* ---------------------------------------------------------- totales */}
        <aside className="order-2 space-y-4 xl:order-3 xl:sticky xl:top-4 xl:self-start">
          <div className="rounded-xl bg-gradient-to-br from-[#1f3a4d] to-[#122430] p-4 text-white shadow-lg">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wider text-white/60">Totales</h3>
            <Dato rotulo="Total Ventas" valor={money(t?.venta_total ?? 0)} destacado />
            <Dato rotulo="Tiquet Promedio" valor={money(t?.ticket_promedio ?? 0)} />
            <Dato rotulo="Total Tiquets" valor={num(t?.tickets ?? 0)} />
            <Dato rotulo="Total Can. Articulos" valor={num(t?.cantidad ?? 0)} />
            <Dato rotulo="Total $ Desc. Promos" valor={money(t?.descuentos ?? 0)} />
            <Dato rotulo="Total # Promo" valor={num(t?.promos ?? 0)} />
            <Dato rotulo="Total Kilos" valor={num(t?.kilos ?? 0, 3)} />
          </div>

          <div className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-400">Rentabilidad</h3>
            <Dato rotulo="Costo mercaderia" valor={money(t?.costo ?? 0)} oscuro />
            <Dato rotulo="Utilidad" valor={money(t?.utilidad ?? 0)} oscuro
              sub={pct(t && t.venta_total ? (t.utilidad / t.venta_total) * 100 : 0)} />
            <Dato rotulo="C. Marginal" valor={money(t?.contrib_marginal ?? 0)} oscuro
              sub={pct(t && t.venta_total ? (t.contrib_marginal / t.venta_total) * 100 : 0)} />
            <p className="mt-2 text-[11px] leading-snug text-gray-400">
              Utilidad es Venta menos costo de mercaderia, el criterio de SmartFran.
              C. Marginal descuenta ademas los insumos.
            </p>
          </div>

          <div className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-400">Sobreventas</h3>
            <Dato rotulo="Activadas / Total" valor={num(t?.sv_activadas ?? 0)} oscuro
              sub={pct(t && t.tickets ? (t.sv_activadas / t.tickets) * 100 : 0)} />
            <Dato rotulo="Aceptadas / Total" valor={num(t?.sv_aceptadas ?? 0)} oscuro
              sub={pct(t && t.tickets ? (t.sv_aceptadas / t.tickets) * 100 : 0)} />
            <Dato rotulo="Aceptadas / Activadas" valor={pct(t && t.sv_activadas ? (t.sv_aceptadas / t.sv_activadas) * 100 : 0)} oscuro />
            <Dato rotulo="Total $ Sobreventas" valor={money(t?.sv_importe ?? 0)} oscuro />
            <Dato rotulo="Total Kilos Sobreventas" valor={num(t?.sv_kilos ?? 0, 3)} oscuro />
          </div>

          {!!t?.tickets_anulados && (
            <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-xs text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
              {num(t.tickets_anulados)} tiquets anulados en el periodo. No suman a la
              venta ni al conteo, igual que en SmartFran.
            </div>
          )}
        </aside>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Piezas chicas
// ---------------------------------------------------------------------------

const inputCls =
  'w-full rounded-md border border-gray-300 bg-white px-2 py-1.5 text-sm text-gray-900 ' +
  'focus:border-dfgroup-gold focus:outline-none focus:ring-1 focus:ring-dfgroup-gold ' +
  'dark:border-gray-700 dark:bg-gray-900 dark:text-white'

function Panel({ titulo, children }: { titulo: string; children: React.ReactNode }) {
  return (
    <div className="rounded-xl border border-gray-200 bg-white p-3 shadow-sm dark:border-gray-800 dark:bg-gray-900">
      <h3 className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-gray-400">{titulo}</h3>
      {children}
    </div>
  )
}

function Tarjeta({ titulo, children }: { titulo: string; children: React.ReactNode }) {
  return (
    <div className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
      <h3 className="mb-3 text-sm font-semibold text-gray-700 dark:text-gray-200">{titulo}</h3>
      {children}
    </div>
  )
}

function Dato({ rotulo, valor, sub, destacado, oscuro }: {
  rotulo: string; valor: string; sub?: string; destacado?: boolean; oscuro?: boolean
}) {
  return (
    <div className="flex items-baseline justify-between gap-2 border-b border-current/10 py-1.5 last:border-0">
      <span className={'text-xs ' + (oscuro ? 'text-gray-500 dark:text-gray-400' : 'text-white/70')}>
        {rotulo}
      </span>
      <span className="text-right">
        <span className={
          (destacado ? 'text-lg font-bold ' : 'text-sm font-semibold ') +
          (oscuro ? 'text-gray-900 dark:text-white' : 'text-white')
        }>
          {valor}
        </span>
        {sub && <span className="ml-1.5 text-[11px] text-gray-400">{sub}</span>}
      </span>
    </div>
  )
}

/*
 * Tabla adaptativa.
 *
 * Las columnas se declaran UNA sola vez y de ahi salen las dos vistas: la
 * tabla de escritorio y las tarjetas de celular. Mantener dos marcados
 * paralelos garantizaba que tarde o temprano mostraran cosas distintas.
 *
 * En celular no alcanza con scroll horizontal: trece columnas obligan a
 * arrastrar con el pulgar perdiendo de vista el nombre de la fila. La tarjeta
 * pone el detalle como titulo, la venta grande, y el resto en dos columnas de
 * rotulo y valor.
 */
interface Col<T> {
  rotulo: string
  valor: (f: T) => string
  /**
   * Celda de la fila TOTAL. Se declara por columna y no se calcula sola a
   * proposito: los porcentajes NO se suman. El total de "% Util." es la
   * utilidad total sobre la venta total; promediar los porcentajes de cada
   * sucursal daria un numero distinto y falso, porque pesan distinto.
   * Sin `total`, la celda del pie queda vacia.
   */
  total?: (filas: T[]) => string
  /** Titulo de la tarjeta en celular. Va uno solo por definicion. */
  titulo?: boolean
  /** Numero grande de la tarjeta. Va uno solo. */
  principal?: boolean
  tenue?: boolean
  dorado?: boolean
}

/** Suma una medida sobre las filas, tratando los nulos como cero. */
const sumar = <T,>(filas: T[], f: (x: T) => number | null | undefined) =>
  filas.reduce((a, x) => a + (f(x) ?? 0), 0)

/** Porcentaje recalculado sobre los totales, no promediado. */
const pctSobre = (parte: number, sobre: number) =>
  sobre === 0 ? '' : pct((parte / sobre) * 100)

function Tabla<T>({ filas, cols, clave, anchoMin = 980 }: {
  filas: T[]
  cols: Col<T>[]
  clave: (f: T, i: number) => string
  anchoMin?: number
}) {
  if (!filas.length) return <Vacio />

  const colTitulo = cols.find((c) => c.titulo) ?? cols[0]
  const colPrincipal = cols.find((c) => c.principal)
  const resto = cols.filter((c) => c !== colTitulo && c !== colPrincipal)
  const hayTotales = cols.some((c) => c.total)

  /* La primera columna queda clavada al costado izquierdo mientras la tabla
     se desplaza. Necesita fondo OPACO propio: si fuera transparente se verian
     las celdas pasando por debajo. Por eso cada zona (encabezado, cuerpo,
     pie) repite su color aca en vez de heredarlo de la fila. */
  const fijaCuerpo = 'sticky left-0 z-10 bg-white dark:bg-gray-900'
  const fijaCabeza = 'sticky left-0 z-20 bg-gray-100 dark:bg-gray-800'
  const fijaPie = 'sticky left-0 z-20 bg-gray-50 dark:bg-gray-800'
  // Sombra sutil al borde derecho: es lo que hace leer la columna como fijada
  // y no como una columna cualquiera que se superpone.
  const sombra = 'after:absolute after:inset-y-0 after:right-0 after:w-px after:bg-gray-200 dark:after:bg-gray-700'

  return (
    <>
      {/* ---- escritorio ---- */}
      <div className="hidden overflow-x-auto rounded-xl border border-gray-200 md:block dark:border-gray-800">
        <table className="w-full text-sm" style={{ minWidth: anchoMin }}>
          <thead className="bg-gray-100 text-[11px] uppercase tracking-wide text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <tr>
              {cols.map((c, i) => (
                <th key={c.rotulo}
                  className={cn('px-3 py-2', i === 0 ? cn('relative text-left', fijaCabeza, sombra) : 'text-right',
                    c.dorado && 'text-dfgroup-gold')}>
                  {c.rotulo}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {filas.map((f, i) => (
              <tr key={clave(f, i)} className="group hover:bg-gray-50 dark:hover:bg-gray-800/40">
                {cols.map((c, j) => (
                  <td key={c.rotulo}
                    className={cn('px-3 py-2',
                      j === 0
                        ? cn('relative font-medium text-gray-900 dark:text-gray-100', fijaCuerpo, sombra,
                             'group-hover:bg-gray-50 dark:group-hover:bg-gray-800')
                        : 'text-right tabular-nums',
                      c.tenue && 'text-gray-500')}>
                    {j === 0 ? <ConColor texto={c.valor(f)} /> : c.valor(f)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
          {hayTotales && (
            <tfoot className="border-t-2 border-gray-300 bg-gray-50 font-semibold dark:border-gray-700 dark:bg-gray-800">
              <tr>
                {cols.map((c, j) => (
                  <td key={c.rotulo}
                    className={cn('px-3 py-2.5',
                      j === 0
                        ? cn('relative text-left text-gray-900 dark:text-white', fijaPie, sombra)
                        : 'text-right tabular-nums text-gray-900 dark:text-white',
                      c.dorado && 'text-dfgroup-gold dark:text-dfgroup-gold')}>
                    {c.total ? c.total(filas) : ''}
                  </td>
                ))}
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      {/* ---- celular ---- */}
      <ul className="space-y-2 md:hidden">
        {filas.map((f, i) => (
          <li key={clave(f, i)}
            className="rounded-xl border border-gray-200 bg-white p-3 shadow-sm dark:border-gray-800 dark:bg-gray-900">
            <div className="flex items-baseline justify-between gap-3">
              <span className="min-w-0 flex-1 truncate text-sm font-semibold text-gray-900 dark:text-gray-100">
                <ConColor texto={colTitulo.valor(f)} />
              </span>
              {colPrincipal && (
                <span className="flex-shrink-0 text-base font-bold tabular-nums text-gray-900 dark:text-white">
                  {colPrincipal.valor(f)}
                </span>
              )}
            </div>
            <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 border-t border-gray-100 pt-2 dark:border-gray-800">
              {resto.map((c) => (
                <div key={c.rotulo} className="flex items-baseline justify-between gap-2">
                  <dt className={cn('text-[11px]', c.dorado ? 'text-dfgroup-gold' : 'text-gray-400')}>
                    {c.rotulo}
                  </dt>
                  <dd className="text-xs tabular-nums text-gray-700 dark:text-gray-300">{c.valor(f)}</dd>
                </div>
              ))}
            </dl>
          </li>
        ))}

        {/* En celular el total va como una tarjeta mas, al final y destacada:
            un <tfoot> no existe en esta vista. */}
        {hayTotales && (
          <li className="rounded-xl border-2 border-gray-300 bg-gray-50 p-3 shadow-sm dark:border-gray-700 dark:bg-gray-800">
            <div className="flex items-baseline justify-between gap-3">
              <span className="text-sm font-bold text-gray-900 dark:text-white">
                {colTitulo.total ? colTitulo.total(filas) : 'TOTAL'}
              </span>
              {colPrincipal?.total && (
                <span className="text-base font-bold tabular-nums text-gray-900 dark:text-white">
                  {colPrincipal.total(filas)}
                </span>
              )}
            </div>
            <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 border-t border-gray-200 pt-2 dark:border-gray-700">
              {resto.filter((c) => c.total).map((c) => (
                <div key={c.rotulo} className="flex items-baseline justify-between gap-2">
                  <dt className={cn('text-[11px]', c.dorado ? 'text-dfgroup-gold' : 'text-gray-500')}>
                    {c.rotulo}
                  </dt>
                  <dd className="text-xs font-semibold tabular-nums text-gray-900 dark:text-white">
                    {c.total!(filas)}
                  </dd>
                </div>
              ))}
            </dl>
          </li>
        )}
      </ul>
    </>
  )
}

/** Pone el cuadradito de color cuando el texto es una sucursal conocida. */
function ConColor({ texto }: { texto: string }) {
  const color = COLOR_SUC[texto]
  if (!color) return <>{texto}</>
  return (
    <span className="flex items-center gap-2">
      <span className="h-2.5 w-2.5 flex-shrink-0 rounded-sm" style={{ background: color }} />
      {texto}
    </span>
  )
}

/** Grilla completa: la que se cruza contra SmartFran columna por columna. */
function Grilla({ filas, conPedidos }: { filas: EstadisticaFila[]; conPedidos?: boolean }) {
  const cols: Col<EstadisticaFila>[] = [
    { rotulo: 'Detalle', valor: (f) => f.detalle, titulo: true, total: () => 'TOTAL' },
    { rotulo: 'Venta', valor: (f) => money(f.venta), principal: true,
      total: (fs) => money(sumar(fs, (f) => f.venta)) },
    { rotulo: '%', valor: (f) => pct(f.porcentaje), tenue: true,
      total: (fs) => pct(sumar(fs, (f) => f.porcentaje)) },
    ...(conPedidos ? [{ rotulo: 'Pedidos', valor: (f: EstadisticaFila) => num(f.pedidos),
      total: (fs: EstadisticaFila[]) => num(sumar(fs, (f) => f.pedidos)) }] : []),
    { rotulo: 'Cantidad', valor: (f) => num(f.cantidad),
      total: (fs) => num(sumar(fs, (f) => f.cantidad)) },
    { rotulo: '$ Dtos.', valor: (f) => money(f.descuentos),
      total: (fs) => money(sumar(fs, (f) => f.descuentos)) },
    { rotulo: '# Promo', valor: (f) => num(f.promos),
      total: (fs) => num(sumar(fs, (f) => f.promos)) },
    { rotulo: 'Kilos', valor: (f) => num(f.kilos, 3),
      total: (fs) => num(sumar(fs, (f) => f.kilos), 3) },
    { rotulo: 'Costo', valor: (f) => money(f.costo),
      total: (fs) => money(sumar(fs, (f) => f.costo)) },
    { rotulo: 'Utilidad', valor: (f) => money(f.utilidad),
      total: (fs) => money(sumar(fs, (f) => f.utilidad)) },
    // Recalculado sobre los totales, NO promediado: las sucursales pesan distinto.
    { rotulo: '% Util.', valor: (f) => pct(f.pct_utilidad), tenue: true,
      total: (fs) => pctSobre(sumar(fs, (f) => f.utilidad), sumar(fs, (f) => f.venta)) },
    { rotulo: 'C. Marginal', valor: (f) => money(f.contrib_marginal), dorado: true,
      total: (fs) => money(sumar(fs, (f) => f.contrib_marginal)) },
    { rotulo: '% CM', valor: (f) => pct(f.pct_contrib), dorado: true, tenue: true,
      total: (fs) => pctSobre(sumar(fs, (f) => f.contrib_marginal), sumar(fs, (f) => f.venta)) },
  ]
  return <Tabla filas={filas} cols={cols} clave={(f, i) => f.detalle + i} />
}

/** Para promociones y sobreventas, que solo tienen venta y cantidad. */
function GrillaSimple({ filas }: { filas: EstadisticaFila[] }) {
  const cols: Col<EstadisticaFila>[] = [
    { rotulo: 'Detalle', valor: (f) => f.detalle, titulo: true, total: () => 'TOTAL' },
    { rotulo: 'Venta', valor: (f) => money(f.venta), principal: true,
      total: (fs) => money(sumar(fs, (f) => f.venta)) },
    { rotulo: '%', valor: (f) => pct(f.porcentaje), tenue: true,
      total: (fs) => pct(sumar(fs, (f) => f.porcentaje)) },
    { rotulo: 'Cantidad', valor: (f) => num(f.cantidad),
      total: (fs) => num(sumar(fs, (f) => f.cantidad)) },
  ]
  return <Tabla filas={filas} cols={cols} clave={(f, i) => f.detalle + i} anchoMin={480} />
}

function TablaHistoria({ filas }: { filas: EstadisticaDia[] }) {
  const cols: Col<EstadisticaDia>[] = [
    { rotulo: 'Dia', titulo: true,
      valor: (f) => `${f.dia.slice(8, 10)}/${f.dia.slice(5, 7)}/${f.dia.slice(0, 4)}`,
      total: (fs) => `TOTAL (${fs.length} dias)` },
    { rotulo: 'Venta', valor: (f) => money(f.venta), principal: true,
      total: (fs) => money(sumar(fs, (f) => f.venta)) },
    { rotulo: 'Tiquets', valor: (f) => num(f.tickets),
      total: (fs) => num(sumar(fs, (f) => f.tickets)) },
    { rotulo: 'Kilos', valor: (f) => num(f.kilos, 3),
      total: (fs) => num(sumar(fs, (f) => f.kilos), 3) },
    { rotulo: 'Utilidad', valor: (f) => money(f.utilidad),
      total: (fs) => money(sumar(fs, (f) => f.utilidad)) },
    { rotulo: 'C. Marginal', valor: (f) => money(f.contrib_marginal), dorado: true,
      total: (fs) => money(sumar(fs, (f) => f.contrib_marginal)) },
  ]
  return <Tabla filas={filas} cols={cols} clave={(f) => f.dia} anchoMin={560} />
}

function Barras({ datos, color = '#C9A227', alto = 240 }: {
  datos: { name: string; venta: number }[]; color?: string; alto?: number
}) {
  if (!datos.length) return <Vacio />
  // Los nombres de articulo y de promocion son largos: recortados entran en
  // el eje sin que haya que girar la pantalla. El nombre completo sigue
  // estando en el tooltip.
  const recortar = (s: string) => (s.length > 14 ? s.slice(0, 13) + '.' : s)
  return (
    <ResponsiveContainer width="100%" height={alto}>
      <BarChart data={datos} margin={{ bottom: 40, left: -10 }}>
        <CartesianGrid strokeDasharray="3 3" opacity={0.15} vertical={false} />
        <XAxis dataKey="name" tick={{ fontSize: 10 }} angle={-40} textAnchor="end" interval={0}
          height={70} tickFormatter={recortar} />
        <YAxis tickFormatter={moneyCorto} tick={{ fontSize: 10 }} width={58} />
        <Tooltip formatter={(v: number) => money(v)} cursor={{ fill: 'rgba(0,0,0,0.04)' }} />
        <Bar dataKey="venta" name="Venta" fill={color} radius={[4, 4, 0, 0]} />
      </BarChart>
    </ResponsiveContainer>
  )
}

function Torta({ datos, colorPorNombre }: {
  datos: { name: string; value: number }[]; colorPorNombre?: (n: string) => string | undefined
}) {
  if (!datos.length) return <Vacio />
  const total = datos.reduce((a, d) => a + d.value, 0)
  return (
    // La etiqueta sobre la porcion lleva SOLO el porcentaje y los nombres van
    // en la leyenda. Poniendo "Nombre 32%" encima, en un celular las etiquetas
    // se pisan entre si y el grafico queda ilegible.
    <ResponsiveContainer width="100%" height={260}>
      <PieChart>
        <Pie data={datos} dataKey="value" nameKey="name" innerRadius="45%" outerRadius="72%" paddingAngle={2}
          label={(e: { value?: number }) =>
            total ? `${Math.round(((e.value ?? 0) / total) * 100)}%` : ''}
          labelLine={false}>
          {datos.map((d, i) => (
            <Cell key={d.name} fill={colorPorNombre?.(d.name) ?? PALETA[i % PALETA.length]} />
          ))}
        </Pie>
        <Legend verticalAlign="bottom" height={36} iconType="circle" iconSize={8}
          wrapperStyle={{ fontSize: 11 }} />
        <Tooltip formatter={(v: number) => money(v)} />
      </PieChart>
    </ResponsiveContainer>
  )
}

function Vacio() {
  return (
    <p className="py-8 text-center text-sm text-gray-400">
      No hay datos para los filtros elegidos.
    </p>
  )
}
