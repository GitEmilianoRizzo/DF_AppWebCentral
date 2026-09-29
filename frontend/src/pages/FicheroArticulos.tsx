import { useCallback, useEffect, useMemo, useState } from 'react'
import { AlertTriangle, Loader2, Search, X } from 'lucide-react'
import {
  ficheroArticulosApi,
  type ArticuloFicha,
  type ArticuloFila,
  type ArticuloSap,
} from '@/services/api'
import { cn } from '@/lib/utils'

/**
 * Fichero de Articulos.
 *
 * Consulta del maestro de la base de origen, con la ficha de cada articulo en
 * un modal. Es SOLO LECTURA: el alta y la modificacion se siguen haciendo en
 * el sistema de gestion, y esto existe para poder mirar una ficha sin salir
 * de la app ni pedirle a alguien que la busque.
 *
 * COSTOS: YA VIENEN POR UNIDAD
 * ----------------------------
 * El maestro guarda el costo POR BULTO. El SP lo divide por las unidades que
 * trae antes de devolverlo, asi que lo que llega aca es costo unitario y se
 * muestra tal cual. Sin esa division una servilleta figura a 17.532 en vez de
 * 8,77.
 */

const money = (n: number | null | undefined, d = 2) =>
  n === null || n === undefined
    ? '—'
    : '$' + n.toLocaleString('es-AR', { minimumFractionDigits: d, maximumFractionDigits: d })
const num = (n: number | null | undefined, d = 0) =>
  n === null || n === undefined
    ? '—'
    : n.toLocaleString('es-AR', { minimumFractionDigits: d, maximumFractionDigits: d })
const texto = (s: string | null | undefined) => (s && s.trim() ? s : '—')

const TIPOS = ['', 'ELABORADO', 'INSUMO', 'REVENTA', 'SERVICIO']

