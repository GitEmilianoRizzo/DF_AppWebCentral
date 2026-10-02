import axios from 'axios'
import type {
  HomeDashboard,
  VentasResumenDiario,
  VentasPorFranquicia,
  VentasPorProducto,
  VentasPorMozo,
  VentasPorTipoPlato,
  OcupacionMesas,
  EstadoIntegracion,
  DashboardFilters,
  // v1.2 types
  VentasConsolidadas,
  VentasPorProductoConPeso,
  VentasPorMealPeriod,
  DiaRanking,
  VentasDelDia,
  ComparativoMensual,
  // v1.3 types
  VentasPorHora,
  // Transacciones
  Transaccion,
  TransaccionDetalle,
} from '@/types/dashboard'
import type {
  NodoConexion,
  NodoConexionCreate,
  NodoDetalle,
  MapeoCategoria,
  MapeoMedioPago,
  FieldMapping,
  Parser,
  ParseBatchResult,
  IngestFileDto,
  IngestBatchResult,
} from '@/types/conexiones'
import type {
  AuthResponse,
  LoginRequest,
  GoogleLoginRequest,
  User,
  UserList,
  Rol,
  RegisterRequest,
  UpdateUserRequest,
  ChangePasswordRequest,
} from '@/types/auth'

// Resultado de ejecución
export interface EjecucionResult {
  success: boolean
  message: string
  tickets_procesados: number
  lineas_procesadas: number
  errors_count: number
  ejecucion_id?: number
  batch_id?: number
}

const API_BASE_URL = import.meta.env.VITE_API_URL || '/api/v1'

const apiClient = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
})

// Token management - will be set by AuthContext
let accessToken: string | null = null

export const setAccessToken = (token: string | null) => {
  accessToken = token
}

export const getAccessToken = () => accessToken

// Public auth endpoints that don't need token
const PUBLIC_AUTH_ENDPOINTS = ['/auth/login', '/auth/google', '/auth/refresh']

// Request interceptor for logging and auth
apiClient.interceptors.request.use(
  (config) => {
    console.log(`[API] ${config.method?.toUpperCase()} ${config.url}`)

    // Add auth header if we have a token (except for public auth endpoints)
    const isPublicEndpoint = PUBLIC_AUTH_ENDPOINTS.some(
      (endpoint) => config.url?.startsWith(endpoint)
    )
    if (accessToken && !isPublicEndpoint) {
      config.headers.Authorization = `Bearer ${accessToken}`
    }

    return config
  },
  (error) => {
    return Promise.reject(error)
  }
)

// Response interceptor for error handling
apiClient.interceptors.response.use(
  (response) => response,
  (error) => {
    console.error('[API Error]', error.response?.data || error.message)
    return Promise.reject(error)
  }
)

function buildQueryString(filters?: DashboardFilters): string {
  if (!filters) return ''

  const params = new URLSearchParams()
  if (filters.fechaDesde) params.append('fechaDesde', filters.fechaDesde)
  if (filters.fechaHasta) params.append('fechaHasta', filters.fechaHasta)
  if (filters.franquiciaId) params.append('franquiciaId', filters.franquiciaId.toString())
  if (filters.grupoEconomicoId) params.append('grupoEconomicoId', filters.grupoEconomicoId.toString())

  const queryString = params.toString()
  return queryString ? `?${queryString}` : ''
}

export const dashboardApi = {
  // Dashboard Home
  async getHomeDashboard(filters?: DashboardFilters): Promise<HomeDashboard[]> {
    const query = buildQueryString(filters)
    const response = await apiClient.get<HomeDashboard[]>(`/dashboard/home${query}`)
    return response.data
  },

  // Ventas Resumen Diario
  async getVentasResumen(filters?: DashboardFilters): Promise<VentasResumenDiario[]> {
    const query = buildQueryString(filters)
    const response = await apiClient.get<VentasResumenDiario[]>(`/dashboard/ventas/resumen${query}`)
    return response.data
  },

  // Ventas por Franquicia
  async getVentasPorFranquicia(filters?: DashboardFilters): Promise<VentasPorFranquicia[]> {
    const query = buildQueryString(filters)
    const response = await apiClient.get<VentasPorFranquicia[]>(`/dashboard/ventas/por-franquicia${query}`)
    return response.data
  },

  // Ventas por Producto
  async getVentasPorProducto(filters?: DashboardFilters): Promise<VentasPorProducto[]> {
    const query = buildQueryString(filters)
    const response = await apiClient.get<VentasPorProducto[]>(`/dashboard/ventas/por-producto${query}`)
    return response.data
  },

  // Ventas por Mozo
  async getVentasPorMozo(filters?: DashboardFilters): Promise<VentasPorMozo[]> {
    const query = buildQueryString(filters)
    const response = await apiClient.get<VentasPorMozo[]>(`/dashboard/ventas/por-mozo${query}`)
    return response.data
  },

  // Ventas por Tipo de Plato
  async getVentasPorTipoPlato(filters?: DashboardFilters): Promise<VentasPorTipoPlato[]> {
    const query = buildQueryString(filters)
    const response = await apiClient.get<VentasPorTipoPlato[]>(`/dashboard/ventas/por-tipo-plato${query}`)
    return response.data
  },

  // Ocupacion de Mesas
  async getOcupacionMesas(filters?: DashboardFilters): Promise<OcupacionMesas[]> {
    const query = buildQueryString(filters)
    const response = await apiClient.get<OcupacionMesas[]>(`/dashboard/ventas/ocupacion-mesas${query}`)
    return response.data
  },

  // Estado de Integracion
  async getEstadoIntegracion(): Promise<EstadoIntegracion[]> {
    const response = await apiClient.get<EstadoIntegracion[]>('/dashboard/integraciones/estado-franquicias')
    return response.data
  },

  // Health check
  async getHealth(): Promise<{ status: string; timestamp: string }> {
    const response = await apiClient.get('/api/health')
    return response.data
  },

  // Exportar transacciones a Excel
  async exportTransaccionesExcel(params: {
    fechaDesde: string
    fechaHasta: string
    pais?: string
    franquiciaId?: number
  }): Promise<Blob> {
    const query = buildQueryString(params)
    const response = await apiClient.get(`/dashboard/transacciones/export/excel${query}`, {
      responseType: 'blob',
    })
    return response.data
  },
}

