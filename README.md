# DF Group - Central de Informacion para Franquicias

Sistema de integracion y consolidacion de datos de ventas para la red de franquicias DF Group.

## Problema a Resolver

DF Group opera multiples franquicias, cada una utilizando diferentes sistemas POS, lo que dificulta:

- Consolidar datos de ventas en tiempo real
- Comparar rendimiento entre franquicias
- Obtener indicadores unificados para la direccion
- Identificar tendencias y oportunidades

## Objetivo del Sistema

Centralizar la informacion de ventas de todas las franquicias en una unica plataforma que permita:

1. **Ingesta automatizada**: Recibir datos via API o archivos JSON
2. **Dashboard ejecutivo**: Visualizar KPIs de venta consolidados
3. **Comparativas**: Analizar rendimiento entre franquicias, productos y personal
4. **Monitoreo**: Controlar el estado de integracion de cada franquicia

## Alcance Inicial (Demo)

### Incluido

- Indicadores de venta: bruto, neto, descuentos
- Metricas por franquicia, producto, mozo y tipo de plato
- Ocupacion y rotacion de mesas
- Estado de integracion por franquicia
- Franquicias demo para pruebas
- 30 dias de datos realistas

### Pendiente (Fase 2)

- Indicadores de rentabilidad y costos
- Gestion de inventarios
- Predicciones de demanda
- Conexion de franquicias reales

## Arquitectura

```
┌──────────────────────────────────────────────────────────────┐
│                      FRANQUICIAS                              │
│  Franquicia 1 │ Franquicia 2 │ Franquicia 3 │ ...            │
└─────┬─────────┬─────────┬───────────┬────────────────────────┘
      │         │         │           │
      ▼         ▼         ▼           ▼
┌──────────────────────────────────────────────────────────────┐
│                    INGESTA DE DATOS                           │
│  ┌──────────────┐              ┌──────────────┐              │
│  │  API POST    │              │  Archivo JSON │              │
│  │ /daily-batch │              │   (Drive)     │              │
│  └──────┬───────┘              └──────┬───────┘              │
└─────────┼────────────────────────────┼───────────────────────┘
          │                            │
          ▼                            ▼
┌──────────────────────────────────────────────────────────────┐
│                      BACKEND API                              │
│  • Validacion de datos                                        │
│  • Normalizacion                                              │
│  • Idempotencia                                               │
│  • Logging                                                    │
└─────────────────────────┬────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│                    SQL SERVER                                 │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐            │
│  │   dim   │ │  fact   │ │   stg   │ │   api   │            │
│  │ Moneda  │ │ Ticket  │ │  Batch  │ │ ApiKey  │            │
│  │ Franq.  │ │ Detalle │ │  Error  │ └─────────┘            │
│  │ Prod.   │ │ Pago    │ │  Log    │                         │
│  └─────────┘ └─────────┘ └─────────┘                         │
└─────────────────────────┬────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│                   FRONTEND DASHBOARD                          │
│  • KPIs consolidados                                          │
│  • Graficos interactivos                                      │
│  • Tablas de ranking                                          │
│  • Estado de integracion                                      │
└──────────────────────────────────────────────────────────────┘
```

## Tecnologias

| Componente | Tecnologia |
|------------|------------|
| Backend | ASP.NET Core 9.0, Dapper, FluentValidation |
| Frontend | React 18, TypeScript, Tailwind, Recharts |
| Base de Datos | SQL Server 2022 (DF_DTW_APP) |
| Documentacion | Swagger/OpenAPI |
| Deploy | Docker, Nginx |

## Estructura del Proyecto

```
00.00_WebApp_Central/
├── backend/
│   └── DFGroup.Api/       # API REST
├── frontend/               # Dashboard React
├── database/
│   └── scripts/           # Scripts SQL manuales
├── docs/
│   └── integration/       # Contratos y ejemplos JSON
├── docker-compose.yml     # Demo local
├── docker-compose.prod.yml  # Produccion
├── DEPLOY.md              # Guia de deploy
└── README.md              # Este archivo
```

## Inicio Rapido

### Requisitos

- Docker y Docker Compose
- SQL Server (externo o contenedor)

### Demo Local

