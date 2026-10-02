import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Area, AreaChart, Bar, BarChart, CartesianGrid, Cell, Legend, Pie, PieChart,
  ResponsiveContainer, Tooltip, XAxis, YAxis,
} from 'recharts'
import {
  AlertTriangle, AlignLeft, ArrowUpDown, BarChart3, ChevronDown, Download,
  Loader2, PieChart as PieChartIcon, Play, RotateCcw, Search,
  SlidersHorizontal, TrendingUp,
} from 'lucide-react'
import {
  estadisticaVentasApi,
  type EstadisticaDia,
  type EstadisticaFila,
  type EstadisticaPromoClima,
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
 * EL PERIODO SE ESCRIBE, CON HORA
 * -------------------------------
 * No hay selector de calendario: se tipea DD/MM/AAAA HH:MM, y tambien vale la
 * tira de numeros corrida. Es asi porque la hora es imprescindible: la jornada
 * comercial va de las 02:00 a las 02:00 del dia siguiente, y eso un selector
 * de fechas no lo puede expresar.
 *
 * "Hasta" es el instante de corte, EXCLUSIVO: para la jornada del 23 se
 * escribe 23/09/2026 02:00 a 24/09/2026 02:00.
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

/* ---------------------------------------------------------------------------
   Fecha y hora escritas a mano.

   El periodo se tipea, sin calendario: es mas rapido para quien ya sabe que
   rango quiere, y sobre todo permite indicar la HORA, que es lo que hace
   falta para pedir la jornada comercial (02:00 a 02:00). Un selector de
   fechas no puede expresar eso.

   Se acepta tanto el formato con separadores como la tira de numeros
   corrida, que es como se teclea rapido:
       25/09/2026 02:00
       250920260200
       25/09/2026        -> asume 02:00
       25092026          -> asume 02:00

   La hora que se asume es la del ARRANQUE DE LA JORNADA (02:00) y no la
   medianoche: escribir solo las fechas tiene que dar jornadas enteras, que es
   lo que se compara contra SmartFran.
   --------------------------------------------------------------------------- */
const dosDig = (n: number) => String(n).padStart(2, '0')

/** Date -> "25/09/2026 02:00" */
const aTexto = (d: Date) =>
  `${dosDig(d.getDate())}/${dosDig(d.getMonth() + 1)}/${d.getFullYear()} ` +
  `${dosDig(d.getHours())}:${dosDig(d.getMinutes())}`

/**
 * La hora con la que arranca todo cuando no se escribe ninguna.
 *
 * Son las 02:00 y no las 00:00 porque la JORNADA COMERCIAL va de las 02:00 a
 * las 02:00 del dia siguiente. Poner 00:00 por defecto obligaba a corregir la
 * hora en cada consulta, y olvidarse de hacerlo daba numeros que no coinciden
 * con SmartFran sin ningun aviso: se estarian mezclando dos medias jornadas.
 */
const HORA_JORNADA = 2

/** Texto tipeado -> Date, o null si no se entiende. */
function aFecha(texto: string): Date | null {
  const n = texto.replace(/\D/g, '')
  if (n.length !== 8 && n.length !== 12) return null

  const dia = +n.slice(0, 2)
  const mes = +n.slice(2, 4)
  const anio = +n.slice(4, 8)
  // Sin hora tipeada se asume el inicio de la jornada, no la medianoche.
  const hora = n.length === 12 ? +n.slice(8, 10) : HORA_JORNADA
  const min = n.length === 12 ? +n.slice(10, 12) : 0

  if (mes < 1 || mes > 12 || dia < 1 || dia > 31) return null
  if (hora > 23 || min > 59) return null
  if (anio < 2000 || anio > 2100) return null

  const d = new Date(anio, mes - 1, dia, hora, min, 0, 0)
  // Rebote del constructor: 31/02 se convierte en 03/03, y eso seria aceptar
  // una fecha que no existe. Si los componentes no vuelven iguales, no vale.
  if (d.getDate() !== dia || d.getMonth() !== mes - 1 || d.getFullYear() !== anio) return null
  return d
}

/** Date -> "2026-09-25T02:00", que es lo que espera la API. */
const aISO = (d: Date) =>
  `${d.getFullYear()}-${dosDig(d.getMonth() + 1)}-${dosDig(d.getDate())}` +
  `T${dosDig(d.getHours())}:${dosDig(d.getMinutes())}`

/**
 * El periodo con el que abre la pantalla: del 1 del mes a hoy, PEGADO A LA
 * JORNADA.
 *
 * Las dos puntas caen a las 02:00, asi que el rango son jornadas comerciales
 * enteras. "Hasta hoy a las 02:00" cierra la ultima jornada completa, que es
 * ademas la ultima que tiene datos: la huella se carga todos los dias a las
 * 12:30 con las jornadas ya terminadas.
 *
 * Antes abria de "1 del mes 00:00" a "ahora mismo", y eso cortaba la primera y
 * la ultima jornada por la mitad. Los totales no coincidian con SmartFran y no
 * habia forma de darse cuenta mirando la pantalla.
 */
const inicioDeMes = () => {
  const d = new Date()
  return new Date(d.getFullYear(), d.getMonth(), 1, HORA_JORNADA, 0, 0, 0)
}
const cierreDeHoy = () => {
  const d = new Date()
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), HORA_JORNADA, 0, 0, 0)
}