// Conexiones API
export const conexionesApi = {
  // Obtener todos los nodos
  async getAllNodos(): Promise<NodoConexion[]> {
    const response = await apiClient.get<NodoConexion[]>('/conexiones')
    return response.data
  },

  // Obtener nodo por ID
  async getNodoById(id: number): Promise<NodoConexion> {
    const response = await apiClient.get<NodoConexion>(`/conexiones/${id}`)
    return response.data
  },

  // Obtener nodo por codigo
  async getNodoByCodigo(codigo: string): Promise<NodoConexion> {
    const response = await apiClient.get<NodoConexion>(`/conexiones/codigo/${codigo}`)
    return response.data
  },

  // Obtener detalle completo del nodo
  async getNodoDetalle(id: number): Promise<NodoDetalle> {
    const response = await apiClient.get<NodoDetalle>(`/conexiones/${id}/detalle`)
    return response.data
  },

  // Crear nodo
  async createNodo(nodo: NodoConexionCreate): Promise<{ nodo_conexion_id: number }> {
    const response = await apiClient.post<{ nodo_conexion_id: number }>('/conexiones', nodo)
    return response.data
  },

  // Actualizar estado del nodo
  async updateNodoEstado(id: number, estado: string): Promise<void> {
    await apiClient.patch(`/conexiones/${id}/estado`, { estado })
  },

  // Upsert mapeo de categoria
  async upsertMapeoCategoria(nodoId: number, mapeo: Partial<MapeoCategoria>): Promise<{ mapeo_categoria_id: number }> {
    const response = await apiClient.put<{ mapeo_categoria_id: number }>(
      `/conexiones/${nodoId}/mapeos/categoria`,
      mapeo
    )
    return response.data
  },

  // Upsert mapeo de medio de pago
  async upsertMapeoMedioPago(nodoId: number, mapeo: Partial<MapeoMedioPago>): Promise<{ mapeo_medio_pago_id: number }> {
    const response = await apiClient.put<{ mapeo_medio_pago_id: number }>(
      `/conexiones/${nodoId}/mapeos/medio-pago`,
      mapeo
    )
    return response.data
  },

  // Actualizar mapeos de campos
  async updateFieldMappings(nodoId: number, mappings: FieldMapping[]): Promise<{ field_mappings_count: number }> {
    const response = await apiClient.put<{ field_mappings_count: number }>(
      `/conexiones/${nodoId}/field-mappings`,
      mappings
    )
    return response.data
  },

  // Ejecutar extracción manual
  async ejecutarExtraccion(nodoId: number, fechaNegocio?: string): Promise<EjecucionResult> {
    const params = fechaNegocio ? `?fechaNegocio=${fechaNegocio}` : ''
    const response = await apiClient.post<EjecucionResult>(`/conexiones/${nodoId}/ejecutar${params}`)
    return response.data
  },

  // Obtener catalogos
  async getCategorias(): Promise<string[]> {
    const response = await apiClient.get<string[]>('/conexiones/catalogos/categorias')
    return response.data
  },

  async getMediosPago(): Promise<string[]> {
    const response = await apiClient.get<string[]>('/conexiones/catalogos/medios-pago')
    return response.data
  },

  // TXT Parser endpoints
  async getParsers(): Promise<Parser[]> {
    const response = await apiClient.get<Parser[]>('/conexiones/parsers')
    return response.data
  },

  async getParserById(parserId: number): Promise<Parser> {
    const response = await apiClient.get<Parser>(`/conexiones/parsers/${parserId}`)
    return response.data
  },

  async parseTxtFiles(nodoId: number, files: File[], parserCode?: string): Promise<ParseBatchResult> {
    const formData = new FormData()
    files.forEach(file => {
      formData.append('files', file)
    })
    if (parserCode) {
      formData.append('parser_code', parserCode)
    }
    const response = await apiClient.post<ParseBatchResult>(
      `/conexiones/${nodoId}/parse-txt`,
      formData,
      {
        headers: {
          'Content-Type': 'multipart/form-data',
        },
      }
    )
    return response.data
  },

  async ingestParsedFiles(nodoId: number, files: IngestFileDto[]): Promise<IngestBatchResult> {
    const response = await apiClient.post<IngestBatchResult>(
      `/conexiones/${nodoId}/ingest-parsed`,
      { files }
    )
    return response.data
  },
}

