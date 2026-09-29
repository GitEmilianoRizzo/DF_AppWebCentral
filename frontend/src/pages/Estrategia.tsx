import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle, ArrowDownRight, ArrowRight, ArrowUpRight, Check, CheckCircle2,
  CloudRain, Flame, Gauge, HelpCircle, Loader2, Lock, Mail, MailCheck, Plus,
  RefreshCw, Send, Snowflake, Target, Thermometer, X,
} from 'lucide-react'
import {
  estrategiaApi,
  type AvisoResultado,
  type EstadoSugerencia,
  type Medicion,
  type MedicionDia,
  type MedicionSucursal,
  type MetricaObjetivo,
  type ObjetivoDetalle,
  type ObjetivoFila,
  type PronosticoDia,
  type Sugerencia,
} from '@/services/api'
import { cn } from '@/lib/utils'

/**
 * Estrategia.
 *
 * El resto de la app describe lo que paso. Esta pantalla es la primera que
 * propone que hacer.
 *
 * EL CIRCUITO
 * -----------
 *   1. Damian declara un objetivo: que metrica quiere mover y en que ventana.
 *   2. Fija una meta por sucursal, que no tiene por que ser la misma en todas.
 *   3. El motor cruza el pronostico con la elasticidad al clima medida sobre
 *      la huella y propone acciones, cada una con el numero que la respalda.
 *   4. Damian acepta o descarta. Lo que acepta se avisa a los responsables.
 *   5. El dato diario llega solo y se mide objetivo contra realidad.
 *
 * LA META VA EN PORCENTAJE, NO EN PESOS
 * -------------------------------------
 * "Vender diez millones" mide el verano, no la gestion: un enero flojo supera
 * a un julio excelente sin que nadie haya hecho nada distinto. La meta es un
 * porcentaje SOBRE LO ESPERADO para el clima de cada dia, que es lo unico que
 * queda cuando se saca el termometro de la ecuacion.
 *
 * NADA DE ESTO ES UN CUADRO FIJO
 * ------------------------------
 * El pronostico se vuelve a pedir cada vez que se abre un objetivo, y las
 * sugerencias se regeneran contra el pronostico del momento. Una tabla que
 * muestre el clima de anteayer no sirve para decidir nada.
 */

const SUCURSALES = [
  { id: 1, nombre: 'Lanus Oeste' },
  { id: 2, nombre: 'Escalada' },
  { id: 3, nombre: 'Fiorito' },
  { id: 4, nombre: 'Mayorista' },
]

const nombreSuc = (id: number | null) =>
  id === null ? 'Todas las sucursales' : SUCURSALES.find((s) => s.id === id)?.nombre ?? `Suc. ${id}`

const METRICAS: Array<{ id: MetricaObjetivo; rotulo: string; ayuda: string }> = [
  {
    id: 'FACTURACION',
    rotulo: 'Subir facturacion',
    ayuda: 'Mas pesos por la caja. Las sugerencias empujan trafico y ticket.',
  },
  {
    id: 'MARGEN',
    rotulo: 'Subir margen',
    ayuda: 'Mas utilidad, no mas venta. Se evita el descuento y se rota hacia lo que deja.',
  },
  {
    id: 'KILOS',
    rotulo: 'Liquidar kilos',
    ayuda: 'Sacar volumen. Aca si entra el descuento y la promo agresiva.',
  },
]

const DIAS_CORTO = ['', 'Lun', 'Mar', 'Mie', 'Jue', 'Vie', 'Sab', 'Dom']

const COLOR_TIPO: Record<string, string> = {
  OPERATIVO: 'bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300',
  PROMO: 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300',
  SOBREVENTA: 'bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300',
  MIX: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300',
}

/** "2026-09-28T00:00:00" -> "28/09" */
const diaCorto = (iso: string | null) => {
  if (!iso) return null
  const d = iso.slice(0, 10).split('-')
  return `${d[2]}/${d[1]}`
}

/** "2026-09-28T00:00:00" -> "28/09/2026" */
const fechaLarga = (iso: string | null) => {
  if (!iso) return '—'
  const d = iso.slice(0, 10).split('-')
  return `${d[2]}/${d[1]}/${d[0]}`
}

const fechaHora = (iso: string | null) => {
  if (!iso) return '—'
  return `${fechaLarga(iso)} ${iso.slice(11, 16)}`
}

/** Date -> "YYYY-MM-DD", que es lo que espera el backend. */
const aIso = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

const hoyMas = (dias: number) => {
  const d = new Date()
  d.setDate(d.getDate() + dias)
  return aIso(d)
}