export function EstadisticaVentas() {
  // Se guardan como TEXTO, tal cual se tipean: mientras se escribe la fecha
  // esta incompleta y no hay Date valido que guardar. Se interpretan recien
  // al calcular.
  const [desde, setDesde] = useState(() => aTexto(inicioDeMes()))
  const [hasta, setHasta] = useState(() => aTexto(cierreDeHoy()))
  const [sucursales, setSucursales] = useState<number[]>([1, 2, 3, 4])
  const [dias, setDias] = useState<number[]>([1, 2, 3, 4, 5, 6, 7])
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
    const fDesde = aFecha(desde)
    const fHasta = aFecha(hasta)

    if (!fDesde || !fHasta) {
      setError(`Revisar ${!fDesde ? "'Desde'" : "'Hasta'"}: se espera DD/MM/AAAA HH:MM. ` +
               'Tambien sirve escribir los numeros de corrido, por ejemplo 250920260200.')
      return
    }
    if (fDesde >= fHasta) {
      setError("La fecha 'Desde' tiene que ser anterior a 'Hasta'.")
      return
    }

    // Al calcular se normaliza lo tipeado: si se escribio corrido, queda con
    // separadores y se ve que el sistema entendio bien.
    setDesde(aTexto(fDesde))
    setHasta(aTexto(fHasta))

    setCargando(true)
    setError(null)
    try {
      const r = await estadisticaVentasApi.getEstadistica({
        desde: aISO(fDesde),
        hasta: aISO(fHasta),
        sucursales: sucursales.length === SUCURSALES.length ? undefined : sucursales.join(','),
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
  }, [desde, hasta, sucursales, dias, delivery, cajero])

  // Primera carga con los valores por defecto, para no mostrar una pantalla
  // vacia que obligue a adivinar que hay que apretar el boton.
  useEffect(() => {
    void calcular()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const alternar = (lista: number[], set: (v: number[]) => void, id: number) =>
    set(lista.includes(id) ? lista.filter((x) => x !== id) : [...lista, id].sort())

  const limpiar = () => {
    setDesde(aTexto(inicioDeMes())); setHasta(aTexto(cierreDeHoy()))
    setSucursales([1, 2, 3, 4])
    setDias([1, 2, 3, 4, 5, 6, 7]); setDelivery(''); setCajero('')
  }

  const dist = useMemo(() => {
    const d = datos?.distribuciones ?? []

    /* El eje de horas arranca a las 6 y termina a las 5 de la madrugada
       siguiente, no a medianoche. Es el orden en que transcurre el dia del
       negocio: cortar a las 00:00 parte la noche en dos y manda la cola de
       ventas (de 0 a 5) al principio del grafico, donde se lee como si fuera
       la apertura. Ademas se completan las horas sin venta, asi el eje
       siempre tiene las 24 y las comparaciones entre periodos calzan. */
    const porHora = new Map(d.filter((x) => x.tipo === 'HORA').map((x) => [x.orden, x]))
    const hora = Array.from({ length: 24 }, (_, i) => {
      const h = (i + 6) % 24
      const x = porHora.get(h)
      return { name: dosDig(h) + ':00', venta: x ? x.venta : 0, tickets: x ? x.tickets : 0 }
    })

    return {
      hora,
      diaSemana: d.filter((x) => x.tipo === 'DIASEMANA'),
      mes: d.filter((x) => x.tipo === 'MES'),
      canal: d.filter((x) => x.tipo === 'CANAL'),
      entrega: d.filter((x) => x.tipo === 'ENTREGA'),
    }
  }, [datos])

  // Con los filtros plegados hay que poder saber que se esta mirando sin
  // desplegarlos. Se muestra el periodo y, si hay recortes, cuantos.
  const resumenFiltros = useMemo(() => {
    // Del periodo alcanza con dia/mes y la hora solo si no es medianoche.
    const corto = (t: string) => {
      const f = aFecha(t)
      if (!f) return '?'
      const dm = `${dosDig(f.getDate())}/${dosDig(f.getMonth() + 1)}`
      const hm = f.getHours() || f.getMinutes()
        ? ` ${dosDig(f.getHours())}:${dosDig(f.getMinutes())}` : ''
      return dm + hm
    }
    const recortes: string[] = []
    if (sucursales.length !== SUCURSALES.length) recortes.push(`${sucursales.length} suc.`)
    if (dias.length !== 7) recortes.push(`${dias.length} dias`)
    if (delivery !== '') recortes.push(delivery === '1' ? 'delivery' : 'sin delivery')
    if (cajero.trim()) recortes.push(cajero.trim())
    return `${corto(desde)} a ${corto(hasta)}` + (recortes.length ? ` · ${recortes.join(' · ')}` : '')
  }, [desde, hasta, sucursales, dias, delivery, cajero])

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
            <input type="text" inputMode="numeric" value={desde} placeholder="DD/MM/AAAA HH:MM"
              onChange={(e) => setDesde(e.target.value)}
              onBlur={() => { const f = aFecha(desde); if (f) setDesde(aTexto(f)) }}
              className={cn(inputCls, 'font-mono', !aFecha(desde) && 'border-red-400 dark:border-red-500')} />

            <label className="mt-2 block text-xs text-gray-500 dark:text-gray-400">Hasta</label>
            <input type="text" inputMode="numeric" value={hasta} placeholder="DD/MM/AAAA HH:MM"
              onChange={(e) => setHasta(e.target.value)}
              onBlur={() => { const f = aFecha(hasta); if (f) setHasta(aTexto(f)) }}
              className={cn(inputCls, 'font-mono', !aFecha(hasta) && 'border-red-400 dark:border-red-500')} />
            <p className="mt-2 text-[11px] leading-snug text-gray-400">
              Se escribe a mano. Los numeros de corrido tambien valen:
              <span className="font-mono text-gray-500 dark:text-gray-300"> 250920260200</span>.
              Si se escribe solo la fecha, la hora queda en
              <span className="font-mono text-gray-500 dark:text-gray-300"> 02:00</span>,
              que es el arranque de la jornada comercial.
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
                  {/* Los tres cortes de la venta, en el mismo orden que SmartFran:
                      quien la vende, por que canal entra y donde se entrega. */}
                  <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
                    <Grafico titulo="Ventas por sucursal" inicial="torta"
                      datos={datos.por_sucursal.map((f) => ({ name: f.detalle, value: f.venta }))}
                      colorPorNombre={(n) => COLOR_SUC[n]}
                      // Se baja la fila completa de la grilla, no solo la porcion
                      // del grafico: es lo que permite ver como se llega al numero.
                      detalle={datos.por_sucursal as unknown as Record<string, unknown>[]} />
                    <Grafico titulo="Ventas por canal" inicial="torta"
                      datos={dist.canal.map((d) => ({ name: d.clave, value: d.venta }))}
                      detalle={dist.canal as unknown as Record<string, unknown>[]} />
                    <Grafico titulo="Ventas por lugar de entrega" inicial="torta"
                      datos={dist.entrega.map((d) => ({ name: d.clave, value: d.venta }))}
                      detalle={dist.entrega as unknown as Record<string, unknown>[]} />
                  </div>
                  <Grilla filas={datos.por_sucursal} conPedidos conNeta />
                </>
              )}

              {solapa === 'distr' && (
                <>
                  <Grafico titulo="Distribucion de ventas por hora" inicial="barra"
                    datos={dist.hora.map((d) => ({ name: d.name, value: d.venta }))}
                    detalle={dist.hora.map((d) => ({ Hora: d.name, Venta: Math.round(d.venta), Tickets: d.tickets }))} />
                  <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
                    <Grafico titulo="Por dia de la semana" inicial="barra" color="#2E6F8E"
                      datos={dist.diaSemana.map((d) => ({ name: d.clave, value: d.venta }))}
                      detalle={dist.diaSemana as unknown as Record<string, unknown>[]} />
                    <Grafico titulo="Por mes" inicial="barra" color="#4A7C59"
                      datos={dist.mes.map((d) => ({ name: d.clave, value: d.venta }))}
                      detalle={dist.mes as unknown as Record<string, unknown>[]} />
                  </div>
                  <PanelMapas datos={datos} />
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
                  <Grafico titulo="Resumen de ventas por grupo" color="#6B5B95" alto={300}
                    datos={datos.por_grupo.slice(0, 14).map((f) => ({ name: f.detalle, value: f.venta }))}
                    detalle={datos.por_grupo as unknown as Record<string, unknown>[]} />
                  <Grilla filas={datos.por_grupo} />
                </>
              )}

              {solapa === 'prod' && (
                <>
                  <Grafico titulo="Top 15 articulos por venta" color="#2E6F8E" alto={320}
                    datos={datos.por_articulo.slice(0, 15).map((f) => ({ name: f.detalle, value: f.venta }))}
                    detalle={datos.por_articulo as unknown as Record<string, unknown>[]} />
                  <Grilla filas={datos.por_articulo} />
                </>
              )}

              {solapa === 'promo' && (
                <>
                  <Grafico titulo="Resumen de ventas por promocion" color="#B07D3C" alto={300}
                    datos={datos.por_promocion.slice(0, 14).map((f) => ({ name: f.detalle, value: f.venta }))}
                    detalle={datos.por_promocion as unknown as Record<string, unknown>[]} />
                  <GrillaSimple filas={datos.por_promocion} />
                  <MapaPromoClima filas={datos.promo_clima ?? []} />
                </>
              )}

              {solapa === 'sobre' && (
                <>
                  <Grafico titulo="Resumen de ventas por sobreventa" color="#9B4F3F" alto={300}
                    datos={datos.por_sobreventa.slice(0, 14).map((f) => ({ name: f.detalle, value: f.venta }))}
                    detalle={datos.por_sobreventa as unknown as Record<string, unknown>[]} />
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
            {/* Venta a precio de lista (= Estadisticas de SmartFran) y lo
                realmente cobrado (= Cierres de Turno de SmartFran y el Informe
                Diario). La diferencia son los descuentos de las plataformas.
                Con filtro de producto no aplica: el cobrado es del ticket. */}
            {t?.venta_neta != null && (
              <>
                <Dato rotulo="Total Desc. Plataformas" valor={money(t.desc_plataformas ?? 0)} />
                {Math.abs(t.otros_ajustes ?? 0) >= 1 && (
                  <Dato rotulo="Otros ajustes" valor={money(t.otros_ajustes ?? 0)} />
                )}
                <Dato rotulo="Total Venta Neta" valor={money(t.venta_neta)} destacado />
              </>
            )}
            <Dato rotulo="Tiquet Promedio" valor={money(t?.ticket_promedio ?? 0)} />
            <Dato rotulo="Total Tiquets" valor={num(t?.tickets ?? 0)} />
            <Dato rotulo="Total Can. Articulos" valor={num(t?.cantidad ?? 0)} />
            <Dato rotulo="Total $ Desc. Promos" valor={money(t?.descuentos ?? 0)} />
            <Dato rotulo="Total # Promo" valor={num(t?.promos ?? 0)} />
            <Dato rotulo="Total Kilos" valor={num(t?.kilos ?? 0, 2)} />
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
            <Dato rotulo="Total Kilos Sobreventas" valor={num(t?.sv_kilos ?? 0, 2)} oscuro />
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
  /**
   * Clave con la que se ordena. Va aparte de `valor` porque ese devuelve
   * texto ya formateado: ordenar por "$1.660.680" es ordenar alfabeticamente
   * y pone el 9 despues del 10.
   */
  orden?: (f: T) => number | string
  /** Columna de texto: habilita el buscador de la grilla. */
  texto?: boolean
  /** Titulo de la tarjeta en celular. Va uno solo por definicion. */
  titulo?: boolean
  /** Numero grande de la tarjeta. Va uno solo. */
  principal?: boolean
  tenue?: boolean
  dorado?: boolean
}

/** Saca acentos y pasa a minuscula, para que "promocion" encuentre "Promoción". */
const plano = (s: string) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

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
  const [ordenPor, setOrdenPor] = useState<string | null>(null)
  const [asc, setAsc] = useState(false)
  const [busqueda, setBusqueda] = useState('')

  const colTexto = cols.find((c) => c.texto)

  /* Filtrar y ordenar se hacen ACA y no sobre los datos crudos para que los
     totales del pie acompanen: si se filtra a un grupo, el total es el de ese
     grupo. Un pie que siguiera mostrando el total general al lado de filas
     filtradas induce a error. */
  const visibles = useMemo(() => {
    let v = filas
    const q = plano(busqueda.trim())
    if (q && colTexto) v = v.filter((f) => plano(colTexto.valor(f)).includes(q))

    const col = cols.find((c) => c.rotulo === ordenPor)
    if (col?.orden) {
      const signo = asc ? 1 : -1
      v = [...v].sort((a, b) => {
        const x = col.orden!(a), y = col.orden!(b)
        if (typeof x === 'number' && typeof y === 'number') return (x - y) * signo
        return String(x).localeCompare(String(y), 'es') * signo
      })
    }
    return v
  }, [filas, cols, ordenPor, asc, busqueda, colTexto])

  /** Valores distintos para sugerir mientras se escribe. */
  const sugerencias = useMemo(() => {
    if (!colTexto) return []
    return Array.from(new Set(filas.map((f) => colTexto.valor(f)))).sort().slice(0, 200)
  }, [filas, colTexto])

  const alternarOrden = (c: Col<T>) => {
    if (!c.orden) return
    if (ordenPor === c.rotulo) setAsc((v) => !v)
    else { setOrdenPor(c.rotulo); setAsc(false) }
  }

  const flecha = (c: Col<T>) => {
    if (!c.orden) return null
    const activa = ordenPor === c.rotulo
    return (
      <ArrowUpDown className={cn('ml-1 inline h-3 w-3 transition-opacity',
        activa ? 'opacity-100 text-dfgroup-gold' : 'opacity-25')} />
    )
  }

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
      {colTexto && (
        <div className="flex items-center gap-2">
          <div className="relative flex-1 md:max-w-xs">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-gray-400" />
            <input
              type="text" value={busqueda} onChange={(e) => setBusqueda(e.target.value)}
              list={`sug-${colTexto.rotulo}`}
              placeholder={`Buscar en ${colTexto.rotulo.toLowerCase()}...`}
              className={cn(inputCls, 'pl-8')}
            />
            {/* El navegador sugiere mientras se escribe con los valores que
                realmente hay en la grilla, no con una lista fija. */}
            <datalist id={`sug-${colTexto.rotulo}`}>
              {sugerencias.map((s) => <option key={s} value={s} />)}
            </datalist>
          </div>
          {busqueda && (
            <span className="text-xs text-gray-500">
              {visibles.length} de {filas.length}
              <button type="button" onClick={() => setBusqueda('')}
                className="ml-2 text-dfgroup-gold hover:underline">limpiar</button>
            </span>
          )}
        </div>
      )}

      {/* ---- escritorio ---- */}
      <div className="hidden overflow-x-auto rounded-xl border border-gray-200 md:block dark:border-gray-800">
        <table className="w-full text-sm" style={{ minWidth: anchoMin }}>
          <thead className="bg-gray-100 text-[11px] uppercase tracking-wide text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <tr>
              {cols.map((c, i) => (
                <th key={c.rotulo}
                  onClick={() => alternarOrden(c)}
                  title={c.orden ? 'Ordenar por ' + c.rotulo : undefined}
                  className={cn('px-3 py-2 select-none',
                    i === 0 ? cn('relative text-left', fijaCabeza, sombra) : 'text-right',
                    c.orden && 'cursor-pointer hover:text-gray-800 dark:hover:text-gray-200',
                    c.dorado && 'text-dfgroup-gold')}>
                  {c.rotulo}{flecha(c)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {visibles.map((f, i) => (
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
                    {c.total ? c.total(visibles) : ''}
                  </td>
                ))}
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      {/* ---- celular ---- */}
      <ul className="space-y-2 md:hidden">
        {visibles.map((f, i) => (
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
                {colTitulo.total ? colTitulo.total(visibles) : 'TOTAL'}
              </span>
              {colPrincipal?.total && (
                <span className="text-base font-bold tabular-nums text-gray-900 dark:text-white">
                  {colPrincipal.total(visibles)}
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
                    {c.total!(visibles)}
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
function Grilla({ filas, conPedidos, conNeta }: { filas: EstadisticaFila[]; conPedidos?: boolean; conNeta?: boolean }) {
  const cols: Col<EstadisticaFila>[] = [
    { rotulo: 'Detalle', orden: (f) => f.detalle, texto: true, valor: (f) => f.detalle, titulo: true, total: () => 'TOTAL' },
    { rotulo: 'Venta', orden: (f) => f.venta, valor: (f) => money(f.venta), principal: true,
      total: (fs) => money(sumar(fs, (f) => f.venta)) },
    { rotulo: '%', orden: (f) => f.porcentaje ?? 0, valor: (f) => pct(f.porcentaje), tenue: true,
      total: (fs) => pct(sumar(fs, (f) => f.porcentaje)) },
    // Solo en el corte por sucursal: Venta (lista, = Estadisticas de SmartFran)
    // menos Desc. plataformas da Venta neta (cobrado, = Cierres de Turno).
    ...(conNeta && filas.some((f) => f.venta_neta != null) ? [
      { rotulo: 'Desc. plataformas', orden: (f: EstadisticaFila) => f.desc_plataformas ?? 0,
        valor: (f: EstadisticaFila) => money(f.desc_plataformas),
        total: (fs: EstadisticaFila[]) => money(sumar(fs, (f) => f.desc_plataformas)) },
      ...(filas.some((f) => Math.abs(f.otros_ajustes ?? 0) >= 1) ? [
        { rotulo: 'Otros ajustes', orden: (f: EstadisticaFila) => f.otros_ajustes ?? 0,
          valor: (f: EstadisticaFila) => money(f.otros_ajustes), tenue: true,
          total: (fs: EstadisticaFila[]) => money(sumar(fs, (f) => f.otros_ajustes)) }] : []),
      { rotulo: 'Venta neta', orden: (f: EstadisticaFila) => f.venta_neta ?? 0,
        valor: (f: EstadisticaFila) => money(f.venta_neta), principal: true,
        total: (fs: EstadisticaFila[]) => money(sumar(fs, (f) => f.venta_neta)) },
    ] : []),
    ...(conPedidos ? [{ rotulo: 'Pedidos', orden: (f: EstadisticaFila) => f.pedidos ?? 0, valor: (f: EstadisticaFila) => num(f.pedidos),
      total: (fs: EstadisticaFila[]) => num(sumar(fs, (f) => f.pedidos)) }] : []),
    { rotulo: 'Cantidad', orden: (f) => f.cantidad, valor: (f) => num(f.cantidad),
      total: (fs) => num(sumar(fs, (f) => f.cantidad)) },
    { rotulo: '$ Dtos.', orden: (f) => f.descuentos ?? 0, valor: (f) => money(f.descuentos),
      total: (fs) => money(sumar(fs, (f) => f.descuentos)) },
    { rotulo: '# Promo', orden: (f) => f.promos ?? 0, valor: (f) => num(f.promos),
      total: (fs) => num(sumar(fs, (f) => f.promos)) },
    { rotulo: 'Kilos', orden: (f) => f.kilos ?? 0, valor: (f) => num(f.kilos, 2),
      total: (fs) => num(sumar(fs, (f) => f.kilos), 2) },
    { rotulo: 'Costo', orden: (f) => f.costo ?? 0, valor: (f) => money(f.costo),
      total: (fs) => money(sumar(fs, (f) => f.costo)) },
    { rotulo: 'Utilidad', orden: (f) => f.utilidad ?? 0, valor: (f) => money(f.utilidad),
      total: (fs) => money(sumar(fs, (f) => f.utilidad)) },
    // Recalculado sobre los totales, NO promediado: las sucursales pesan distinto.
    { rotulo: '% Util.', orden: (f) => f.pct_utilidad ?? 0, valor: (f) => pct(f.pct_utilidad), tenue: true,
      total: (fs) => pctSobre(sumar(fs, (f) => f.utilidad), sumar(fs, (f) => f.venta)) },
    { rotulo: 'C. Marginal', orden: (f) => f.contrib_marginal ?? 0, valor: (f) => money(f.contrib_marginal), dorado: true,
      total: (fs) => money(sumar(fs, (f) => f.contrib_marginal)) },
    { rotulo: '% CM', orden: (f) => f.pct_contrib ?? 0, valor: (f) => pct(f.pct_contrib), dorado: true, tenue: true,
      total: (fs) => pctSobre(sumar(fs, (f) => f.contrib_marginal), sumar(fs, (f) => f.venta)) },
  ]
  return <Tabla filas={filas} cols={cols} clave={(f, i) => f.detalle + i} />
}

/** Para promociones y sobreventas, que solo tienen venta y cantidad. */
function GrillaSimple({ filas }: { filas: EstadisticaFila[] }) {
  const cols: Col<EstadisticaFila>[] = [
    { rotulo: 'Detalle', orden: (f) => f.detalle, texto: true, valor: (f) => f.detalle, titulo: true, total: () => 'TOTAL' },
    { rotulo: 'Venta', orden: (f) => f.venta, valor: (f) => money(f.venta), principal: true,
      total: (fs) => money(sumar(fs, (f) => f.venta)) },
    { rotulo: '%', orden: (f) => f.porcentaje ?? 0, valor: (f) => pct(f.porcentaje), tenue: true,
      total: (fs) => pct(sumar(fs, (f) => f.porcentaje)) },
    { rotulo: 'Cantidad', orden: (f) => f.cantidad, valor: (f) => num(f.cantidad),
      total: (fs) => num(sumar(fs, (f) => f.cantidad)) },
  ]
  return <Tabla filas={filas} cols={cols} clave={(f, i) => f.detalle + i} anchoMin={480} />
}

function TablaHistoria({ filas }: { filas: EstadisticaDia[] }) {
  const cols: Col<EstadisticaDia>[] = [
    { rotulo: 'Dia', titulo: true,
      valor: (f) => `${f.dia.slice(8, 10)}/${f.dia.slice(5, 7)}/${f.dia.slice(0, 4)}`,
      total: (fs) => `TOTAL (${fs.length} dias)` },
    { rotulo: 'Venta', orden: (f) => f.venta, valor: (f) => money(f.venta), principal: true,
      total: (fs) => money(sumar(fs, (f) => f.venta)) },
    { rotulo: 'Tiquets', orden: (f) => f.tickets, valor: (f) => num(f.tickets),
      total: (fs) => num(sumar(fs, (f) => f.tickets)) },
    { rotulo: 'Kilos', orden: (f) => f.kilos ?? 0, valor: (f) => num(f.kilos, 2),
      total: (fs) => num(sumar(fs, (f) => f.kilos), 2) },
    { rotulo: 'Utilidad', orden: (f) => f.utilidad ?? 0, valor: (f) => money(f.utilidad),
      total: (fs) => money(sumar(fs, (f) => f.utilidad)) },
    { rotulo: 'C. Marginal', orden: (f) => f.contrib_marginal ?? 0, valor: (f) => money(f.contrib_marginal), dorado: true,
      total: (fs) => money(sumar(fs, (f) => f.contrib_marginal)) },
  ]
  return <Tabla filas={filas} cols={cols} clave={(f) => f.dia} anchoMin={560} />
}

/* ---------------------------------------------------------------------------
   Grafico con sus dos acciones: cambiar de forma y bajar el detalle.

   La forma se elige por grafico y no globalmente: una torta sirve para ver
   participacion entre pocas categorias y no sirve para 24 horas; una linea
   muestra evolucion pero no compara magnitudes. Quien mira sabe que pregunta
   se esta haciendo, asi que la eleccion es suya.

   La descarga sale en CSV con separador punto y coma y BOM: asi Excel en
   espanol lo abre en columnas de una, sin el asistente de importacion. Un
   .xlsx de verdad obligaria a sumar una libreria al bundle para un caso que
   el CSV resuelve.
   --------------------------------------------------------------------------- */
type TipoGrafico = 'torta' | 'barra' | 'barraH' | 'linea'

const TIPOS: { id: TipoGrafico; rotulo: string; icono: typeof PieChartIcon }[] = [
  { id: 'torta', rotulo: 'Torta', icono: PieChartIcon },
  { id: 'barra', rotulo: 'Barras', icono: BarChart3 },
  { id: 'barraH', rotulo: 'Barras horizontales', icono: AlignLeft },
  { id: 'linea', rotulo: 'Linea', icono: TrendingUp },
]

function descargarCSV(nombre: string, filas: Record<string, unknown>[]) {
  if (!filas.length) return
  const cols = Object.keys(filas[0])
  const celda = (v: unknown) => {
    if (v === null || v === undefined) return ''
    const s = String(v)
    // Decimales con coma, que es lo que espera Excel en espanol.
    if (typeof v === 'number') return s.replace('.', ',')
    return /[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  const csv = [cols.join(';'), ...filas.map((f) => cols.map((c) => celda(f[c])).join(';'))].join('\r\n')

  const url = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' }))
  const a = document.createElement('a')
  a.href = url
  a.download = `${nombre}_${new Date().toISOString().slice(0, 10)}.csv`
  a.click()
  URL.revokeObjectURL(url)
}

function Grafico({ titulo, datos, inicial = 'barra', color = '#C9A227', colorPorNombre, alto = 260, detalle }: {
  titulo: string
  datos: { name: string; value: number }[]
  inicial?: TipoGrafico
  color?: string
  colorPorNombre?: (n: string) => string | undefined
  alto?: number
  /** Filas que se bajan al exportar. Sin esto se baja lo que muestra el grafico. */
  detalle?: Record<string, unknown>[]
}) {
  const [tipo, setTipo] = useState<TipoGrafico>(inicial)
  const total = datos.reduce((a, d) => a + d.value, 0)
  const recortar = (s: string) => (s.length > 14 ? s.slice(0, 13) + '.' : s)

  const exportar = () =>
    descargarCSV(plano(titulo).replace(/[^a-z0-9]+/g, '_'),
      detalle ?? datos.map((d) => ({
        Detalle: d.name,
        Venta: Math.round(d.value),
        Participacion: total ? +((d.value / total) * 100).toFixed(2) : 0,
      })))

  return (
    <div className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
      <div className="mb-3 flex items-start justify-between gap-2">
        <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200">{titulo}</h3>
        <div className="flex flex-shrink-0 items-center gap-0.5">
          {TIPOS.map((t) => (
            <button key={t.id} type="button" onClick={() => setTipo(t.id)} title={t.rotulo}
              className={cn('rounded p-1 transition-colors',
                tipo === t.id
                  ? 'bg-dfgroup-gold/20 text-dfgroup-gold'
                  : 'text-gray-400 hover:bg-gray-100 hover:text-gray-600 dark:hover:bg-gray-800')}>
              <t.icono className="h-3.5 w-3.5" />
            </button>
          ))}
          <button type="button" onClick={exportar} title="Bajar el detalle en Excel"
            className="ml-1 rounded p-1 text-gray-400 transition-colors hover:bg-gray-100 hover:text-dfgroup-gold dark:hover:bg-gray-800">
            <Download className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      {!datos.length ? <Vacio /> : (
        <ResponsiveContainer width="100%" height={alto}>
          {tipo === 'torta' ? (
            <PieChart>
              <Pie data={datos} dataKey="value" nameKey="name" innerRadius="45%" outerRadius="72%"
                paddingAngle={2} labelLine={false}
                label={(e: { value?: number }) =>
                  total ? `${Math.round(((e.value ?? 0) / total) * 100)}%` : ''}>
                {datos.map((d, i) => (
                  <Cell key={d.name} fill={colorPorNombre?.(d.name) ?? PALETA[i % PALETA.length]} />
                ))}
              </Pie>
              <Legend verticalAlign="bottom" height={36} iconType="circle" iconSize={8}
                wrapperStyle={{ fontSize: 11 }} />
              <Tooltip formatter={(v: number) => money(v)} />
            </PieChart>
          ) : tipo === 'barraH' ? (
            <BarChart data={datos} layout="vertical" margin={{ left: 10, right: 20 }}>
              <CartesianGrid strokeDasharray="3 3" opacity={0.15} horizontal={false} />
              <XAxis type="number" tickFormatter={moneyCorto} tick={{ fontSize: 10 }} />
              <YAxis type="category" dataKey="name" width={110} tick={{ fontSize: 10 }}
                tickFormatter={recortar} />
              <Tooltip formatter={(v: number) => money(v)} cursor={{ fill: 'rgba(0,0,0,0.04)' }} />
              <Bar dataKey="value" name="Venta" fill={color} radius={[0, 4, 4, 0]} />
            </BarChart>
          ) : tipo === 'linea' ? (
            <AreaChart data={datos} margin={{ bottom: 40, left: -10 }}>
              <defs>
                <linearGradient id={`g${plano(titulo).replace(/\W/g, '')}`} x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor={color} stopOpacity={0.6} />
                  <stop offset="95%" stopColor={color} stopOpacity={0.05} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" opacity={0.15} />
              <XAxis dataKey="name" tick={{ fontSize: 10 }} angle={-40} textAnchor="end"
                interval={0} height={70} tickFormatter={recortar} />
              <YAxis tickFormatter={moneyCorto} tick={{ fontSize: 10 }} width={58} />
              <Tooltip formatter={(v: number) => money(v)} />
              <Area type="monotone" dataKey="value" name="Venta" stroke={color} strokeWidth={2}
                fill={`url(#g${plano(titulo).replace(/\W/g, '')})`} />
            </AreaChart>
          ) : (
            <BarChart data={datos} margin={{ bottom: 40, left: -10 }}>
              <CartesianGrid strokeDasharray="3 3" opacity={0.15} vertical={false} />
              <XAxis dataKey="name" tick={{ fontSize: 10 }} angle={-40} textAnchor="end"
                interval={0} height={70} tickFormatter={recortar} />
              <YAxis tickFormatter={moneyCorto} tick={{ fontSize: 10 }} width={58} />
              <Tooltip formatter={(v: number) => money(v)} cursor={{ fill: 'rgba(0,0,0,0.04)' }} />
              <Bar dataKey="value" name="Venta" fill={color} radius={[4, 4, 0, 0]} />
            </BarChart>
          )}
        </ResponsiveContainer>
      )}
    </div>
  )
}

/* Barras y Torta quedaron absorbidos por <Grafico>, que ademas permite
   cambiar de forma y exportar. Tener las dos cosas invitaba a que algunos
   graficos tuvieran esas acciones y otros no. */

/* ---------------------------------------------------------------------------
   Mapa de calor: hora contra dia de la semana.

   Las horas van en filas y los dias en columnas, y el orden arranca a las 6
   como en el grafico de barras: la madrugada es la cola del dia anterior, no
   la apertura del siguiente.

   La intensidad se calcula contra el MAXIMO de la grilla y no contra el
   total: lo que se busca leer es donde estan los picos relativos, y con el
   total como referencia todas las celdas quedarian casi blancas.
   --------------------------------------------------------------------------- */
const MEDIDAS = [
  { id: 'venta', rotulo: 'Ventas', fmt: (n: number) => money(n) },
  { id: 'kilos', rotulo: 'Kilos', fmt: (n: number) => num(n, 2) },
  { id: 'tickets', rotulo: 'Tickets', fmt: (n: number) => num(n) },
] as const

type MedidaId = (typeof MEDIDAS)[number]['id']

/** Un eje del mapa: la lista de filas o de columnas, con su rotulo. */
interface Eje { clave: number; rotulo: string }

/** Las tres vistas comparten grilla; solo cambian los ejes y de donde sale el dato. */
type VistaMapa = 'horaDia' | 'climaDia' | 'climaHora'

const VISTAS: { id: VistaMapa; rotulo: string }[] = [
  { id: 'horaDia', rotulo: 'Hora y dia' },
  { id: 'climaDia', rotulo: 'Clima por dia' },
  { id: 'climaHora', rotulo: 'Clima por hora' },
]

function PanelMapas({ datos }: { datos: EstadisticaVentasRespuesta }) {
  const [vista, setVista] = useState<VistaMapa>('horaDia')
  const [medida, setMedida] = useState<MedidaId>('venta')

  // Las horas arrancan a las 6: la madrugada es la cola del dia anterior.
  const horas = useMemo(() => Array.from({ length: 24 }, (_, i) => (i + 6) % 24), [])

  /* Las franjas de temperatura salen del dato y no de un rango fijo: en
     invierno no hay 34 grados y dibujar esas filas vacias solo aplasta la
     escala de color del resto. */
  const franjas = useMemo(() => {
    const fuente = vista === 'climaHora' ? datos.clima_hora : datos.clima_dia
    return Array.from(new Set(fuente.map((f) => f.franja))).sort((a, b) => b - a)
  }, [datos, vista])

  const config = useMemo(() => {
    if (vista === 'horaDia') {
      const m = new Map(datos.mapa_calor.map((f) => [`${f.hora}|${f.dia_semana}`, f]))
      return {
        filas: horas.map((h) => ({ clave: h, rotulo: `${h} hs` })) as Eje[],
        columnas: DIAS.map((d) => ({ clave: d.id, rotulo: d.corto })) as Eje[],
        rotuloFila: 'Hora',
        rotuloCol: 'Dia',
        valor: (f: number, c: number) => Number(m.get(`${f}|${c}`)?.[medida] ?? 0),
        nota: 'Participacion de cada hora a la derecha y de cada dia abajo. Las horas de 0 a 5 son la cola del dia anterior.',
        archivo: 'mapa_hora_dia',
        crudo: datos.mapa_calor.map((f) => ({
          Hora: dosDig(f.hora) + ':00', Dia: DIAS[f.dia_semana - 1]?.corto ?? f.dia_semana,
          Ventas: Math.round(f.venta), Kilos: +Number(f.kilos).toFixed(2), Tickets: f.tickets,
        })),
      }
    }
    if (vista === 'climaDia') {
      const m = new Map(datos.clima_dia.map((f) => [`${f.franja}|${f.dia_semana}`, f]))
      return {
        filas: franjas.map((t) => ({ clave: t, rotulo: `${t} a ${t + 1}°` })) as Eje[],
        columnas: DIAS.map((d) => ({ clave: d.id, rotulo: d.corto })) as Eje[],
        rotuloFila: 'Temp.',
        rotuloCol: 'Dia',
        valor: (f: number, c: number) => Number(m.get(`${f}|${c}`)?.[medida] ?? 0),
        nota: 'Temperatura en franjas de 2 grados. Solo entran las ventas que tienen clima registrado para esa hora y sucursal.',
        archivo: 'clima_por_dia',
        crudo: datos.clima_dia.map((f) => ({
          TemperaturaDesde: f.franja, TemperaturaHasta: f.franja + 2,
          Dia: DIAS[f.dia_semana - 1]?.corto ?? f.dia_semana,
          Ventas: Math.round(f.venta), Kilos: +Number(f.kilos).toFixed(2), Tickets: f.tickets,
        })),
      }
    }
    const m = new Map(datos.clima_hora.map((f) => [`${f.franja}|${f.hora}`, f]))
    return {
      filas: franjas.map((t) => ({ clave: t, rotulo: `${t} a ${t + 1}°` })) as Eje[],
      columnas: horas.map((h) => ({ clave: h, rotulo: String(h) })) as Eje[],
      rotuloFila: 'Temp.',
      rotuloCol: 'Hora',
      valor: (f: number, c: number) => Number(m.get(`${f}|${c}`)?.[medida] ?? 0),
      nota: 'Temperatura en franjas de 2 grados contra la hora del dia. Columnas de 6 a 5, que es como transcurre la jornada.',
      archivo: 'clima_por_hora',
      crudo: datos.clima_hora.map((f) => ({
        TemperaturaDesde: f.franja, TemperaturaHasta: f.franja + 2,
        Hora: dosDig(f.hora) + ':00',
        Ventas: Math.round(f.venta), Kilos: +Number(f.kilos).toFixed(2), Tickets: f.tickets,
      })),
    }
  }, [datos, vista, medida, horas, franjas])

  const hayClima = datos.clima_dia.length > 0
  if (!datos.mapa_calor.length) return null

  return (
    <div className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-2">
        <div className="flex flex-wrap gap-1">
          {VISTAS.map((v) => {
            const deshabilitada = v.id !== 'horaDia' && !hayClima
            return (
              <button key={v.id} type="button" disabled={deshabilitada}
                onClick={() => setVista(v.id)}
                title={deshabilitada ? 'No hay clima registrado para este periodo' : undefined}
                className={cn('rounded-md px-2.5 py-1 text-xs font-medium transition-colors',
                  vista === v.id
                    ? 'bg-dfgroup-gold/20 text-dfgroup-gold'
                    : 'text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-800',
                  deshabilitada && 'cursor-not-allowed opacity-40')}>
                {v.rotulo}
              </button>
            )
          })}
        </div>

        <div className="flex flex-shrink-0 items-center gap-1">
          {MEDIDAS.map((m) => (
            <button key={m.id} type="button" onClick={() => setMedida(m.id)}
              className={cn('rounded px-2 py-0.5 text-[11px] font-medium transition-colors',
                medida === m.id
                  ? 'bg-dfgroup-gold/20 text-dfgroup-gold'
                  : 'text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800')}>
              {m.rotulo}
            </button>
          ))}
          <button type="button" onClick={() => descargarCSV(config.archivo, config.crudo)}
            title="Bajar el detalle en Excel"
            className="ml-1 rounded p-1 text-gray-400 hover:bg-gray-100 hover:text-dfgroup-gold dark:hover:bg-gray-800">
            <Download className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      <p className="mb-3 text-[11px] leading-snug text-gray-400">
        Mas oscuro, mas {MEDIDAS.find((m) => m.id === medida)!.rotulo.toLowerCase()}. {config.nota}
      </p>

      <RejillaCalor filas={config.filas} columnas={config.columnas} valor={config.valor}
        medida={medida} rotuloFila={config.rotuloFila} rotuloCol={config.rotuloCol} />
    </div>
  )
}

/**
 * Que promocion rinde con que temperatura.
 *
 * Las promociones van en FILAS porque los nombres son largos y como
 * encabezado de columna no entran. La escala de color se calcula sobre toda
 * la matriz, asi que compara promos entre si: una fila entera clara es una
 * promo que vende poco en cualquier clima.
 */
function MapaPromoClima({ filas }: { filas: EstadisticaPromoClima[] }) {
  const [medida, setMedida] = useState<MedidaId>('venta')

  const { promos, franjas, valor } = useMemo(() => {
    const m = new Map(filas.map((f) => [`${f.promocion}|${f.franja}`, f]))

    // Se ordenan por venta total para que lo que mas pesa quede arriba.
    const totalPorPromo = new Map<number, { detalle: string; total: number }>()
    for (const f of filas) {
      const a = totalPorPromo.get(f.promocion) ?? { detalle: f.detalle, total: 0 }
      a.total += Number(f.venta)
      totalPorPromo.set(f.promocion, a)
    }
    const promos: Eje[] = [...totalPorPromo.entries()]
      .sort((a, b) => b[1].total - a[1].total)
      .map(([id, a]) => ({ clave: id, rotulo: a.detalle }))

    const franjas: Eje[] = Array.from(new Set(filas.map((f) => f.franja)))
      .sort((a, b) => a - b)
      .map((t) => ({ clave: t, rotulo: `${t}°` }))

    return {
      promos, franjas,
      valor: (p: number, t: number) => Number(m.get(`${p}|${t}`)?.[medida] ?? 0),
    }
  }, [filas, medida])

  if (!filas.length) return null

  return (
    <div className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
      <div className="mb-1 flex flex-wrap items-start justify-between gap-2">
        <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200">
          Que promocion funciona con cada temperatura
        </h3>
        <div className="flex flex-shrink-0 items-center gap-1">
          {MEDIDAS.map((m) => (
            <button key={m.id} type="button" onClick={() => setMedida(m.id)}
              className={cn('rounded px-2 py-0.5 text-[11px] font-medium transition-colors',
                medida === m.id
                  ? 'bg-dfgroup-gold/20 text-dfgroup-gold'
                  : 'text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800')}>
              {m.rotulo}
            </button>
          ))}
          <button type="button"
            onClick={() => descargarCSV('promociones_por_clima', filas.map((f) => ({
              Promocion: f.detalle,
              TemperaturaDesde: f.franja, TemperaturaHasta: f.franja + 2,
              Ventas: Math.round(f.venta), Kilos: +Number(f.kilos).toFixed(2), Tickets: f.tickets,
            })))}
            title="Bajar el detalle en Excel"
            className="ml-1 rounded p-1 text-gray-400 hover:bg-gray-100 hover:text-dfgroup-gold dark:hover:bg-gray-800">
            <Download className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>
      <p className="mb-3 text-[11px] leading-snug text-gray-400">
        Temperatura en franjas de 2 grados. Las 25 promociones de mayor venta del periodo,
        ordenadas de mayor a menor. Una fila entera clara es una promo que vende poco en
        cualquier clima.
      </p>

      <RejillaCalor filas={promos} columnas={franjas} valor={valor} medida={medida}
        rotuloFila="Promo" rotuloCol="Temp." anchoRotulo={190} />
    </div>
  )
}

function RejillaCalor({ filas, columnas, valor, medida, rotuloFila, rotuloCol, anchoRotulo = 64 }: {
  filas: Eje[]
  columnas: Eje[]
  valor: (fila: number, col: number) => number
  medida: MedidaId
  rotuloFila: string
  rotuloCol: string
  /** Ancho de la primera columna. Los nombres de promocion necesitan mas. */
  anchoRotulo?: number
}) {
  const { max, total, totalFila, totalCol } = useMemo(() => {
    let max = 0, total = 0
    const totalFila = new Map<number, number>()
    const totalCol = new Map<number, number>()
    for (const f of filas) {
      for (const c of columnas) {
        const v = valor(f.clave, c.clave)
        if (v > max) max = v
        total += v
        totalFila.set(f.clave, (totalFila.get(f.clave) ?? 0) + v)
        totalCol.set(c.clave, (totalCol.get(c.clave) ?? 0) + v)
      }
    }
    return { max, total, totalFila, totalCol }
  }, [filas, columnas, valor])

  if (!filas.length) {
    return <p className="py-6 text-center text-sm text-gray-400">No hay datos para esta vista.</p>
  }

  const fmt = MEDIDAS.find((m) => m.id === medida)!.fmt
  const pctDe = (n: number) => (total ? Math.round((n / total) * 100) + '%' : '')

  return (
    <div className="overflow-x-auto">
      <table className="w-full border-separate border-spacing-0.5 text-[11px]"
        style={{ minWidth: Math.max(620, anchoRotulo + 60 + columnas.length * 46) }}>
        <thead>
          <tr className="text-gray-400">
            <th style={{ width: anchoRotulo }} />
            {columnas.map((c) => <th key={c.clave} className="px-1 py-1 font-medium">{c.rotulo}</th>)}
            <th className="w-12 px-1 font-medium">{rotuloFila}</th>
          </tr>
        </thead>
        <tbody>
          {filas.map((f) => (
            <tr key={f.clave}>
              <td className="truncate pr-1 text-right text-gray-400" title={f.rotulo}
                style={{ maxWidth: anchoRotulo }}>{f.rotulo}</td>
              {columnas.map((c) => {
                const v = valor(f.clave, c.clave)
                const int = max ? v / max : 0
                return (
                  <td key={c.clave} title={`${f.rotulo} · ${c.rotulo}: ${fmt(v)}`}
                    className="rounded px-1 py-1 text-center tabular-nums"
                    style={{
                      backgroundColor: v ? `rgba(46, 111, 142, ${0.08 + int * 0.85})` : undefined,
                      color: int > 0.55 ? '#fff' : undefined,
                    }}>
                    {v ? (medida === 'venta' ? moneyCorto(v) : fmt(v)) : ''}
                  </td>
                )
              })}
              <td className="pl-1 text-right text-gray-400">{pctDe(totalFila.get(f.clave) ?? 0)}</td>
            </tr>
          ))}
          <tr className="font-medium text-gray-500">
            <td className="pr-1 text-right">{rotuloCol}</td>
            {columnas.map((c) => (
              <td key={c.clave} className="px-1 pt-1 text-center">{pctDe(totalCol.get(c.clave) ?? 0)}</td>
            ))}
            <td />
          </tr>
        </tbody>
      </table>
    </div>
  )
}

function Vacio() {
  return (
    <p className="py-8 text-center text-sm text-gray-400">
      No hay datos para los filtros elegidos.
    </p>
  )
}