// Franquicias API
export interface Franquicia {
  franquicia_id: number
  codigo: string
  nombre: string
  grupo_economico_id: number | null
  grupo_economico_nombre: string | null
  pais: string | null
  ciudad: string | null
  zona_horaria: string | null
  sistema_origen: string | null
  contacto_nombre: string | null
  contacto_email: string | null
  contacto_telefono: string | null
  estado_integracion: string | null
  ultima_sincronizacion: string | null
}

export interface FranquiciaUpdate {
  nombre?: string
  grupo_economico_id?: number
  pais?: string
  ciudad?: string
  sistema_origen?: string
  contacto_nombre?: string
  contacto_email?: string
  contacto_telefono?: string
  zona_horaria?: string
}

export interface GrupoEconomico {
  grupo_economico_id: number
  codigo: string
  nombre: string
  pais: string | null
}

// Preferencias API
export interface PreferenciaColumnas {
  vista_id: string
  columnas_visibles: string[]
  orden_columnas?: string[]
}

export const preferenciasApi = {
  async getColumnPreferences(vistaId: string): Promise<PreferenciaColumnas | null> {
    try {
      const response = await apiClient.get<PreferenciaColumnas>(`/preferencias/columnas/${vistaId}`)
      return response.data
    } catch (error) {
      // Si no hay preferencias guardadas, retornar null
      return null
    }
  },

  async saveColumnPreferences(vistaId: string, columnasVisibles: string[], ordenColumnas?: string[]): Promise<void> {
    await apiClient.put(`/preferencias/columnas/${vistaId}`, {
      columnas_visibles: columnasVisibles,
      orden_columnas: ordenColumnas,
    })
  },
}

export const franquiciasApi = {
  async getAll(): Promise<Franquicia[]> {
    const response = await apiClient.get<Franquicia[]>('/franquicias')
    return response.data
  },

  async getById(id: number): Promise<Franquicia> {
    const response = await apiClient.get<Franquicia>(`/franquicias/${id}`)
    return response.data
  },

  async update(id: number, data: FranquiciaUpdate): Promise<void> {
    await apiClient.put(`/franquicias/${id}`, data)
  },

  async getGruposEconomicos(): Promise<GrupoEconomico[]> {
    const response = await apiClient.get<GrupoEconomico[]>('/grupos-economicos')
    return response.data
  },
}

export default dashboardApi

// v1.2 Extended query builder
function buildQueryStringV2(filters?: DashboardFilters): string {
  if (!filters) return ''

  const params = new URLSearchParams()
  if (filters.fechaDesde) params.append('fechaDesde', filters.fechaDesde)
  if (filters.fechaHasta) params.append('fechaHasta', filters.fechaHasta)
  if (filters.franquiciaId) params.append('franquiciaId', filters.franquiciaId.toString())
  if (filters.grupoEconomicoId) params.append('grupoEconomicoId', filters.grupoEconomicoId.toString())
  if (filters.pais) params.append('pais', filters.pais)
  if (filters.currencyMode) params.append('currencyMode', filters.currencyMode)
  if (filters.taxMode) params.append('taxMode', filters.taxMode)
  if (filters.mealPeriod) params.append('mealPeriod', filters.mealPeriod)
  if (filters.anio) params.append('anio', filters.anio.toString())
  if (filters.mes) params.append('mes', filters.mes.toString())
  // v1.3: Bidirectional filtering
  if (filters.productoId) params.append('productoId', filters.productoId.toString())
  if (filters.hora !== undefined && filters.hora !== null) params.append('hora', filters.hora.toString())

  const queryString = params.toString()
  return queryString ? `?${queryString}` : ''
}