```bash
# 1. Clonar repositorio
git clone [url] && cd 00.00_WebApp_Central

# 2. Configurar variables
cp .env.example .env

# 3. Levantar servicios
docker-compose up -d

# 4. Ejecutar scripts SQL manualmente
# (Ver seccion "Base de Datos" abajo)

# 5. Abrir dashboard
open http://localhost:3000
```

### Base de Datos

Los scripts SQL deben ejecutarse manualmente en orden:

```bash
# Conectar a SQL Server y ejecutar:
1. database/scripts/00_create_database.sql
2. database/scripts/01_create_schemas.sql
3. database/scripts/02_create_tables.sql
4. database/scripts/03_create_constraints_indexes.sql
5. database/scripts/04_create_views_dashboard.sql
6. database/scripts/05_create_stored_procedures_ingestion.sql
7. database/scripts/06_seed_demo_data.sql
8. database/scripts/06b_seed_extended_products.sql
9. database/scripts/07_seed_realistic_sales_data.sql
```

## Endpoints Principales

| Metodo | Endpoint | Descripcion |
|--------|----------|-------------|
| POST | `/api/v1/sales/daily-batch` | Enviar batch de ventas |
| GET | `/api/v1/dashboard/home` | Dashboard principal |
| GET | `/api/v1/dashboard/ventas/por-franquicia` | Ventas por franquicia |
| GET | `/api/v1/dashboard/ventas/por-producto` | Ranking de productos |
| GET | `/api/v1/dashboard/integraciones/estado-franquicias` | Estado de integracion |

Documentacion completa: `http://localhost:5000/swagger`

## Integracion de Franquicias

### Proceso de Integracion

1. **Solicitar API Key**: Central genera API Key para la franquicia
2. **Revisar contrato**: Ver `docs/integration/dfgroup_daily_sales_batch_contract.md`
3. **Desarrollar exportador**: Generar JSON diario desde el POS
4. **Enviar datos**: POST a `/api/v1/sales/daily-batch`
5. **Verificar estado**: GET a `/api/v1/sales/daily-batch/{batchId}/status`

### Ejemplo de Envio

```bash
curl -X POST http://api.dfgroup.com/api/v1/sales/daily-batch \
  -H "Content-Type: application/json" \
  -H "X-API-KEY: DF-FRANQUICIA-XXX-2026" \
  -d @ventas_2026-07-15.json
```

### Datos Obligatorios vs Opcionales

| Campo | Obligatorio | Opcional |
|-------|-------------|----------|
| batch_id | Si | - |
| business_date | Si | - |
| franchise_code | Si | - |
| tickets[].ticket_id | Si | - |
| tickets[].items[] | Si | - |
| tickets[].service.covers | - | Si |
| tickets[].service.waiter_id | - | Si |
| tickets[].discounts[] | - | Si |

## Roadmap

### Fase 1: Demo (Actual)

- [x] Modelo de datos SQL Server
- [x] API de ingesta
- [x] Dashboard basico
- [x] Franquicias demo

### Fase 2: Piloto

- [ ] Conectar franquicias reales
- [ ] Validar flujo completo
- [ ] Ajustar segun feedback

### Fase 3: Expansion

- [ ] Conectar todas las franquicias
- [ ] Automatizar ingesta por archivo (Drive)
- [ ] Alertas y notificaciones

### Fase 4: Analisis Avanzado

- [ ] Indicadores de rentabilidad
- [ ] Costos por producto
- [ ] Predicciones de demanda

## Supuestos

1. Las franquicias pueden exportar datos en formato JSON
2. Se dispone de conectividad para envios diarios
3. Los sistemas POS pueden configurarse para exportacion automatica
4. Central gestiona las API Keys de cada franquicia

## Riesgos

| Riesgo | Mitigacion |
|--------|------------|
| Franquicia sin capacidad tecnica | Proveer plantilla Excel alternativa |
| Datos inconsistentes | Validaciones y warnings en API |
| Caida de conectividad | Soporte para carga manual de archivos |
| Volumenes altos | Arquitectura preparada para escalar |

## Contacto

- **Proyecto**: DF Group - Central de Franquicias
- **Cliente**: DF Group (Damian Fernandez)
- **Desarrollador**: PILLOW