// ===========================================================================
export function Estrategia() {
  const [objetivos, setObjetivos] = useState<ObjetivoFila[]>([])
  const [abierto, setAbierto] = useState<number | null>(null)
  const [detalle, setDetalle] = useState<ObjetivoDetalle | null>(null)

  const [cargandoLista, setCargandoLista] = useState(false)
  const [cargandoDetalle, setCargandoDetalle] = useState(false)
  const [regenerando, setRegenerando] = useState(false)
  const [avisando, setAvisando] = useState(false)
  const [aviso, setAviso] = useState<AvisoResultado | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [nuevo, setNuevo] = useState(false)

  const listar = useCallback(async () => {
    setCargandoLista(true)
    setError(null)
    try {
      const filas = await estrategiaApi.listarObjetivos({ top: 50 })
      setObjetivos(filas)
      // Al entrar se abre el objetivo vigente mas reciente: es lo que se esta
      // gestionando hoy, y arrancar en una lista vacia no dice nada.
      setAbierto((prev) => prev ?? filas.find((o) => o.estado === 'VIGENTE')?.objetivo_id ?? null)
    } catch (e) {
      setError('No se pudieron traer los objetivos: ' + (e instanceof Error ? e.message : 'error'))
    } finally {
      setCargandoLista(false)
    }
  }, [])

  useEffect(() => { void listar() }, [listar])

  useEffect(() => {
    // El resultado del ultimo envio pertenece al objetivo que se estaba
    // viendo: mostrarlo sobre otro seria decir que a este ya se le aviso.
    setAviso(null)
    if (abierto === null) { setDetalle(null); return }
    let vigente = true
    setCargandoDetalle(true)
    estrategiaApi.obtenerObjetivo(abierto)
      .then((d) => { if (vigente) setDetalle(d) })
      .catch((e) => { if (vigente) setError('No se pudo abrir el objetivo: ' + (e instanceof Error ? e.message : 'error')) })
      .finally(() => { if (vigente) setCargandoDetalle(false) })
    return () => { vigente = false }
  }, [abierto])

  /** Refresca el detalle y la fila del listado despues de una decision. */
  const refrescar = useCallback(async () => {
    if (abierto === null) return
    const d = await estrategiaApi.obtenerObjetivo(abierto)
    setDetalle(d)
    if (d.objetivo) {
      setObjetivos((prev) => prev.map((o) => (o.objetivo_id === d.objetivo!.objetivo_id ? d.objetivo! : o)))
    }
  }, [abierto])

  const decidir = async (sugerenciaId: number, estado: EstadoSugerencia, comentario?: string) => {
    // Se pinta la decision de entrada y despues se confirma contra el servidor:
    // esperar el ida y vuelta para ver un cambio de estado se siente roto.
    setDetalle((prev) => prev && {
      ...prev,
      sugerencias: prev.sugerencias.map((s) =>
        s.sugerencia_id === sugerenciaId ? { ...s, estado } : s),
    })
    try {
      await estrategiaApi.decidir(sugerenciaId, estado, comentario)
      await refrescar()
    } catch (e) {
      setError('No se pudo guardar la decision: ' + (e instanceof Error ? e.message : 'error'))
      await refrescar()
    }
  }

  const regenerar = async () => {
    if (abierto === null) return
    setRegenerando(true)
    setError(null)
    try {
      setDetalle(await estrategiaApi.regenerar(abierto))
      await listar()
    } catch (e) {
      setError('No se pudieron regenerar las sugerencias: ' + (e instanceof Error ? e.message : 'error'))
    } finally {
      setRegenerando(false)
    }
  }

  const avisar = async (prueba: boolean) => {
    if (abierto === null || !detalle?.objetivo) return

    const conMail = detalle.sucursales.filter((s) => s.mail?.trim()).length
    if (!prueba && !window.confirm(
      `Avisar a ${conMail} responsable(s) de "${detalle.objetivo.nombre}"?\n\n` +
      'Cada uno recibe solo las acciones aceptadas de su local mas las que aplican a todas.',
    )) return

    setAvisando(true)
    setError(null)
    setAviso(null)
    try {
      const r = await estrategiaApi.avisar(abierto, prueba)
      setAviso(r)
      if (r.objetivo) {
        setDetalle(r.objetivo)
        if (r.objetivo.objetivo) {
          const o = r.objetivo.objetivo
          setObjetivos((prev) => prev.map((x) => (x.objetivo_id === o.objetivo_id ? o : x)))
        }
      }
    } catch (e) {
      // El backend explica el motivo (falta configurar el correo, no hay nada
      // aceptado): se muestra tal cual en vez de un "fallo el envio" generico.
      const msg = (e as { response?: { data?: { error?: string } } })?.response?.data?.error
      setError(msg ?? 'No se pudo avisar: ' + (e instanceof Error ? e.message : 'error'))
    } finally {
      setAvisando(false)
    }
  }

  const cerrar = async () => {
    if (abierto === null || !detalle?.objetivo) return
    if (!window.confirm(
      `Cerrar "${detalle.objetivo.nombre}"?\n\n` +
      'Las sugerencias sin decidir quedan como vencidas y el objetivo deja de recibir sugerencias nuevas.',
    )) return
    try {
      await estrategiaApi.cerrar(abierto)
      await listar()
      await refrescar()
    } catch (e) {
      setError('No se pudo cerrar: ' + (e instanceof Error ? e.message : 'error'))
    }
  }

  return (
    <div className="space-y-5">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Estrategia</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Objetivo, sugerencias con evidencia y medicion contra lo esperado para el clima.
          </p>
        </div>
        <button
          onClick={() => setNuevo(true)}
          className="inline-flex items-center gap-2 rounded-md bg-dfgroup-gold px-3 py-2 text-sm font-medium text-white hover:brightness-95"
        >
          <Plus className="h-4 w-4" /> Nuevo objetivo
        </button>
      </header>

      {error && (
        <div className="flex items-start gap-2 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
          <AlertTriangle className="mt-0.5 h-4 w-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
          <button onClick={() => setError(null)} aria-label="Cerrar aviso">
            <X className="h-4 w-4" />
          </button>
        </div>
      )}

      <div className="grid gap-5 lg:grid-cols-[300px_minmax(0,1fr)]">
        {/* ------------------------------------------------ listado lateral */}
        <div className="space-y-2">
          <div className="flex items-center justify-between px-1">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500">
              Objetivos
            </h2>
            {cargandoLista && <Loader2 className="h-3.5 w-3.5 animate-spin text-gray-400" />}
          </div>

          {objetivos.length === 0 && !cargandoLista && (
            <p className="rounded-lg border border-dashed border-gray-300 p-4 text-sm text-gray-500 dark:border-gray-700">
              Todavia no hay ningun objetivo declarado.
            </p>
          )}

          {objetivos.map((o) => (
            <TarjetaObjetivo
              key={o.objetivo_id}
              objetivo={o}
              activo={o.objetivo_id === abierto}
              onClick={() => setAbierto(o.objetivo_id)}
            />
          ))}
        </div>

        {/* -------------------------------------------------------- detalle */}
        <div>
          {cargandoDetalle && !detalle && (
            <div className="flex items-center gap-2 p-8 text-sm text-gray-500">
              <Loader2 className="h-4 w-4 animate-spin" /> Abriendo el objetivo...
            </div>
          )}

          {detalle?.objetivo && (
            <PanelObjetivo
              detalle={detalle}
              regenerando={regenerando}
              avisando={avisando}
              aviso={aviso}
              onRegenerar={regenerar}
              onAvisar={avisar}
              onDescartarAviso={() => setAviso(null)}
              onCerrar={cerrar}
              onDecidir={decidir}
            />
          )}

          {!cargandoDetalle && !detalle && objetivos.length > 0 && (
            <p className="p-8 text-sm text-gray-500">Elegi un objetivo de la lista.</p>
          )}
        </div>
      </div>

      {nuevo && (
        <ModalNuevoObjetivo
          onCerrar={() => setNuevo(false)}
          onCreado={async (id) => {
            setNuevo(false)
            await listar()
            setAbierto(id)
          }}
        />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
function TarjetaObjetivo({
  objetivo, activo, onClick,
}: { objetivo: ObjetivoFila; activo: boolean; onClick: () => void }) {
  const cerrado = objetivo.estado === 'CERRADO'
  // Una ventana que ya vencio con el objetivo abierto no es lo mismo que una
  // en curso: es lo primero que hay que resolver.
  const vencido = !cerrado && objetivo.dias_restantes < 0

  return (
    <button
      onClick={onClick}
      className={cn(
        'w-full rounded-lg border p-3 text-left transition-colors',
        activo
          ? 'border-dfgroup-gold bg-amber-50 dark:bg-amber-950/30'
          : 'border-gray-200 bg-white hover:border-gray-300 dark:border-gray-700 dark:bg-gray-900',
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <span className={cn(
          'text-sm font-medium leading-tight',
          cerrado ? 'text-gray-500' : 'text-gray-900 dark:text-white',
        )}>
          {objetivo.nombre}
        </span>
        {cerrado && <Lock className="mt-0.5 h-3.5 w-3.5 flex-shrink-0 text-gray-400" />}
      </div>

      <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-[11px]">
        <span className="rounded bg-gray-100 px-1.5 py-0.5 font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-300">
          {METRICAS.find((m) => m.id === objetivo.metrica)?.rotulo ?? objetivo.metrica}
        </span>
        <span className="text-gray-500">
          {diaCorto(objetivo.fecha_desde)} a {diaCorto(objetivo.fecha_hasta)}
        </span>
      </div>

      <div className="mt-1.5 flex items-center gap-3 text-[11px] text-gray-500">
        <span>{objetivo.sucursales} suc.</span>
        {objetivo.pendientes > 0 ? (
          <span className="font-medium text-amber-700 dark:text-amber-400">
            {objetivo.pendientes} sin decidir
          </span>
        ) : (
          <span>{objetivo.sugerencias} sugerencias</span>
        )}
        {vencido && <span className="font-medium text-red-600">vencido</span>}
        {!vencido && !cerrado && <span>{objetivo.dias_restantes} d.</span>}
      </div>
    </button>
  )
}

// ---------------------------------------------------------------------------
function PanelObjetivo({
  detalle, regenerando, avisando, aviso,
  onRegenerar, onAvisar, onDescartarAviso, onCerrar, onDecidir,
}: {
  detalle: ObjetivoDetalle
  regenerando: boolean
  avisando: boolean
  aviso: AvisoResultado | null
  onRegenerar: () => void
  onAvisar: (prueba: boolean) => void
  onDescartarAviso: () => void
  onCerrar: () => void
  onDecidir: (id: number, estado: EstadoSugerencia, comentario?: string) => Promise<void>
}) {
  const o = detalle.objetivo!
  const cerrado = o.estado === 'CERRADO'
  const metrica = METRICAS.find((m) => m.id === o.metrica)

  const pendientes = detalle.sugerencias.filter((s) => s.estado === 'SUGERIDA')
  const decididas = detalle.sugerencias.filter((s) => s.estado !== 'SUGERIDA')

  const aceptadas = detalle.sugerencias.filter((s) => s.estado === 'ACEPTADA').length
  const sinMail = detalle.sucursales.filter((s) => !s.mail?.trim()).length
  // "Avisado" solo cuando todas las sucursales recibieron el suyo. Con una a
  // medias el boton tiene que seguir a la vista para poder reintentar.
  const faltaAvisar = detalle.sucursales.some((s) => !s.avisado_el)

  return (
    <div className="space-y-5">
      {/* ---------------------------------------------------- encabezado */}
      <div className="rounded-lg border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div className="flex items-center gap-2">
              <Target className="h-4 w-4 text-dfgroup-gold" />
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white">{o.nombre}</h2>
              {cerrado && (
                <span className="rounded bg-gray-200 px-1.5 py-0.5 text-[11px] font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-300">
                  cerrado
                </span>
              )}
            </div>
            <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
              {metrica?.rotulo} · del {fechaLarga(o.fecha_desde)} al {fechaLarga(o.fecha_hasta)}
              {!cerrado && o.dias_restantes >= 0 && ` · quedan ${o.dias_restantes} dias`}
              {!cerrado && o.dias_restantes < 0 && (
                <span className="font-medium text-red-600"> · la ventana ya vencio</span>
              )}
            </p>
            {metrica && <p className="mt-0.5 text-xs text-gray-500">{metrica.ayuda}</p>}
            {o.notas && (
              <p className="mt-2 border-l-2 border-gray-200 pl-2 text-xs italic text-gray-500 dark:border-gray-700">
                {o.notas}
              </p>
            )}
          </div>

          {!cerrado && (
            <div className="flex flex-wrap gap-2">
              {aceptadas > 0 && (
                <>
                  <button
                    onClick={() => onAvisar(true)}
                    disabled={avisando}
                    title="Manda el mail solo a la casilla de copia, sin avisarle a los locales. Sirve para ver como queda."
                    className="inline-flex items-center gap-1.5 rounded-md border border-gray-300 px-2.5 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
                  >
                    <Mail className="h-3.5 w-3.5" /> Prueba
                  </button>
                  <button
                    onClick={() => onAvisar(false)}
                    disabled={avisando}
                    className={cn(
                      'inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium disabled:opacity-50',
                      faltaAvisar
                        ? 'bg-dfgroup-gold text-white hover:brightness-95'
                        : 'border border-gray-300 text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800',
                    )}
                  >
                    {avisando
                      ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      : faltaAvisar ? <Send className="h-3.5 w-3.5" /> : <MailCheck className="h-3.5 w-3.5" />}
                    {faltaAvisar ? 'Avisar a los locales' : 'Volver a avisar'}
                  </button>
                </>
              )}
              <button
                onClick={onRegenerar}
                disabled={regenerando}
                title="Rehace las sugerencias sin decidir contra el pronostico de ahora. Las ya decididas no se tocan."
                className="inline-flex items-center gap-1.5 rounded-md border border-gray-300 px-2.5 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
              >
                {regenerando
                  ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  : <RefreshCw className="h-3.5 w-3.5" />}
                Regenerar
              </button>
              <button
                onClick={onCerrar}
                className="inline-flex items-center gap-1.5 rounded-md border border-gray-300 px-2.5 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
              >
                <Lock className="h-3.5 w-3.5" /> Cerrar
              </button>
            </div>
          )}
        </div>

        {/* metas por sucursal */}
        <div className="mt-4 flex flex-wrap gap-2 border-t border-gray-100 pt-3 dark:border-gray-800">
          {detalle.sucursales.map((s) => (
            <div
              key={s.sucursal}
              className="rounded-md border border-gray-200 px-2.5 py-1.5 dark:border-gray-700"
              title={[s.responsable, s.mail].filter(Boolean).join(' · ') || undefined}
            >
              <div className="text-[11px] text-gray-500">{nombreSuc(s.sucursal)}</div>
              <div className={cn(
                'text-sm font-semibold',
                s.meta_pct > 0 ? 'text-emerald-700 dark:text-emerald-400'
                  : s.meta_pct < 0 ? 'text-red-600'
                    : 'text-gray-500',
              )}>
                {s.meta_pct > 0 ? '+' : ''}{s.meta_pct.toLocaleString('es-AR', { maximumFractionDigits: 1 })}%
              </div>
              {/* Avisado, sin avisar, o sin mail cargado: son tres estados
                  distintos y el del medio es el unico accionable con el boton. */}
              {s.avisado_el ? (
                <div className="mt-0.5 flex items-center gap-1 text-[10px] text-emerald-700 dark:text-emerald-400">
                  <MailCheck className="h-3 w-3" /> {fechaHora(s.avisado_el).slice(0, 11)}
                </div>
              ) : !s.mail?.trim() ? (
                <div className="mt-0.5 text-[10px] text-amber-700 dark:text-amber-500">sin mail</div>
              ) : (
                <div className="mt-0.5 text-[10px] text-gray-400">sin avisar</div>
              )}
              {/* Si la meta queda por debajo del ruido del modelo, no se va a
                  poder verificar. Mejor saberlo mirando la meta que despues de
                  discutir el resultado. */}
              {s.ruido_ventana_pct !== null && s.meta_pct !== 0
                && Math.abs(s.meta_pct) < s.ruido_ventana_pct && (
                <div
                  className="mt-0.5 text-[10px] text-amber-700 dark:text-amber-500"
                  title={`El modelo se equivoca +-${s.ruido_ventana_pct.toFixed(1)}% en una ventana de este largo. Una meta menor no se distingue del ruido.`}
                >
                  bajo el ruido (±{s.ruido_ventana_pct.toFixed(0)}%)
                </div>
              )}
              {aceptadas > 0 && (
                <a
                  href={estrategiaApi.vistaPreviaUrl(o.objetivo_id, s.sucursal)}
                  target="_blank" rel="noreferrer"
                  className="mt-0.5 block text-[10px] text-gray-400 underline hover:text-gray-600 dark:hover:text-gray-300"
                >
                  ver mail
                </a>
              )}
            </div>
          ))}
          <p className="w-full pt-1 text-[11px] text-gray-400">
            Porcentaje sobre lo esperado para el clima de cada dia, no sobre el mes pasado.
            {sinMail > 0 && (
              <span className="text-amber-700 dark:text-amber-500">
                {' '}Hay {sinMail} sucursal(es) sin mail cargado: no van a recibir el aviso.
              </span>
            )}
          </p>
        </div>
      </div>

      {aviso && <ResultadoAviso aviso={aviso} onCerrar={onDescartarAviso} />}

      {/* La medicion va ARRIBA de las sugerencias: cuando el objetivo ya
          arranco, lo primero que se quiere saber es como viene, no que se
          habia propuesto. */}
      <PanelMedicion objetivoId={o.objetivo_id} metrica={o.metrica} />

      {/* ------------------------------------------------------ pronostico */}
      <TiraPronostico desde={o.fecha_desde} hasta={o.fecha_hasta} />

      {/* ----------------------------------------------------- sugerencias */}
      <div>
        <div className="mb-2 flex items-center justify-between">
          <h3 className="text-sm font-semibold text-gray-900 dark:text-white">
            Por decidir
            {pendientes.length > 0 && (
              <span className="ml-1.5 rounded-full bg-amber-100 px-2 py-0.5 text-[11px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                {pendientes.length}
              </span>
            )}
          </h3>
        </div>

        {pendientes.length === 0 ? (
          <p className="rounded-lg border border-dashed border-gray-300 p-4 text-sm text-gray-500 dark:border-gray-700">
            {detalle.sugerencias.length === 0
              ? 'No hay sugerencias todavia. Si el pronostico esta al dia, probá regenerar.'
              : 'Todo decidido.'}
          </p>
        ) : (
          <div className="space-y-2">
            {pendientes.map((s) => (
              <TarjetaSugerencia key={s.sugerencia_id} sugerencia={s} bloqueado={cerrado} onDecidir={onDecidir} />
            ))}
          </div>
        )}
      </div>

      {decididas.length > 0 && (
        <div>
          <h3 className="mb-2 text-sm font-semibold text-gray-900 dark:text-white">
            Ya decididas <span className="font-normal text-gray-500">({decididas.length})</span>
          </h3>
          <div className="space-y-2">
            {decididas.map((s) => (
              <TarjetaSugerencia key={s.sugerencia_id} sugerencia={s} bloqueado={cerrado} onDecidir={onDecidir} />
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
/**
 * Objetivo contra realidad.
 *
 * EL DESVIO NUNCA SE MUESTRA SOLO
 * -------------------------------
 * Al lado va siempre el ruido del modelo. Un +8% sobre un modelo que se
 * equivoca +-10% no es un logro: es un empate que todavia no se puede leer. Sin
 * ese numero, cualquiera festejaria una semana que en realidad no dijo nada, y
 * la primera vez que eso pase la herramienta se quema.
 *
 * "Sin datos todavia" no es un error: un objetivo que arranca manana no tiene
 * nada que medir, y decirlo es mas util que una tabla en cero.
 */
function PanelMedicion({ objetivoId, metrica }: { objetivoId: number; metrica: MetricaObjetivo }) {
  const [med, setMed] = useState<Medicion | null>(null)
  const [cargando, setCargando] = useState(false)
  const [recalculando, setRecalculando] = useState(false)
  const [verDias, setVerDias] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let vigente = true
    setCargando(true)
    setMed(null)
    estrategiaApi.medicion(objetivoId)
      .then((m) => { if (vigente) setMed(m) })
      .catch(() => { if (vigente) setError('No se pudo traer la medicion.') })
      .finally(() => { if (vigente) setCargando(false) })
    return () => { vigente = false }
  }, [objetivoId])

  const recalcular = async () => {
    setRecalculando(true)
    setError(null)
    try {
      setMed(await estrategiaApi.recalcularMedicion(objetivoId))
    } catch (e) {
      setError('No se pudo recalcular: ' + (e instanceof Error ? e.message : 'error'))
    } finally {
      setRecalculando(false)
    }
  }

  const hay = (med?.sucursales.length ?? 0) > 0
  const unidad = metrica === 'KILOS' ? 'kg' : '$'

  return (
    <div className="rounded-lg border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-white">
          <Gauge className="h-4 w-4 text-gray-400" />
          Objetivo contra realidad
          {cargando && <Loader2 className="h-3.5 w-3.5 animate-spin text-gray-400" />}
        </h3>
        <div className="flex items-center gap-2">
          {hay && (
            <button
              onClick={() => setVerDias((v) => !v)}
              className="text-[11px] text-gray-500 underline hover:text-gray-700 dark:hover:text-gray-300"
            >
              {verDias ? 'ocultar el detalle diario' : 'ver dia por dia'}
            </button>
          )}
          <button
            onClick={() => void recalcular()}
            disabled={recalculando}
            title="La medicion la deja hecha la tarea de las 12:30. Esto sirve para un objetivo sobre un periodo ya pasado."
            className="inline-flex items-center gap-1.5 rounded-md border border-gray-300 px-2.5 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
          >
            {recalculando
              ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
              : <RefreshCw className="h-3.5 w-3.5" />}
            Recalcular
          </button>
        </div>
      </div>

      {error && <p className="mb-2 text-sm text-red-600">{error}</p>}

      {!hay && !cargando ? (
        <p className="text-sm text-gray-500">
          Todavia no hay dias medidos. La venta de cada jornada entra al otro dia
          a las 12:30 y la medicion aparece sola. Si el objetivo es sobre un
          periodo ya pasado, toca Recalcular.
        </p>
      ) : (
        <>
          <div className="grid gap-2 sm:grid-cols-2">
            {med?.sucursales.map((s) => <TarjetaMedicion key={s.sucursal} m={s} unidad={unidad} />)}
          </div>

          {verDias && med && <TablaDias dias={med.dias} unidad={unidad} />}
        </>
      )}
    </div>
  )
}

const miles = (n: number | null | undefined, unidad: string) => {
  if (n === null || n === undefined) return '—'
  const abs = Math.abs(n)
  if (unidad === 'kg') return Math.round(n).toLocaleString('es-AR') + ' kg'
  if (abs >= 1e6) return '$' + (n / 1e6).toFixed(1) + 'M'
  if (abs >= 1e3) return '$' + Math.round(n / 1e3).toLocaleString('es-AR') + 'k'
  return '$' + Math.round(n)
}

const conSigno = (n: number | null | undefined, d = 1) =>
  n === null || n === undefined
    ? '—'
    : (n > 0 ? '+' : '') + n.toLocaleString('es-AR', { minimumFractionDigits: d, maximumFractionDigits: d }) + '%'

function TarjetaMedicion({ m, unidad }: { m: MedicionSucursal; unidad: string }) {
  // Tres estados, no dos. El tercero es el honesto cuando el numero no alcanza.
  const estado = !m.concluyente ? 'indefinido' : m.cumple ? 'cumple' : 'falla'

  return (
    <div className={cn(
      'rounded-md border p-3',
      estado === 'cumple' ? 'border-emerald-300 bg-emerald-50/50 dark:border-emerald-800 dark:bg-emerald-950/20'
        : estado === 'falla' ? 'border-red-300 bg-red-50/50 dark:border-red-900 dark:bg-red-950/20'
          : 'border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800/40',
    )}>
      <div className="flex items-start justify-between gap-2">
        <div>
          <div className="text-sm font-medium text-gray-900 dark:text-white">{nombreSuc(m.sucursal)}</div>
          <div className="text-[11px] text-gray-500">
            {m.dias} dia{m.dias === 1 ? '' : 's'} medido{m.dias === 1 ? '' : 's'}
            {' · meta '}{conSigno(m.meta_pct, 0)}
          </div>
        </div>
        <div className="text-right">
          <div className={cn(
            'text-xl font-semibold leading-none',
            estado === 'cumple' ? 'text-emerald-700 dark:text-emerald-400'
              : estado === 'falla' ? 'text-red-600'
                : 'text-gray-500',
          )}>
            {conSigno(m.desvio_pct)}
          </div>
          <div className="mt-0.5 text-[10px] text-gray-500">sobre lo esperado</div>
        </div>
      </div>

      <div className="mt-2 flex items-center justify-between border-t border-gray-200/70 pt-2 text-[11px] text-gray-600 dark:border-gray-700 dark:text-gray-400">
        <span>esperado {miles(m.esperado, unidad)}</span>
        <span>real {miles(m.real, unidad)}</span>
      </div>

      {/* El ruido. Es lo que separa "cumplio" de "no se sabe". */}
      <div className="mt-1.5 flex items-start gap-1 text-[11px]">
        {estado === 'indefinido' ? (
          <>
            <HelpCircle className="mt-0.5 h-3 w-3 flex-shrink-0 text-gray-400" />
            <span className="text-gray-500">
              No concluyente: el modelo se equivoca +-{m.ruido_ventana_pct?.toFixed(1)}% en una
              ventana de este largo, asi que un {conSigno(m.desvio_pct)} no se distingue del ruido.
              {m.meta_pct !== 0 && m.ruido_ventana_pct !== null && m.meta_pct < m.ruido_ventana_pct && (
                <> Para verificar una meta de {conSigno(m.meta_pct, 0)} hace falta una ventana mas larga.</>
              )}
            </span>
          </>
        ) : (
          <span className="text-gray-500">
            Ruido del modelo en esta ventana: +-{m.ruido_ventana_pct?.toFixed(1)}%.
            El desvio lo supera, asi que el resultado se sostiene.
          </span>
        )}
      </div>
    </div>
  )
}

function TablaDias({ dias, unidad }: { dias: MedicionDia[]; unidad: string }) {
  return (
    <div className="mt-3 overflow-x-auto">
      <table className="w-full min-w-[640px] text-xs">
        <thead>
          <tr className="border-b border-gray-200 text-left text-gray-500 dark:border-gray-700">
            <th className="py-1.5 pr-3 font-medium">Dia</th>
            <th className="py-1.5 pr-3 font-medium">Sucursal</th>
            <th className="py-1.5 pr-3 font-medium">Clima</th>
            <th className="py-1.5 pr-3 text-right font-medium">Esperado</th>
            <th className="py-1.5 pr-3 text-right font-medium">Real</th>
            <th className="py-1.5 pr-3 text-right font-medium">Desvio</th>
            <th className="py-1.5 font-medium">Con que se estimo</th>
          </tr>
        </thead>
        <tbody>
          {dias.map((d) => {
            const salto = d.tmax !== null && d.tmax_ayer !== null ? d.tmax - d.tmax_ayer : null
            return (
              <tr key={`${d.sucursal}-${d.fecha}`} className="border-b border-gray-100 dark:border-gray-800">
                <td className="py-1.5 pr-3 whitespace-nowrap">
                  {DIAS_CORTO[((new Date(d.fecha.slice(0, 10) + 'T12:00:00').getDay() + 6) % 7) + 1]}{' '}
                  {diaCorto(d.fecha)}
                </td>
                <td className="py-1.5 pr-3 whitespace-nowrap">{nombreSuc(d.sucursal)}</td>
                <td className="py-1.5 pr-3 whitespace-nowrap text-gray-600 dark:text-gray-400">
                  {d.tmax === null ? '—' : `${Math.round(d.tmax)}°`}
                  {salto !== null && (
                    <span className={cn(
                      'ml-1',
                      salto >= 2 ? 'text-orange-500' : salto <= -2 ? 'text-sky-500' : 'text-gray-400',
                    )}>
                      ({salto > 0 ? '+' : ''}{salto.toFixed(0)})
                    </span>
                  )}
                  {d.llovio && (
                    <span
                      className={cn(
                        'ml-1 inline-flex items-center gap-0.5',
                        (d.expos_lluvia ?? 0) >= 25 ? 'font-medium text-blue-700 dark:text-blue-300' : 'text-blue-500',
                      )}
                      title={
                        d.expos_lluvia === null || d.expos_lluvia === undefined
                          ? 'Llovio'
                          : `Llovio sobre el ${Math.round(d.expos_lluvia)}% de la venta del dia`
                      }
                    >
                      <CloudRain className="h-3 w-3" />
                      {d.expos_lluvia !== null && d.expos_lluvia !== undefined
                        && `${Math.round(d.expos_lluvia)}%`}
                    </span>
                  )}
                </td>
                <td className="py-1.5 pr-3 text-right tabular-nums">{miles(d.esperado, unidad)}</td>
                <td className="py-1.5 pr-3 text-right tabular-nums">{miles(d.real, unidad)}</td>
                <td className={cn(
                  'py-1.5 pr-3 text-right tabular-nums font-medium',
                  d.desvio_pct === null ? 'text-gray-400'
                    : d.desvio_pct > 0 ? 'text-emerald-700 dark:text-emerald-400'
                      : 'text-red-600',
                )}>
                  {conSigno(d.desvio_pct)}
                </td>
                <td className="py-1.5 text-gray-500">{d.nivel_modelo ?? '—'}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
      <p className="mt-2 text-[11px] text-gray-400">
        Un dia suelto se desvia facil +-20% por puro azar. El numero que vale es el
        acumulado de arriba; esta tabla sirve para entender POR QUE, no para juzgar un dia.
      </p>
    </div>
  )
}

// ---------------------------------------------------------------------------
/**
 * Como le fue al envio, sucursal por sucursal.
 *
 * Se muestra el detalle entero y no un "listo": una sucursal sin mail cargado
 * o un rebote son cosas que hay que poder ver en el momento, porque el local
 * que no recibio el aviso no va a reclamar por algo que no sabe que existe.
 */
function ResultadoAviso({ aviso, onCerrar }: { aviso: AvisoResultado; onCerrar: () => void }) {
  const todoBien = aviso.omitidos === 0

  return (
    <div className={cn(
      'rounded-lg border p-3 text-sm',
      todoBien
        ? 'border-emerald-300 bg-emerald-50 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950/30 dark:text-emerald-200'
        : 'border-amber-300 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-200',
    )}>
      <div className="flex items-start gap-2">
        {todoBien
          ? <MailCheck className="mt-0.5 h-4 w-4 flex-shrink-0" />
          : <AlertTriangle className="mt-0.5 h-4 w-4 flex-shrink-0" />}
        <div className="flex-1">
          <p className="font-medium">
            {aviso.enviados} enviado{aviso.enviados === 1 ? '' : 's'}
            {aviso.omitidos > 0 && `, ${aviso.omitidos} sin enviar`}
          </p>
          <ul className="mt-1.5 space-y-0.5 text-xs">
            {aviso.detalle.map((d) => (
              <li key={d.sucursal} className="flex flex-wrap items-center gap-1.5">
                {d.enviado
                  ? <Check className="h-3 w-3 text-emerald-600" />
                  : <X className="h-3 w-3 text-amber-600" />}
                <span className="font-medium">{d.nombre}</span>
                {d.enviado
                  ? <span className="opacity-80">{d.mail} · {d.acciones} accion{d.acciones === 1 ? '' : 'es'}</span>
                  : <span className="opacity-80">{d.motivo}</span>}
              </li>
            ))}
          </ul>
        </div>
        <button onClick={onCerrar} aria-label="Cerrar">
          <X className="h-4 w-4" />
        </button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
/**
 * El pronostico de la ventana, pedido en vivo.
 *
 * Va al lado de las sugerencias a proposito: si el clima que se ve aca no se
 * parece al que dice la sugerencia, la sugerencia esta vieja y hay que
 * regenerar. Sin esto habria que creerle al motor sin poder chequearlo.
 */
function TiraPronostico({ desde, hasta }: { desde: string; hasta: string }) {
  const [suc, setSuc] = useState(1)
  const [dias, setDias] = useState<PronosticoDia[]>([])
  const [cargando, setCargando] = useState(false)

  useEffect(() => {
    let vigente = true
    setCargando(true)
    // 16 es el tope de Open-Meteo. Se pide todo y se recorta a la ventana:
    // un objetivo que arranca dentro de dos semanas igual muestra algo.
    estrategiaApi.pronostico({ sucursal: suc, dias: 16 })
      .then((d) => { if (vigente) setDias(d) })
      .catch(() => { if (vigente) setDias([]) })
      .finally(() => { if (vigente) setCargando(false) })
    return () => { vigente = false }
  }, [suc])

  const delTramo = useMemo(() => {
    const d0 = desde.slice(0, 10)
    const d1 = hasta.slice(0, 10)
    return dias.filter((d) => d.dia.slice(0, 10) >= d0 && d.dia.slice(0, 10) <= d1)
  }, [dias, desde, hasta])

  return (
    <div className="rounded-lg border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-white">
          <Thermometer className="h-4 w-4 text-gray-400" />
          Pronostico de la ventana
          {cargando && <Loader2 className="h-3.5 w-3.5 animate-spin text-gray-400" />}
        </h3>
        <select
          value={suc}
          onChange={(e) => setSuc(Number(e.target.value))}
          className="rounded-md border border-gray-300 bg-white px-2 py-1 text-xs dark:border-gray-700 dark:bg-gray-900 dark:text-white"
        >
          {SUCURSALES.map((s) => <option key={s.id} value={s.id}>{s.nombre}</option>)}
        </select>
      </div>

      {delTramo.length === 0 ? (
        <p className="text-sm text-gray-500">
          {cargando
            ? 'Trayendo el pronostico...'
            : 'No hay pronostico para esta ventana. Se carga todos los dias a las 12:30 y llega hasta 16 dias.'}
        </p>
      ) : (
        <div className="flex gap-2 overflow-x-auto pb-1">
          {delTramo.map((d) => <CeldaDia key={d.dia} dia={d} />)}
        </div>
      )}
    </div>
  )
}

function CeldaDia({ dia }: { dia: PronosticoDia }) {
  const salto = dia.tmax !== null && dia.tmax_ayer !== null ? dia.tmax - dia.tmax_ayer : null

  // Los cortes son los mismos con los que se calibro el ajuste por salto
  // termico: 2 y 5 grados. Cambiarlos aca haria que la pantalla muestre
  // tramos que el modelo no usa.
  const Icono = salto === null ? ArrowRight
    : salto >= 2 ? ArrowUpRight
      : salto <= -2 ? ArrowDownRight
        : ArrowRight
  const colorSalto = salto === null ? 'text-gray-400'
    : salto >= 5 ? 'text-red-600'
      : salto >= 2 ? 'text-orange-500'
        : salto <= -5 ? 'text-blue-600'
          : salto <= -2 ? 'text-sky-500'
            : 'text-gray-400'

  return (
    <div className="min-w-[92px] flex-1 rounded-md border border-gray-200 p-2 text-center dark:border-gray-700">
      <div className="text-[11px] font-medium text-gray-500">
        {DIAS_CORTO[dia.dia_semana]} {diaCorto(dia.dia)}
      </div>

      <div className="mt-1 flex items-center justify-center gap-1">
        {dia.tmax !== null && dia.tmax >= 28
          ? <Flame className="h-3.5 w-3.5 text-red-500" />
          : dia.tmax !== null && dia.tmax <= 14
            ? <Snowflake className="h-3.5 w-3.5 text-sky-500" />
            : null}
        <span className="text-base font-semibold text-gray-900 dark:text-white">
          {dia.tmax === null ? '—' : `${Math.round(dia.tmax)}°`}
        </span>
        <span className="text-[11px] text-gray-400">
          {dia.tmin === null ? '' : `/${Math.round(dia.tmin)}°`}
        </span>
      </div>

      <div className={cn('mt-0.5 flex items-center justify-center gap-0.5 text-[11px]', colorSalto)}>
        <Icono className="h-3 w-3" />
        {salto === null ? 's/d' : `${salto > 0 ? '+' : ''}${salto.toFixed(1)}°`}
      </div>

      {/* Lo que se muestra es la EXPOSICION, no las horas de lluvia. Once
          horas de madrugada valen 4% y no mueven la aguja; tres encima de la
          tarde valen 38% y cuestan un 22%. Mostrar las horas invitaria a
          preocuparse por el dia equivocado. */}
      {dia.llueve === 1 && (
        <div className={cn(
          'mt-1 flex items-center justify-center gap-0.5 text-[11px]',
          (dia.tramo_lluvia ?? 0) >= 3 ? 'font-medium text-blue-700 dark:text-blue-300'
            : (dia.tramo_lluvia ?? 0) === 2 ? 'text-blue-600 dark:text-blue-400'
              : 'text-gray-400',
        )}
          title={
            dia.exposicion === null
              ? `${dia.horas_lluvia} horas de lluvia`
              : `Llueve sobre el ${Math.round(dia.exposicion)}% de la venta del dia `
                + `(${dia.horas_lluvia} h en total)`
                + (dia.impacto_pct ? `. Historicamente eso cuesta ${dia.impacto_pct}% contra un dia seco.` : '')
          }
        >
          <CloudRain className="h-3 w-3" />
          {dia.exposicion === null ? `${dia.horas_lluvia}h` : `${Math.round(dia.exposicion)}%`}
        </div>
      )}
      {/* El costo esperado, solo cuando de verdad lo hay. */}
      {(dia.tramo_lluvia ?? 0) >= 2 && dia.impacto_pct !== null && (
        <div className="text-[10px] font-medium text-blue-700 dark:text-blue-300">
          {Math.round(dia.impacto_pct)}%
        </div>
      )}

      {/* A mas anticipacion, menos confiable. Se dice, no se esconde. */}
      <div className="mt-1 text-[10px] text-gray-400">
        {dia.anticipacion === 0 ? 'hoy' : `+${dia.anticipacion}d`}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
function TarjetaSugerencia({
  sugerencia: s, bloqueado, onDecidir,
}: {
  sugerencia: Sugerencia
  bloqueado: boolean
  onDecidir: (id: number, estado: EstadoSugerencia, comentario?: string) => Promise<void>
}) {
  const [comentario, setComentario] = useState('')
  const [guardando, setGuardando] = useState(false)

  const pendiente = s.estado === 'SUGERIDA'

  const decidir = async (estado: EstadoSugerencia) => {
    setGuardando(true)
    try {
      await onDecidir(s.sugerencia_id, estado, comentario.trim() || undefined)
      setComentario('')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <div className={cn(
      'rounded-lg border p-3',
      s.estado === 'ACEPTADA' ? 'border-emerald-300 bg-emerald-50/50 dark:border-emerald-800 dark:bg-emerald-950/20'
        : s.estado === 'DESCARTADA' ? 'border-gray-200 bg-gray-50 opacity-70 dark:border-gray-800 dark:bg-gray-900'
          : s.estado === 'VENCIDA' ? 'border-gray-200 bg-gray-50 opacity-60 dark:border-gray-800 dark:bg-gray-900'
            : 'border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900',
    )}>
      <div className="flex flex-wrap items-center gap-1.5">
        <span className={cn('rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide', COLOR_TIPO[s.tipo])}>
          {s.tipo}
        </span>
        {s.fecha && (
          <span className="rounded bg-gray-100 px-1.5 py-0.5 text-[11px] font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-300">
            {diaCorto(s.fecha)}
          </span>
        )}
        <span className="text-[11px] text-gray-500">{nombreSuc(s.sucursal)}</span>
        {s.estado === 'ACEPTADA' && (
          <span className="ml-auto flex items-center gap-1 text-[11px] font-medium text-emerald-700 dark:text-emerald-400">
            <CheckCircle2 className="h-3.5 w-3.5" /> aceptada
          </span>
        )}
        {s.estado === 'DESCARTADA' && (
          <span className="ml-auto text-[11px] font-medium text-gray-500">descartada</span>
        )}
        {s.estado === 'VENCIDA' && (
          <span className="ml-auto text-[11px] font-medium text-gray-500">vencida sin decidir</span>
        )}
      </div>

      <p className="mt-1.5 text-sm font-medium text-gray-900 dark:text-white">{s.titulo}</p>
      {s.detalle && <p className="mt-0.5 text-sm text-gray-600 dark:text-gray-400">{s.detalle}</p>}

      {/* La evidencia va SIEMPRE visible, no escondida en un despliegue: una
          sugerencia sin el numero que la respalda es una corazonada. */}
      {s.evidencia && (
        <p className="mt-2 border-l-2 border-gray-300 pl-2 text-xs text-gray-500 dark:border-gray-700">
          {s.evidencia}
        </p>
      )}

      {pendiente && !bloqueado && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <input
            type="text"
            value={comentario}
            onChange={(e) => setComentario(e.target.value)}
            placeholder="Comentario (opcional)"
            className="min-w-[180px] flex-1 rounded-md border border-gray-300 bg-white px-2 py-1.5 text-xs dark:border-gray-700 dark:bg-gray-900 dark:text-white"
          />
          <button
            onClick={() => void decidir('ACEPTADA')}
            disabled={guardando}
            className="inline-flex items-center gap-1 rounded-md bg-emerald-600 px-2.5 py-1.5 text-xs font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            <Check className="h-3.5 w-3.5" /> Aceptar
          </button>
          <button
            onClick={() => void decidir('DESCARTADA')}
            disabled={guardando}
            className="inline-flex items-center gap-1 rounded-md border border-gray-300 px-2.5 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
          >
            <X className="h-3.5 w-3.5" /> Descartar
          </button>
        </div>
      )}

      {!pendiente && (
        <div className="mt-2 flex flex-wrap items-center gap-2 text-[11px] text-gray-500">
          {s.decidido_el && (
            <span>{s.decidido_por ?? 'alguien'} · {fechaHora(s.decidido_el)}</span>
          )}
          {s.comentario && <span className="italic">“{s.comentario}”</span>}
          {!bloqueado && s.estado !== 'VENCIDA' && (
            <button
              onClick={() => void decidir('SUGERIDA')}
              className="ml-auto underline hover:text-gray-700 dark:hover:text-gray-300"
            >
              reabrir
            </button>
          )}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
function ModalNuevoObjetivo({
  onCerrar, onCreado,
}: { onCerrar: () => void; onCreado: (id: number) => void | Promise<void> }) {
  const [nombre, setNombre] = useState('')
  const [metrica, setMetrica] = useState<MetricaObjetivo>('FACTURACION')
  // Arranca en la semana que viene: es la ventana que de verdad se puede
  // gestionar. Sobre el dia de hoy ya no hay nada que decidir.
  const [desde, setDesde] = useState(hoyMas(1))
  const [hasta, setHasta] = useState(hoyMas(7))
  const [notas, setNotas] = useState('')
  const [metas, setMetas] = useState<Record<number, { incluida: boolean; meta: string; responsable: string; mail: string }>>(
    Object.fromEntries(SUCURSALES.map((s) => [s.id, { incluida: true, meta: '3', responsable: '', mail: '' }])),
  )
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === 'Escape') onCerrar() }
    window.addEventListener('keydown', h)
    return () => window.removeEventListener('keydown', h)
  }, [onCerrar])

  const elegidas = SUCURSALES.filter((s) => metas[s.id].incluida)

  const largoVentana = useMemo(() => {
    const d0 = new Date(desde + 'T12:00:00')
    const d1 = new Date(hasta + 'T12:00:00')
    if (isNaN(d0.getTime()) || isNaN(d1.getTime())) return 0
    return Math.round((d1.getTime() - d0.getTime()) / 86400000) + 1
  }, [desde, hasta])

  /**
   * Estimacion del ruido del modelo para esta ventana.
   *
   * El error tipico de UN dia, medido sobre la historia de 2024 a hoy, es de
   * alrededor del 20% en los tres locales de mostrador. Acumulado sobre N dias
   * los dias buenos y malos se compensan y el error cae con la raiz de N: siete
   * dias dan ~8%, treinta dan ~4%. Coincide con lo que dio la calibracion real
   * (10,3% / 9,3% / 12,0% para una semana), asi que sirve como orientacion
   * antes de crear el objetivo. El numero exacto de cada sucursal aparece
   * despues, cuando hay medicion.
   */
  const ruidoEstimado = largoVentana > 0 ? 20 / Math.sqrt(largoVentana) : null

  const metaMasChica = useMemo(() => {
    const vals = elegidas
      .map((s) => Math.abs(Number(metas[s.id].meta.replace(',', '.'))))
      .filter((v) => !isNaN(v) && v > 0)
    return vals.length ? Math.min(...vals) : null
  }, [elegidas, metas])

  const guardar = async () => {
    setError(null)
    if (!nombre.trim()) { setError('Ponele un nombre: es como se lo va a buscar despues.'); return }
    if (elegidas.length === 0) { setError('Elegi al menos una sucursal.'); return }
    if (hasta < desde) { setError('La fecha de fin no puede ser anterior a la de inicio.'); return }

    setGuardando(true)
    try {
      const creado = await estrategiaApi.crearObjetivo({
        nombre: nombre.trim(),
        metrica,
        fecha_desde: desde,
        fecha_hasta: hasta,
        notas: notas.trim() || null,
        sucursales: elegidas.map((s) => ({
          sucursal: s.id,
          meta_pct: Number(metas[s.id].meta.replace(',', '.')) || 0,
          responsable: metas[s.id].responsable.trim() || null,
          mail: metas[s.id].mail.trim() || null,
        })),
      })
      if (creado.objetivo) await onCreado(creado.objetivo.objetivo_id)
      else onCerrar()
    } catch (e) {
      setError('No se pudo crear: ' + (e instanceof Error ? e.message : 'error'))
    } finally {
      setGuardando(false)
    }
  }

  const setMeta = (id: number, campo: 'meta' | 'responsable' | 'mail', valor: string) =>
    setMetas((prev) => ({ ...prev, [id]: { ...prev[id], [campo]: valor } }))

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/50 p-4">
      <div className="my-8 w-full max-w-2xl rounded-lg bg-white shadow-xl dark:bg-gray-900">
        <div className="flex items-center justify-between border-b border-gray-200 px-5 py-3 dark:border-gray-700">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Nuevo objetivo</h2>
          <button onClick={onCerrar} aria-label="Cerrar"><X className="h-5 w-5 text-gray-400" /></button>
        </div>

        <div className="space-y-5 p-5">
          {error && (
            <div className="flex items-start gap-2 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
              <AlertTriangle className="mt-0.5 h-4 w-4 flex-shrink-0" />
              <span>{error}</span>
            </div>
          )}

          <div>
            <label className="mb-1 block text-xs font-medium text-gray-700 dark:text-gray-300">Nombre</label>
            <input
              type="text" value={nombre} onChange={(e) => setNombre(e.target.value)}
              placeholder="Semana del 5/10 - empujar volumen antes del calor"
              className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900 dark:text-white"
            />
          </div>

          {/* ---------------------------------------------------- metrica */}
          <div>
            <label className="mb-1.5 block text-xs font-medium text-gray-700 dark:text-gray-300">
              Que se quiere mover
            </label>
            <div className="grid gap-2 sm:grid-cols-3">
              {METRICAS.map((m) => (
                <button
                  key={m.id}
                  onClick={() => setMetrica(m.id)}
                  className={cn(
                    'rounded-lg border p-2.5 text-left transition-colors',
                    metrica === m.id
                      ? 'border-dfgroup-gold bg-amber-50 dark:bg-amber-950/30'
                      : 'border-gray-200 hover:border-gray-300 dark:border-gray-700',
                  )}
                >
                  <div className="text-sm font-medium text-gray-900 dark:text-white">{m.rotulo}</div>
                  <div className="mt-0.5 text-[11px] leading-snug text-gray-500">{m.ayuda}</div>
                </button>
              ))}
            </div>
          </div>

          {/* ----------------------------------------------------- ventana */}
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className="mb-1 block text-xs font-medium text-gray-700 dark:text-gray-300">Desde</label>
              <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)}
                className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900 dark:text-white" />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-gray-700 dark:text-gray-300">Hasta</label>
              <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)}
                className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900 dark:text-white" />
            </div>
          </div>

          {/* ------------------------------------------ metas por sucursal */}
          <div>
            <label className="mb-1 block text-xs font-medium text-gray-700 dark:text-gray-300">
              Meta por sucursal
            </label>
            <p className="mb-2 text-[11px] text-gray-500">
              En % sobre lo esperado para el clima de cada dia. No tiene que ser la misma en todas:
              una sucursal con margen para crecer puede ir a mas que el resto.
            </p>
            {/* Cuanto se puede exigir depende del largo de la ventana. Decirlo
                ACA, antes de fijar la meta, evita la discusion de despues sobre
                si un +3% en una semana se cumplio o no. */}
            {ruidoEstimado !== null && (
              <p className={cn(
                'mb-2 flex items-start gap-1 text-[11px]',
                metaMasChica !== null && metaMasChica < ruidoEstimado
                  ? 'text-amber-700 dark:text-amber-500'
                  : 'text-gray-500',
              )}>
                <HelpCircle className="mt-0.5 h-3 w-3 flex-shrink-0" />
                <span>
                  Con {largoVentana} dia{largoVentana === 1 ? '' : 's'} de ventana, el modelo
                  distingue desvios de alrededor de <strong>±{ruidoEstimado.toFixed(0)}%</strong>.
                  {metaMasChica !== null && metaMasChica < ruidoEstimado
                    ? ` Una meta de ${metaMasChica}% va a quedar dentro del ruido: se va a poder
                        ver el numero, pero no afirmar que se cumplio. Con una ventana mas larga si.`
                    : ' Las metas elegidas estan por encima de ese piso.'}
                </span>
              </p>
            )}

            <div className="space-y-1.5">
              {SUCURSALES.map((s) => {
                const m = metas[s.id]
                return (
                  <div key={s.id} className={cn(
                    'flex flex-wrap items-center gap-2 rounded-md border p-2',
                    m.incluida ? 'border-gray-200 dark:border-gray-700' : 'border-gray-100 opacity-50 dark:border-gray-800',
                  )}>
                    <label className="flex w-[130px] items-center gap-2 text-sm text-gray-900 dark:text-white">
                      <input
                        type="checkbox" checked={m.incluida}
                        onChange={(e) => setMetas((p) => ({ ...p, [s.id]: { ...p[s.id], incluida: e.target.checked } }))}
                        className="h-3.5 w-3.5 rounded border-gray-300"
                      />
                      {s.nombre}
                    </label>

                    <div className="flex items-center gap-1">
                      <input
                        type="text" inputMode="decimal" value={m.meta} disabled={!m.incluida}
                        onChange={(e) => setMeta(s.id, 'meta', e.target.value)}
                        className="w-16 rounded-md border border-gray-300 bg-white px-2 py-1 text-right text-sm dark:border-gray-700 dark:bg-gray-900 dark:text-white"
                      />
                      <span className="text-xs text-gray-500">%</span>
                    </div>

                    <input
                      type="text" value={m.responsable} disabled={!m.incluida}
                      onChange={(e) => setMeta(s.id, 'responsable', e.target.value)}
                      placeholder="Responsable"
                      className="min-w-[110px] flex-1 rounded-md border border-gray-300 bg-white px-2 py-1 text-xs dark:border-gray-700 dark:bg-gray-900 dark:text-white"
                    />
                    <input
                      type="email" value={m.mail} disabled={!m.incluida}
                      onChange={(e) => setMeta(s.id, 'mail', e.target.value)}
                      placeholder="Mail para el aviso"
                      className="min-w-[140px] flex-1 rounded-md border border-gray-300 bg-white px-2 py-1 text-xs dark:border-gray-700 dark:bg-gray-900 dark:text-white"
                    />
                  </div>
                )
              })}
            </div>
          </div>

          <div>
            <label className="mb-1 block text-xs font-medium text-gray-700 dark:text-gray-300">
              Notas (opcional)
            </label>
            <textarea
              value={notas} onChange={(e) => setNotas(e.target.value)} rows={2}
              placeholder="Por que se define esto ahora. Dentro de tres meses es lo unico que va a explicar la decision."
              className="w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm dark:border-gray-700 dark:bg-gray-900 dark:text-white"
            />
          </div>
        </div>

        <div className="flex items-center justify-between gap-3 border-t border-gray-200 px-5 py-3 dark:border-gray-700">
          <p className="text-[11px] text-gray-500">
            Al crearlo se generan las sugerencias contra el pronostico de ahora.
          </p>
          <div className="flex gap-2">
            <button onClick={onCerrar}
              className="rounded-md border border-gray-300 px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800">
              Cancelar
            </button>
            <button onClick={() => void guardar()} disabled={guardando}
              className="inline-flex items-center gap-2 rounded-md bg-dfgroup-gold px-3 py-2 text-sm font-medium text-white hover:brightness-95 disabled:opacity-50">
              {guardando && <Loader2 className="h-4 w-4 animate-spin" />}
              Crear objetivo
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