// v1.2 Dashboard API with USD and tax axis support
export const dashboardApiV2 = {
  // Ventas consolidadas con USD y separación de impuestos
  async getVentasConsolidadas(filters?: DashboardFilters): Promise<VentasConsolidadas[]> {
    const query = buildQueryStringV2(filters)
    const response = await apiClient.get<VentasConsolidadas[]>(`/dashboard/v2/ventas/consolidadas${query}`)
    return response.data
  },

  // Ventas por producto con peso relativo
  async getVentasPorProductoConPeso(filters?: DashboardFilters): Promise<VentasPorProductoConPeso[]> {
    const query = buildQueryStringV2(filters)
    const response = await apiClient.get<VentasPorProductoConPeso[]>(`/dashboard/v2/ventas/por-producto${query}`)
    return response.data
  },

  // Ventas por turno/período de comida
  async getVentasPorMealPeriod(filters?: DashboardFilters): Promise<VentasPorMealPeriod[]> {
    const query = buildQueryStringV2(filters)
    const response = await apiClient.get<VentasPorMealPeriod[]>(`/dashboard/v2/ventas/por-turno${query}`)
    return response.data
  },

  // Ranking de días (mejores/peores)
  async getDiaRanking(filters?: DashboardFilters, mejores = true, top = 10): Promise<DiaRanking[]> {
    const query = buildQueryStringV2(filters)
    const separator = query ? '&' : '?'
    const response = await apiClient.get<DiaRanking[]>(`/dashboard/v2/ventas/ranking-dias${query}${separator}mejores=${mejores}&top=${top}`)
    return response.data
  },

  // Ventas del día actual con comparativos
  async getVentasDelDia(filters?: DashboardFilters): Promise<VentasDelDia[]> {
    const query = buildQueryStringV2(filters)
    const response = await apiClient.get<VentasDelDia[]>(`/dashboard/v2/ventas/hoy${query}`)
    return response.data
  },

  // Comparativo mensual
  async getComparativoMensual(filters?: DashboardFilters): Promise<ComparativoMensual[]> {
    const query = buildQueryStringV2(filters)
    const response = await apiClient.get<ComparativoMensual[]>(`/dashboard/v2/ventas/comparativo-mensual${query}`)
    return response.data
  },

  // v1.3: Ventas por hora (ClockChart)
  async getVentasPorHora(filters?: DashboardFilters): Promise<VentasPorHora[]> {
    const query = buildQueryStringV2(filters)
    const response = await apiClient.get<VentasPorHora[]>(`/dashboard/v2/ventas/por-hora${query}`)
    return response.data
  },
}

// Transacciones API
export const transaccionesApi = {
  // Obtener transacciones de una franquicia en un rango de fechas
  async getTransaccionesByFranquicia(
    franquiciaId: number,
    fechaDesde: string,
    fechaHasta: string
  ): Promise<Transaccion[]> {
    const params = new URLSearchParams({
      franquiciaId: franquiciaId.toString(),
      fechaDesde,
      fechaHasta,
    })
    const response = await apiClient.get<Transaccion[]>(`/dashboard/transacciones?${params}`)
    return response.data
  },

  // Obtener el detalle de líneas de una transacción
  async getTransaccionDetalle(ticketId: number): Promise<TransaccionDetalle[]> {
    const response = await apiClient.get<TransaccionDetalle[]>(`/dashboard/transacciones/${ticketId}/detalle`)
    return response.data
  },
}

// Auth API
export const authApi = {
  // Login con email/password
  async login(request: LoginRequest): Promise<AuthResponse> {
    const response = await apiClient.post<AuthResponse>('/auth/login', request)
    return response.data
  },

  // Login con Google
  async googleLogin(request: GoogleLoginRequest): Promise<AuthResponse> {
    const response = await apiClient.post<AuthResponse>('/auth/google', request)
    return response.data
  },

  // Refrescar token
  async refreshToken(refreshToken: string): Promise<AuthResponse> {
    const response = await apiClient.post<AuthResponse>('/auth/refresh', { refresh_token: refreshToken })
    return response.data
  },

  // Logout (revocar token)
  async logout(refreshToken: string): Promise<void> {
    await apiClient.post('/auth/logout', { refresh_token: refreshToken })
  },

  // Obtener usuario actual
  async getCurrentUser(): Promise<User> {
    const response = await apiClient.get<User>('/auth/me')
    return response.data
  },

  // Cambiar contraseña
  async changePassword(request: ChangePasswordRequest): Promise<void> {
    await apiClient.post('/auth/change-password', request)
  },

  // --- Admin endpoints ---

  // Listar todos los usuarios (Admin)
  async getAllUsers(): Promise<UserList[]> {
    const response = await apiClient.get<UserList[]>('/auth/users')
    return response.data
  },

  // Crear usuario (Admin)
  async createUser(request: RegisterRequest): Promise<User> {
    const response = await apiClient.post<User>('/auth/users', request)
    return response.data
  },

  // Actualizar usuario (Admin)
  async updateUser(userId: number, request: UpdateUserRequest): Promise<void> {
    await apiClient.put(`/auth/users/${userId}`, request)
  },

  // Desactivar usuario (Admin)
  async deleteUser(userId: number): Promise<void> {
    await apiClient.delete(`/auth/users/${userId}`)
  },

  // Listar roles
  async getRoles(): Promise<Rol[]> {
    const response = await apiClient.get<Rol[]>('/auth/roles')
    return response.data
  },
}

// ============================================================================
// Informe Diario GRIDO
// ============================================================================