export function FicheroArticulos() {
  const [buscar, setBuscar] = useState('')
  const [tipo, setTipo] = useState('')
  const [soloActivos, setSoloActivos] = useState(true)

  const [filas, setFilas] = useState<ArticuloFila[]>([])
  const [cargando, setCargando] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const [ficha, setFicha] = useState<ArticuloFicha | null>(null)
  const [cargandoFicha, setCargandoFicha] = useState(false)

  const listar = useCallback(async () => {
    setCargando(true)
    setError(null)
    try {
      setFilas(await ficheroArticulosApi.listar({
        buscar: buscar.trim() || undefined,
        tipo: tipo || undefined,
        soloActivos,
        top: 500,
      }))
    } catch (e) {
      setError('No se pudo traer el maestro: ' + (e instanceof Error ? e.message : 'error'))
    } finally {
      setCargando(false)
    }
  }, [buscar, tipo, soloActivos])

  useEffect(() => { void listar() /* eslint-disable-next-line */ }, [tipo, soloActivos])

  const abrir = async (articulo: number) => {
    setCargandoFicha(true)
    setFicha(null)
    try {
      setFicha(await ficheroArticulosApi.ficha(articulo))
    } catch (e) {
      setError('No se pudo abrir la ficha: ' + (e instanceof Error ? e.message : 'error'))
    } finally {
      setCargandoFicha(false)
    }
  }

  // Cerrar con Escape: en un modal de solo lectura es el gesto esperado.
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === 'Escape') setFicha(null) }
    window.addEventListener('keydown', h)
    return () => window.removeEventListener('keydown', h)
  }, [])

  const costoReceta = useMemo(
    () => (ficha?.receta ?? []).reduce((a, r) => a + (r.costo_total ?? 0), 0),
    [ficha])

  return (
    <div className="space-y-5">
      <header>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Fichero de Articulos</h1>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          Maestro de articulos del sistema de gestion. Consulta: no se edita desde aca.
        </p>
      </header>

      {error && (
        <div className="flex items-start gap-2 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
          <AlertTriangle className="mt-0.5 h-4 w-4 flex-shrink-0" />
          <span>{error}</span>
        </div>
      )}

      {/* --- filtros --- */}
      <div className="flex flex-wrap items-center gap-2">
        <form onSubmit={(e) => { e.preventDefault(); void listar() }} className="relative flex-1 min-w-[220px]">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
          <input type="text" value={buscar} onChange={(e) => setBuscar(e.target.value)}
            placeholder="Descripcion, codigo o numero de articulo..."
            className="w-full rounded-md border border-gray-300 bg-white py-2 pl-9 pr-3 text-sm focus:border-dfgroup-gold focus:outline-none focus:ring-1 focus:ring-dfgroup-gold dark:border-gray-700 dark:bg-gray-900 dark:text-white" />
        </form>

        <select value={tipo} onChange={(e) => setTipo(e.target.value)}
          className="rounded-md border border-gray-300 bg-white px-2 py-2 text-sm dark:border-gray-700 dark:bg-gray-900 dark:text-white">
          {TIPOS.map((t) => <option key={t} value={t}>{t || 'Todos los tipos'}</option>)}
        </select>

        <label className="flex cursor-pointer items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
          <input type="checkbox" checked={soloActivos} onChange={(e) => setSoloActivos(e.target.checked)}
            className="h-3.5 w-3.5 rounded border-gray-300 text-dfgroup-gold focus:ring-dfgroup-gold" />
          Solo activos
        </label>

        <button type="button" onClick={() => void listar()} disabled={cargando}
          className="flex items-center gap-2 rounded-md bg-dfgroup-gold px-4 py-2 text-sm font-semibold text-black hover:opacity-90 disabled:opacity-50">
          {cargando ? <Loader2 className="h-4 w-4 animate-spin" /> : <Search className="h-4 w-4" />}
          Buscar
        </button>
      </div>

      <p className="text-xs text-gray-500">
        {filas.length} articulo{filas.length === 1 ? '' : 's'}
        {filas.length >= 500 && ' (tope alcanzado: afinar la busqueda)'}
        . Tocar una fila para ver la ficha.
      </p>

      {/* --- listado --- */}
      <div className="overflow-x-auto rounded-xl border border-gray-200 dark:border-gray-800">
        <table className="w-full min-w-[820px] text-sm">
          <thead className="bg-gray-100 text-[11px] uppercase tracking-wide text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <tr>
              <th className="px-3 py-2 text-left">Articulo</th>
              <th className="px-3 py-2 text-left">Descripcion</th>
              <th className="px-3 py-2 text-left">Tipo</th>
              <th className="px-3 py-2 text-left">Grupo</th>
              <th className="px-3 py-2 text-right">Precio</th>
              <th className="px-3 py-2 text-right">Costo x unidad</th>
              <th className="px-3 py-2 text-left">Codigo SAP</th>
              <th className="px-3 py-2 text-center">Estado</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {cargando && !filas.length && (
              <tr><td colSpan={8} className="py-10 text-center text-gray-400">
                <Loader2 className="mx-auto h-5 w-5 animate-spin" /></td></tr>
            )}
            {!cargando && !filas.length && (
              <tr><td colSpan={8} className="py-10 text-center text-sm text-gray-400">
                No hay articulos para esos filtros.</td></tr>
            )}
            {filas.map((f) => (
              <tr key={f.articulo} onClick={() => void abrir(f.articulo)}
                className="cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800/40">
                <td className="px-3 py-2 tabular-nums text-gray-500">{f.articulo}</td>
                <td className="px-3 py-2 font-medium text-gray-900 dark:text-gray-100">{f.descripcion}</td>
                <td className="px-3 py-2 text-xs text-gray-500">{texto(f.tipo)}</td>
                <td className="px-3 py-2 text-xs text-gray-500">{texto(f.grupo_descrip)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{money(f.precio, 0)}</td>
                <td className="px-3 py-2 text-right tabular-nums text-gray-500">
                  {f.costo !== null && f.unid_x_bulto
                    ? money(f.costo / f.unid_x_bulto)
                    : money(f.costo)}
                </td>
                <td className="px-3 py-2">
                  {f.codigo_sap
                    ? <span className="font-mono text-xs text-gray-700 dark:text-gray-300">{f.codigo_sap}</span>
                    : <span className="text-[11px] text-amber-600 dark:text-amber-400">sin cargar</span>}
                </td>
                <td className="px-3 py-2 text-center">
                  <span className={cn('rounded px-1.5 py-0.5 text-[10px] font-medium',
                    f.estado === 'ACTIVO'
                      ? 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300'
                      : 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400')}>
                    {texto(f.estado)}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* --- ficha --- */}
      {(ficha || cargandoFicha) && (
        <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/50 p-4"
          onClick={() => setFicha(null)}>
          <div className="my-8 w-full max-w-4xl rounded-xl bg-white shadow-2xl dark:bg-gray-900"
            onClick={(e) => e.stopPropagation()}>
            {cargandoFicha || !ficha?.detalle ? (
              <div className="flex h-48 items-center justify-center">
                <Loader2 className="h-6 w-6 animate-spin text-dfgroup-gold" />
              </div>
            ) : (
              <Ficha ficha={ficha} costoReceta={costoReceta} onCerrar={() => setFicha(null)}
                onSapGuardado={(sap) => {
                  setFicha({ ...ficha, sap })
                  // El listado muestra el codigo SAP: si no se refresca, la
                  // fila de atras sigue diciendo que falta cargarlo.
                  setFilas((fs) => fs.map((f) =>
                    f.articulo === ficha.detalle!.articulo
                      ? { ...f, codigo_sap: sap?.activo ? sap.codigo_sap : null }
                      : f))
                }} />
            )}
          </div>
        </div>
      )}
    </div>
  )
}

type SolapaFicha = 'ficha' | 'receta' | 'sap'

function Ficha({ ficha, costoReceta, onCerrar, onSapGuardado }: {
  ficha: ArticuloFicha
  costoReceta: number
  onCerrar: () => void
  onSapGuardado: (sap: ArticuloSap | null) => void
}) {
  const d = ficha.detalle!
  const [solapa, setSolapa] = useState<SolapaFicha>('ficha')

  return (
    <>
      <div className="flex items-start justify-between gap-4 border-b border-gray-200 p-4 dark:border-gray-800">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-gray-400">#{d.articulo}</span>
            <h2 className="truncate text-lg font-bold text-gray-900 dark:text-white">{d.descripcion}</h2>
            <span className={cn('rounded px-1.5 py-0.5 text-[10px] font-medium',
              d.estado === 'ACTIVO'
                ? 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300'
                : 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400')}>
              {texto(d.estado)}
            </span>
          </div>
          <p className="mt-0.5 text-xs text-gray-500">
            {texto(d.tipo)} · {texto(d.grupo_descrip)} · Tiquet: {texto(d.descrip_ticket)}
          </p>
        </div>
        <button type="button" onClick={onCerrar} aria-label="Cerrar"
          className="rounded p-1 text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800">
          <X className="h-5 w-5" />
        </button>
      </div>

      {/* Solapas. Solo la de SAP se edita; las otras dos son el maestro de
          origen, que se administra en el sistema de gestion. */}
      <nav className="flex gap-1 border-b border-gray-200 px-4 pt-3 dark:border-gray-800">
        {([
          { id: 'ficha', rotulo: 'Ficha' },
          { id: 'receta', rotulo: `Receta (${ficha.receta.length})` },
          { id: 'sap', rotulo: 'Codigo SAP' },
        ] as { id: SolapaFicha; rotulo: string }[]).map((s) => (
          <button key={s.id} type="button" onClick={() => setSolapa(s.id)}
            className={cn('relative rounded-t-md px-3 py-2 text-sm font-medium transition-colors',
              solapa === s.id
                ? 'text-dfgroup-gold after:absolute after:inset-x-0 after:-bottom-px after:h-0.5 after:bg-dfgroup-gold'
                : 'text-gray-500 hover:text-gray-800 dark:hover:text-gray-200')}>
            {s.rotulo}
            {s.id === 'sap' && (
              <span className={cn('ml-1.5 inline-block h-1.5 w-1.5 rounded-full',
                ficha.sap?.codigo_sap ? 'bg-green-500' : 'bg-amber-400')} />
            )}
          </button>
        ))}
      </nav>

      {solapa === 'sap' ? (
        <SolapaSap articulo={d.articulo} sap={ficha.sap} onGuardado={onSapGuardado} />
      ) : solapa === 'receta' ? (
        <div className="p-4"><Receta ficha={ficha} costoReceta={costoReceta} /></div>
      ) : (
      <div className="space-y-5 p-4">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Bloque titulo="Datos para la venta">
            <Dato r="Venta al publico" v={texto(d.venta_publico)} />
            <Dato r="Tasa de IVA" v={num(d.iva_tasa)} />
            <Dato r="Orden de boton" v={num(d.orden)} />
            <Dato r="Peso" v={d.peso ? num(d.peso, 3) + ' kg' : '—'} />
            <Dato r="Codigo" v={texto(d.codigo)} />
          </Bloque>

          <Bloque titulo="Precios">
            <Dato r="Lista 1" v={money(d.precio_lista1, 0)} destacado />
            <Dato r="Lista 2" v={money(d.precio_lista2, 0)} />
            <Dato r="Lista 3" v={money(d.precio_lista3, 0)} />
            <Dato r="Gastronomico 1" v={money(d.precio_gastro1, 0)} />
            <Dato r="Ultima actualizacion"
              v={d.fecha_estado ? new Date(d.fecha_estado).toLocaleString('es-AR') : '—'} />
          </Bloque>

          <Bloque titulo="Compra y stock">
            <Dato r="Costo (por bulto)" v={money(d.costo)} />
            <Dato r="Unidades por bulto" v={num(d.unid_x_bulto, 2)} />
            <Dato r="Costo por unidad"
              v={d.costo && d.unid_x_bulto ? money(d.costo / d.unid_x_bulto) : '—'} destacado />
            <Dato r="Stock minimo" v={num(d.stock_minimo, 2)} />
            <Dato r="Proveedor" v={num(d.proveedor)} />
          </Bloque>

          <Bloque titulo="Margen">
            <Dato r="Precio lista 1" v={money(d.precio_lista1, 0)} />
            <Dato r="Costo de receta" v={costoReceta ? money(costoReceta) : '—'} />
            <Dato r="Margen"
              v={d.precio_lista1 && costoReceta
                ? money(d.precio_lista1 - costoReceta, 0) +
                  ` (${(((d.precio_lista1 - costoReceta) / d.precio_lista1) * 100).toFixed(1)}%)`
                : '—'} destacado />
          </Bloque>
        </div>

      </div>
      )}
    </>
  )
}

function Receta({ ficha, costoReceta }: { ficha: ArticuloFicha; costoReceta: number }) {
  return (
        <div>
          {!ficha.receta.length ? (
            <p className="py-4 text-center text-sm text-gray-400">
              Este articulo no tiene receta cargada.
            </p>
          ) : (
            <div className="overflow-x-auto rounded-lg border border-gray-200 dark:border-gray-800">
              <table className="w-full min-w-[520px] text-sm">
                <thead className="bg-gray-100 text-[11px] uppercase tracking-wide text-gray-500 dark:bg-gray-800 dark:text-gray-400">
                  <tr>
                    <th className="px-3 py-2 text-left">Componente</th>
                    <th className="px-3 py-2 text-right">Cantidad</th>
                    <th className="px-3 py-2 text-right">Costo unit.</th>
                    <th className="px-3 py-2 text-right">Costo total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                  {ficha.receta.map((r) => (
                    <tr key={r.orden}>
                      <td className="px-3 py-2">
                        <span className="text-gray-900 dark:text-gray-100">{texto(r.descripcion)}</span>
                        {r.clase === 'GENERICO' && (
                          <span className="ml-2 rounded bg-gray-100 px-1.5 py-0.5 text-[10px] text-gray-500 dark:bg-gray-800">
                            generico
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">{num(r.cantidad, 3)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{money(r.costo_unit)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{money(r.costo_total)}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot className="border-t-2 border-gray-300 bg-gray-50 font-semibold dark:border-gray-700 dark:bg-gray-800">
                  <tr>
                    <td className="px-3 py-2" colSpan={3}>Costo de la receta</td>
                    <td className="px-3 py-2 text-right tabular-nums">{money(costoReceta)}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          )}
          <p className="mt-2 text-[11px] leading-snug text-gray-400">
            Los componentes marcados como generico son categorias (por ejemplo HELADO) que
            se resuelven contra el sabor concreto en el momento de la venta, y por eso no
            tienen costo propio en la ficha.
          </p>
        </div>
  )
}

/**
 * Solapa de codigo SAP: lo unico editable de toda la ficha.
 *
 * El dato se guarda en DF_DTW y NO en la base de origen, que se restaura
 * entera todos los dias a las 12:00: escribir alla seria perder la carga a la
 * mañana siguiente.
 */
function SolapaSap({ articulo, sap, onGuardado }: {
  articulo: number
  sap: ArticuloSap | null
  onGuardado: (sap: ArticuloSap | null) => void
}) {
  const [codigo, setCodigo] = useState(sap?.codigo_sap ?? '')
  const [descripcion, setDescripcion] = useState(sap?.descripcion_sap ?? '')
  const [unidad, setUnidad] = useState(sap?.unidad_sap ?? '')
  const [factor, setFactor] = useState(String(sap?.factor_sap ?? 1))
  const [observaciones, setObservaciones] = useState(sap?.observaciones ?? '')
  const [activo, setActivo] = useState(sap?.activo ?? true)

  const [guardando, setGuardando] = useState(false)
  const [msg, setMsg] = useState<{ tipo: 'ok' | 'error'; texto: string } | null>(null)

  const factorNum = Number(factor.replace(',', '.'))
  const codigoOk = codigo.trim().length > 0
  const factorOk = Number.isFinite(factorNum) && factorNum > 0
  const sucio =
    codigo.trim() !== (sap?.codigo_sap ?? '') ||
    descripcion !== (sap?.descripcion_sap ?? '') ||
    unidad !== (sap?.unidad_sap ?? '') ||
    factorNum !== (sap?.factor_sap ?? 1) ||
    observaciones !== (sap?.observaciones ?? '') ||
    activo !== (sap?.activo ?? true)

  const guardar = async () => {
    if (!codigoOk || !factorOk) return
    setGuardando(true)
    setMsg(null)
    try {
      const r = await ficheroArticulosApi.guardarSap(articulo, {
        codigo_sap: codigo.trim(),
        descripcion_sap: descripcion.trim() || null,
        unidad_sap: unidad.trim() || null,
        factor_sap: factorNum,
        observaciones: observaciones.trim() || null,
        activo,
      })
      onGuardado(r)
      setMsg({ tipo: 'ok', texto: 'Guardado.' })
    } catch (e) {
      setMsg({ tipo: 'error', texto: e instanceof Error ? e.message : 'No se pudo guardar.' })
    } finally {
      setGuardando(false)
    }
  }

  const borrar = async () => {
    setGuardando(true)
    setMsg(null)
    try {
      await ficheroArticulosApi.borrarSap(articulo)
      setCodigo(''); setDescripcion(''); setUnidad(''); setFactor('1')
      setObservaciones(''); setActivo(true)
      onGuardado(null)
      setMsg({ tipo: 'ok', texto: 'Relacion borrada.' })
    } catch (e) {
      setMsg({ tipo: 'error', texto: e instanceof Error ? e.message : 'No se pudo borrar.' })
    } finally {
      setGuardando(false)
    }
  }

  const campo = 'w-full rounded-md border border-gray-300 bg-white px-2 py-1.5 text-sm ' +
    'focus:border-dfgroup-gold focus:outline-none focus:ring-1 focus:ring-dfgroup-gold ' +
    'dark:border-gray-700 dark:bg-gray-900 dark:text-white'

  return (
    <div className="space-y-4 p-4">
      <p className="rounded-lg bg-blue-50 p-3 text-xs leading-snug text-blue-900 dark:bg-blue-950/40 dark:text-blue-200">
        Relacion con el codigo SAP de Grido Central, para poder planificar las compras
        por ese codigo. Varios articulos pueden compartir un mismo codigo; cada articulo
        tiene uno solo.
      </p>

      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-gray-600 dark:text-gray-300">
            Codigo SAP <span className="text-red-500">*</span>
          </label>
          <input type="text" value={codigo} onChange={(e) => setCodigo(e.target.value)}
            placeholder="Como figura en Central"
            className={cn(campo, 'font-mono', !codigoOk && codigo !== '' && 'border-red-400')} />
        </div>

        <div>
          <label className="mb-1 block text-xs font-medium text-gray-600 dark:text-gray-300">
            Descripcion en SAP
          </label>
          <input type="text" value={descripcion} onChange={(e) => setDescripcion(e.target.value)}
            placeholder="Opcional" className={campo} />
        </div>

        <div>
          <label className="mb-1 block text-xs font-medium text-gray-600 dark:text-gray-300">
            Unidad de compra
          </label>
          <input type="text" value={unidad} onChange={(e) => setUnidad(e.target.value)}
            placeholder="UN, CAJA, KG..." className={campo} />
        </div>

        <div>
          <label className="mb-1 block text-xs font-medium text-gray-600 dark:text-gray-300">
            Factor de conversion
          </label>
          <input type="text" inputMode="decimal" value={factor}
            onChange={(e) => setFactor(e.target.value)}
            className={cn(campo, !factorOk && 'border-red-400')} />
          <p className="mt-1 text-[11px] leading-snug text-gray-400">
            Cuantas unidades SAP equivalen a una unidad de aca. Dejar en 1 si es lo mismo.
          </p>
        </div>

        <div className="md:col-span-2">
          <label className="mb-1 block text-xs font-medium text-gray-600 dark:text-gray-300">
            Observaciones
          </label>
          <textarea value={observaciones} onChange={(e) => setObservaciones(e.target.value)}
            rows={2} placeholder="Opcional" className={campo} />
        </div>

        <label className="flex cursor-pointer items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
          <input type="checkbox" checked={activo} onChange={(e) => setActivo(e.target.checked)}
            className="h-3.5 w-3.5 rounded border-gray-300 text-dfgroup-gold focus:ring-dfgroup-gold" />
          Relacion vigente
        </label>
      </div>

      {msg && (
        <p className={cn('rounded-md px-3 py-2 text-sm',
          msg.tipo === 'ok'
            ? 'bg-green-50 text-green-800 dark:bg-green-950/40 dark:text-green-300'
            : 'bg-red-50 text-red-800 dark:bg-red-950/40 dark:text-red-300')}>
          {msg.texto}
        </p>
      )}

      <div className="flex flex-wrap items-center gap-2 border-t border-gray-200 pt-3 dark:border-gray-800">
        <button type="button" onClick={() => void guardar()}
          disabled={guardando || !codigoOk || !factorOk || !sucio}
          className="flex items-center gap-2 rounded-md bg-dfgroup-gold px-4 py-2 text-sm font-semibold text-black hover:opacity-90 disabled:opacity-40">
          {guardando ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
          {sap?.codigo_sap ? 'Guardar cambios' : 'Guardar'}
        </button>

        {sap?.codigo_sap && (
          <button type="button" onClick={() => void borrar()} disabled={guardando}
            className="rounded-md border border-red-300 px-3 py-2 text-sm text-red-700 hover:bg-red-50 disabled:opacity-40 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950/40">
            Borrar relacion
          </button>
        )}

        {!sucio && sap?.codigo_sap && (
          <span className="text-xs text-gray-400">Sin cambios para guardar.</span>
        )}
      </div>

      {(sap?.usuario_alta || sap?.usuario_mod) && (
        <p className="text-[11px] text-gray-400">
          {sap.usuario_alta && (
            <>Cargado por {sap.usuario_alta}
              {sap.fecha_alta && ` el ${new Date(sap.fecha_alta).toLocaleString('es-AR')}`}.</>
          )}
          {sap.usuario_mod && (
            <> Ultima modificacion de {sap.usuario_mod}
              {sap.fecha_mod && ` el ${new Date(sap.fecha_mod).toLocaleString('es-AR')}`}.</>
          )}
        </p>
      )}
    </div>
  )
}

function Bloque({ titulo, children }: { titulo: string; children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-gray-200 p-3 dark:border-gray-800">
      <h3 className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-gray-400">{titulo}</h3>
      <dl className="space-y-1">{children}</dl>
    </div>
  )
}

function Dato({ r, v, destacado }: { r: string; v: string; destacado?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3 border-b border-gray-100 py-1 last:border-0 dark:border-gray-800">
      <dt className="text-xs text-gray-500 dark:text-gray-400">{r}</dt>
      <dd className={cn('text-right text-sm tabular-nums',
        destacado ? 'font-bold text-gray-900 dark:text-white' : 'text-gray-700 dark:text-gray-300')}>
        {v}
      </dd>
    </div>
  )
}