export interface InformeGridoFila {
  fecha_operativa: string
  sucursal: number
  sucursal_rotulo: string
  orden_sucursal: number
  turno: number
  caja: number
  cajero: string
  horario: string
  horas: number
  kilos: number
  ventas: number
  tickets: number
  sv_activadas: number
  sv_aceptadas: number
  promos: number
  socios: number
  ventas_club: number
  /** Kilos vendidos a socios Club Grido: el %VCG se mide sobre kilos. */
  kilos_club: number
  anuladas: number
  dif_caja: number
  /** La caja atiende delivery (tabla CFG_CAJA_DELIVERY). */
  es_caja_delivery: boolean
  /** Clima en las horas del turno; null si no hay clima cargado. */
  sensacion_termica: number | null
  lluvia_mm: number | null
  /** Clima de la sucursal en toda la jornada: es lo que va en el subtotal. */
  suc_sensacion_termica: number | null
  suc_lluvia_mm: number | null
}

export const informeGridoApi = {
  /**
   * Filas del informe para un rango de jornadas. Las fechas van en formato
   * YYYY-MM-DD; la jornada va de 02:00 a 02:00.
   */
  async getInforme(desde: string, hasta: string): Promise<InformeGridoFila[]> {
    const response = await apiClient.get<InformeGridoFila[]>('/ventas/informe-grido', {
      params: { desde, hasta },
    })
    return response.data
  },
}

// ---------------------------------------------------------------------------
// Estadistica de Ventas (replica de la pantalla homonima de SmartFran)
// ---------------------------------------------------------------------------

export interface EstadisticaTotales {
  venta_total: number
  tickets: number
  ticket_promedio: number
  cantidad: number
  descuentos: number
  /** Unidades vendidas en promocion, no cantidad de lineas. */
  promos: number
  kilos: number
  costo: number
  /** Venta - Costo de mercaderia. Es la "Utilidad" de SmartFran. */
  utilidad: number
  /** Utilidad menos insumos. Indicador propio, no existe en SmartFran. */
  contrib_marginal: number
  tickets_anulados: number
  sv_activadas: number
  sv_aceptadas: number
  sv_importe: number
  sv_kilos: number
  /**
   * Total cobrado (= Cierres de Turno de SmartFran e Informe Diario).
   * venta_total - desc_plataformas - otros_ajustes = venta_neta.
   * Las tres llegan null con filtro de articulo, grupo o tipo de producto.
   */
  venta_neta: number | null
  /** Descuento de PedidosYa / Rappi: las lineas no lo restan, el cobrado si. */
  desc_plataformas: number | null
  /** Otras diferencias lineas / cobrado (canjes, centavos). Casi siempre ~0. */
  otros_ajustes: number | null
}

export interface EstadisticaFila {
  detalle: string
  sucursal: number | null
  articulo: number | null
  venta: number
  porcentaje: number | null
  pedidos: number | null
  cantidad: number
  descuentos: number | null
  promos: number | null
  kilos: number | null
  costo: number | null
  utilidad: number | null
  pct_utilidad: number | null
  contrib_marginal: number | null
  pct_contrib: number | null
  /** Solo en el corte por sucursal; null en los demas. Ver EstadisticaTotales. */
  venta_neta: number | null
  desc_plataformas: number | null
  otros_ajustes: number | null
}

export interface EstadisticaDia {
  dia: string
  venta: number
  tickets: number
  kilos: number
  utilidad: number
  contrib_marginal: number
}

export interface EstadisticaDistribucion {
  tipo: 'HORA' | 'DIASEMANA' | 'MES' | 'CANAL' | 'ENTREGA'
  orden: number
  clave: string
  venta: number
  tickets: number
}

export interface EstadisticaMapaCalor {
  /** 1 = lunes .. 7 = domingo */
  dia_semana: number
  hora: number
  venta: number
  kilos: number
  tickets: number
}

/**
 * Venta cruzada con la temperatura. `franja` es el piso de un tramo de dos
 * grados: 24 significa "de 24 a 25,9".
 */
export interface EstadisticaClimaDia {
  franja: number
  /** 1 = lunes .. 7 = domingo */
  dia_semana: number
  venta: number
  kilos: number
  tickets: number
}

export interface EstadisticaClimaHora {
  franja: number
  hora: number
  venta: number
  kilos: number
  tickets: number
}

/** Cuanto vendio cada promocion en cada franja de temperatura. Top 25. */
export interface EstadisticaPromoClima {
  promocion: number
  detalle: string
  franja: number
  venta: number
  kilos: number
  tickets: number
}

export interface EstadisticaVentasRespuesta {
  totales: EstadisticaTotales
  por_sucursal: EstadisticaFila[]
  por_grupo: EstadisticaFila[]
  por_articulo: EstadisticaFila[]
  por_promocion: EstadisticaFila[]
  por_sobreventa: EstadisticaFila[]
  historia: EstadisticaDia[]
  distribuciones: EstadisticaDistribucion[]
  mapa_calor: EstadisticaMapaCalor[]
  clima_dia: EstadisticaClimaDia[]
  clima_hora: EstadisticaClimaHora[]
  promo_clima: EstadisticaPromoClima[]
}

export interface EstadisticaFiltros {
  /** Hora calendario, NO jornada comercial. Formato YYYY-MM-DDTHH:mm. */
  desde: string
  /** EXCLUSIVO: para ver hasta el 8 inclusive, mandar el 9 a las 00:00. */
  hasta: string
  sucursales?: string
  horaDesde?: number
  horaHasta?: number
  diasSemana?: string
  grupoProducto?: number
  tipoProducto?: string
  delivery?: number
  cajero?: string
  topArticulos?: number
}

// ---------------------------------------------------------------------------
// Fichero de Articulos (solo lectura)
// ---------------------------------------------------------------------------

export interface ArticuloFila {
  articulo: number
  codigo: string | null
  descripcion: string
  tipo: string | null
  grupo: number | null
  grupo_descrip: string | null
  estado: string | null
  precio: number | null
  costo: number | null
  unid_x_bulto: number | null
  peso: number | null
  /** Nulo si el articulo todavia no tiene codigo SAP cargado. */
  codigo_sap: string | null
}

export interface ArticuloDetalle {
  articulo: number
  codigo: string | null
  descripcion: string
  descrip_ticket: string | null
  tipo: string | null
  estado: string | null
  fecha_estado: string | null
  grupo: number | null
  grupo_descrip: string | null
  venta_publico: string | null
  iva_tasa: number | null
  orden: number | null
  proveedor: number | null
  unid_x_bulto: number | null
  stock_minimo: number | null
  peso: number | null
  costo: number | null
  precio_lista1: number | null
  precio_lista2: number | null
  precio_lista3: number | null
  precio_gastro1: number | null
  precio_gastro2: number | null
  precio_gastro3: number | null
}

export interface ArticuloReceta {
  orden: number
  /** GENERICO (una categoria, como HELADO) o ARTICULO (un insumo concreto). */
  clase: string
  componente: number
  descripcion: string | null
  cantidad: number
  /** Ya dividido por las unidades del bulto. Nulo para los genericos. */
  costo_unit: number | null
  costo_total: number | null
}

/**
 * Relacion con el codigo SAP de Grido Central. Es lo unico editable de la
 * ficha, y vive en el DWH: la base de origen se restaura entera todos los
 * dias y se llevaria puesto lo cargado.
 */
export interface ArticuloSap {
  codigo_sap: string | null
  descripcion_sap: string | null
  unidad_sap: string | null
  /** Cuantas unidades SAP equivalen a una unidad local. */
  factor_sap: number
  observaciones: string | null
  activo: boolean
  usuario_alta: string | null
  fecha_alta: string | null
  usuario_mod: string | null
  fecha_mod: string | null
}

export interface GuardarArticuloSap {
  codigo_sap: string
  descripcion_sap?: string | null
  unidad_sap?: string | null
  factor_sap: number
  observaciones?: string | null
  activo: boolean
}

export interface ArticuloFicha {
  detalle: ArticuloDetalle | null
  receta: ArticuloReceta[]
  /** Nulo si el articulo todavia no tiene codigo SAP cargado. */
  sap: ArticuloSap | null
}

export const ficheroArticulosApi = {
  async listar(p: { buscar?: string; tipo?: string; soloActivos?: boolean; top?: number } = {}) {
    const params: Record<string, string | number | boolean> = {
      soloActivos: p.soloActivos ?? true,
      top: p.top ?? 300,
    }
    if (p.buscar) params.buscar = p.buscar
    if (p.tipo) params.tipo = p.tipo
    const r = await apiClient.get<ArticuloFila[]>('/abm/articulos', { params })
    return r.data
  },

  async ficha(articulo: number) {
    const r = await apiClient.get<ArticuloFicha>(`/abm/articulos/${articulo}`)
    return r.data
  },

  async guardarSap(articulo: number, datos: GuardarArticuloSap) {
    const r = await apiClient.put<ArticuloSap>(`/abm/articulos/${articulo}/sap`, datos)
    return r.data
  },

  async borrarSap(articulo: number) {
    await apiClient.delete(`/abm/articulos/${articulo}/sap`)
  },
}

export const estadisticaVentasApi = {
  async getEstadistica(filtros: EstadisticaFiltros): Promise<EstadisticaVentasRespuesta> {
    // Los vacios no se mandan: el backend los trata como "todos" y asi la URL
    // queda legible cuando hay que depurar una consulta.
    const params: Record<string, string | number> = {
      desde: filtros.desde,
      hasta: filtros.hasta,
    }
    if (filtros.sucursales) params.sucursales = filtros.sucursales
    if (filtros.horaDesde !== undefined) params.horaDesde = filtros.horaDesde
    if (filtros.horaHasta !== undefined) params.horaHasta = filtros.horaHasta
    if (filtros.diasSemana) params.diasSemana = filtros.diasSemana
    if (filtros.grupoProducto) params.grupoProducto = filtros.grupoProducto
    if (filtros.tipoProducto) params.tipoProducto = filtros.tipoProducto
    if (filtros.delivery !== undefined) params.delivery = filtros.delivery
    if (filtros.cajero) params.cajero = filtros.cajero
    if (filtros.topArticulos) params.topArticulos = filtros.topArticulos

    const response = await apiClient.get<EstadisticaVentasRespuesta>('/ventas/estadistica', {
      params,
    })
    return response.data
  },
}

// ---------------------------------------------------------------------------
// Estrategia
//
// El resto de la app describe lo que paso. Esto propone que hacer: Damian
// declara un objetivo con una ventana, fija una meta por sucursal, y el motor
// cruza el pronostico con la elasticidad al clima medida sobre la huella.
//
// La meta va en PORCENTAJE sobre lo esperado para el clima de cada dia, no en
// pesos: un monto fijo mide el verano, no la gestion.
// ---------------------------------------------------------------------------

export type MetricaObjetivo = 'FACTURACION' | 'MARGEN' | 'KILOS'
export type EstadoObjetivo = 'VIGENTE' | 'CERRADO'
export type EstadoSugerencia = 'SUGERIDA' | 'ACEPTADA' | 'DESCARTADA' | 'VENCIDA'
export type TipoSugerencia = 'OPERATIVO' | 'PROMO' | 'SOBREVENTA' | 'MIX'

export interface ObjetivoFila {
  objetivo_id: number
  nombre: string
  metrica: MetricaObjetivo
  fecha_desde: string
  fecha_hasta: string
  estado: EstadoObjetivo
  notas: string | null
  creado_por: string | null
  creado_el: string
  /** Cuando se le aviso a los responsables. Nulo = todavia no salio el mail. */
  avisado_el: string | null
  sucursales: number
  sugerencias: number
  pendientes: number
  /** Negativo: la ventana ya paso y el objetivo sigue abierto. */
  dias_restantes: number
}

export interface ObjetivoSucursal {
  sucursal: number
  /** Meta en % sobre lo esperado para el clima, no en pesos. */
  meta_pct: number
  responsable: string | null
  mail: string | null
  notas: string | null
  /** Cuando se le aviso a ESTA sucursal. Nulo = todavia no. */
  avisado_el: string | null
  /**
   * El error tipico del modelo acumulado sobre una ventana de este largo. Es el
   * piso de lo medible: una meta por debajo no se distingue del ruido.
   */
  ruido_ventana_pct: number | null
}

export interface Sugerencia {
  sugerencia_id: number
  /** Nulo = aplica a todas las sucursales del objetivo. */
  sucursal: number | null
  /** Nulo = vale para toda la ventana, no para un dia puntual. */
  fecha: string | null
  tipo: TipoSugerencia
  titulo: string
  detalle: string | null
  /** El numero que respalda la sugerencia, congelado al generarla. */
  evidencia: string | null
  estado: EstadoSugerencia
  decidido_por: string | null
  decidido_el: string | null
  comentario: string | null
}

export interface ObjetivoDetalle {
  objetivo: ObjetivoFila | null
  sucursales: ObjetivoSucursal[]
  sugerencias: Sugerencia[]
}

export interface CrearObjetivo {
  nombre: string
  metrica: MetricaObjetivo
  /** YYYY-MM-DD */
  fecha_desde: string
  fecha_hasta: string
  notas?: string | null
  sucursales: Array<{
    sucursal: number
    meta_pct: number
    responsable?: string | null
    mail?: string | null
  }>
}

export interface PronosticoDia {
  sucursal: number
  dia: string
  /** 1 = lunes .. 7 = domingo */
  dia_semana: number
  tmax: number | null
  tmin: number | null
  /** Maxima de ayer: es lo que define el salto termico. */
  tmax_ayer: number | null
  llueve: number
  horas_lluvia: number
  lluvia_mm: number | null
  /**
   * Que porcentaje de la venta del dia cae en horas con lluvia.
   *
   * Es LA variable de lluvia, no `llueve`. Medido sobre 2024-2026, un dia con
   * menos del 10% expuesto no se distingue de uno seco, y uno con mas de la
   * mitad vende ~30% menos que un dia seco de la misma temperatura. Llover once
   * horas de madrugada y llover doce encima de la tarde son el mismo `llueve` y
   * dias opuestos.
   */
  exposicion: number | null
  /** 0 nada · 1 hasta 10% · 2 10-25% · 3 25-50% · 4 mas de 50% */
  tramo_lluvia: number | null
  /** Cuanto cuesta ese tramo contra un dia seco, en esa sucursal. */
  impacto_pct: number | null
  /** Dias de anticipacion. Mas alto, menos confiable. */
  anticipacion: number
}

/*
 * Medicion: objetivo contra realidad.
 *
 * El desvio nunca va solo: viaja con el ruido al lado. Un +8% sobre un modelo
 * que se equivoca +-10% no dice nada, y sin ese numero se leeria como un logro.
 */

export interface MedicionSucursal {
  sucursal: number
  meta_pct: number
  dias: number
  dias_cumplidos: number
  esperado: number
  real: number
  desvio_pct: number | null
  cumple: boolean
  /** Cuanto se equivoca el modelo en UN dia, tipicamente. */
  error_tipico_pct: number | null
  /** Lo mismo acumulado sobre la ventana. Es el piso de lo medible. */
  ruido_ventana_pct: number | null
  /** False cuando el desvio no se despega del ruido: no dice ni si ni no. */
  concluyente: boolean
}

export interface MedicionDia {
  sucursal: number
  fecha: string
  tmax: number | null
  tmax_ayer: number | null
  llovio: boolean | null
  /** Que porcentaje de la venta del dia cayo en horas con lluvia. */
  expos_lluvia: number | null
  factor_salto: number | null
  esperado: number | null
  real: number | null
  desvio_pct: number | null
  meta_pct: number | null
  cumple: boolean | null
  error_tipico_pct: number | null
  /** Con que precision se estimo. Un nivel flojo hay que verlo. */
  nivel_modelo: string | null
  calculado_el: string
}

export interface Medicion {
  sucursales: MedicionSucursal[]
  dias: MedicionDia[]
}

export interface AvisoSucursal {
  sucursal: number
  nombre: string
  mail: string | null
  enviado: boolean
  /** Cuantas acciones le tocaban. Cero explica un envio omitido. */
  acciones: number
  /** Por que no se envio, cuando no se envio. */
  motivo: string | null
}

export interface AvisoResultado {
  enviados: number
  omitidos: number
  detalle: AvisoSucursal[]
  objetivo: ObjetivoDetalle | null
}

export const estrategiaApi = {
  async listarObjetivos(p: { estado?: EstadoObjetivo; top?: number } = {}) {
    const params: Record<string, string | number> = { top: p.top ?? 50 }
    if (p.estado) params.estado = p.estado
    const r = await apiClient.get<ObjetivoFila[]>('/estrategia/objetivos', { params })
    return r.data
  },

  async obtenerObjetivo(objetivoId: number) {
    const r = await apiClient.get<ObjetivoDetalle>(`/estrategia/objetivos/${objetivoId}`)
    return r.data
  },

  async crearObjetivo(datos: CrearObjetivo) {
    const r = await apiClient.post<ObjetivoDetalle>('/estrategia/objetivos', datos)
    return r.data
  },

  /**
   * Rehace las sugerencias que nadie decidio todavia. Las aceptadas y
   * descartadas quedan como estan: son decisiones tomadas y sirven para medir.
   */
  async regenerar(objetivoId: number) {
    const r = await apiClient.post<ObjetivoDetalle>(
      `/estrategia/objetivos/${objetivoId}/sugerencias`,
    )
    return r.data
  },

  async decidir(sugerenciaId: number, estado: EstadoSugerencia, comentario?: string) {
    const r = await apiClient.put<Sugerencia>(`/estrategia/sugerencias/${sugerenciaId}`, {
      estado,
      comentario: comentario ?? null,
    })
    return r.data
  },

  async cerrar(objetivoId: number) {
    await apiClient.post(`/estrategia/objetivos/${objetivoId}/cerrar`)
  },

  /**
   * Manda a cada responsable las acciones aceptadas de su local.
   *
   * Con `prueba` el mail sale igual pero solo a la casilla de copia, y no
   * marca nada como avisado: sirve para ver como queda antes de mandarlo.
   */
  async avisar(objetivoId: number, prueba = false) {
    const r = await apiClient.post<AvisoResultado>(
      `/estrategia/objetivos/${objetivoId}/avisar`,
      null,
      { params: prueba ? { prueba: true } : {} },
    )
    return r.data
  },

  /** Lee la medicion que ya calculo la tarea diaria. No recalcula. */
  async medicion(objetivoId: number) {
    const r = await apiClient.get<Medicion>(`/estrategia/objetivos/${objetivoId}/medicion`)
    return r.data
  },

  /**
   * Recalcula la medicion ahora.
   *
   * Normalmente no hace falta: la tarea de las 12:30 la deja hecha. Sirve para
   * un objetivo recien creado sobre un periodo ya pasado, o cuando se recargo
   * una jornada vieja.
   */
  async recalcularMedicion(objetivoId: number) {
    const r = await apiClient.post<Medicion>(`/estrategia/objetivos/${objetivoId}/medicion`)
    return r.data
  },

  /**
   * URL del mail tal como lo va a recibir esa sucursal, sin enviarlo.
   *
   * Devuelve la direccion y no el contenido porque se abre en una pestana: un
   * mail se mira como mail, no como un bloque de HTML dentro de un modal.
   */
  vistaPreviaUrl(objetivoId: number, sucursal: number) {
    return `${API_BASE_URL}/estrategia/objetivos/${objetivoId}/aviso/vista-previa?sucursal=${sucursal}`
  },

  async pronostico(p: { sucursal?: number; dias?: number } = {}) {
    const params: Record<string, number> = { dias: p.dias ?? 7 }
    if (p.sucursal) params.sucursal = p.sucursal
    const r = await apiClient.get<PronosticoDia[]>('/estrategia/pronostico', { params })
    return r.data
  },
}
