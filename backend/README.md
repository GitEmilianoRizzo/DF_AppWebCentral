# DF Group - Backend API

API REST para integracion de ventas de franquicias de DF Group.

## Stack Tecnologico

- ASP.NET Core 8.0
- Dapper (acceso a datos)
- SQL Server
- FluentValidation
- Swagger/OpenAPI
- Serilog (logging)

## Requisitos

- .NET 8.0 SDK
- SQL Server con la base de datos DF_DTW_APP creada
- Scripts SQL ejecutados (ver `/database/scripts`)

## Configuracion

### Connection String

Editar `appsettings.json` o usar variables de entorno:

```json
{
  "ConnectionStrings": {
    "DF_DTW_APP": "Server=localhost;Database=DF_DTW_APP;User Id=sa;Password=TuPassword;TrustServerCertificate=True"
  }
}
```

O usar variable de entorno:
```bash
export ConnectionStrings__DF_DTW_APP="Server=..."
```

## Ejecucion Local

```bash
cd backend/DFGroup.Api

# Restaurar dependencias
dotnet restore

# Ejecutar en desarrollo
dotnet run

# O con watch (recarga automatica)
dotnet watch run
```

La API estara disponible en:
- http://localhost:5000
- Swagger UI: http://localhost:5000/swagger

## Endpoints Principales

### Ingesta de Ventas

| Metodo | Endpoint | Descripcion |
|--------|----------|-------------|
| POST | `/api/v1/sales/daily-batch` | Enviar batch diario de ventas |
| GET | `/api/v1/sales/daily-batch/{batchId}/status` | Consultar estado de batch |

### Dashboard

| Metodo | Endpoint | Descripcion |
|--------|----------|-------------|
| GET | `/api/v1/dashboard/home` | Dashboard principal |
| GET | `/api/v1/dashboard/ventas/resumen` | Resumen diario |
| GET | `/api/v1/dashboard/ventas/por-franquicia` | Ventas por franquicia |
| GET | `/api/v1/dashboard/ventas/por-producto` | Ranking de productos |
| GET | `/api/v1/dashboard/ventas/por-mozo` | Ranking de mozos |
| GET | `/api/v1/dashboard/ventas/por-tipo-plato` | Por categoria |
| GET | `/api/v1/dashboard/ventas/ocupacion-mesas` | Ocupacion mesas |
| GET | `/api/v1/dashboard/integraciones/estado-franquicias` | Estado integracion |

### Integracion

| Metodo | Endpoint | Descripcion |
|--------|----------|-------------|
| GET | `/api/v1/integration/schema/daily-sales-batch` | JSON Schema |
| GET | `/health` | Health check |

## Autenticacion

Los endpoints de ingesta requieren una API Key en el header:

```
X-API-KEY: DF-DEMO-PARAGUAY-ASU01-2026
```

API Keys demo disponibles:
- `DF-DEMO-PARAGUAY-ASU01-2026` (Paraguay Asuncion)
- `DF-DEMO-MIAMI-01-2026` (Miami Beach)

## Ejemplo de Uso

### Enviar Batch de Ventas

```bash
curl -X POST http://localhost:5000/api/v1/sales/daily-batch \
  -H "Content-Type: application/json" \
  -H "X-API-KEY: DF-DEMO-PARAGUAY-ASU01-2026" \
  -d @docs/integration/DFGroup_daily_sales_batch_example.json
```

### Consultar Estado

```bash
curl http://localhost:5000/api/v1/sales/daily-batch/DF-PARAGUAY-ASU01-20260714-001/status \
  -H "X-API-KEY: DF-DEMO-PARAGUAY-ASU01-2026"
```

### Obtener Dashboard

```bash
curl http://localhost:5000/api/v1/dashboard/home
```

## Estructura del Proyecto

```
backend/DFGroup.Api/
├── Controllers/        # Controladores API
├── Models/
│   └── DTOs/          # Data Transfer Objects
├── Services/          # Logica de negocio
├── Repositories/      # Acceso a datos
├── Validators/        # Validaciones FluentValidation
├── Middleware/        # Middleware personalizado
├── Configuration/     # Configuracion
├── Program.cs         # Entry point
└── appsettings.json   # Configuracion
```

## Docker

```bash
# Desde la raiz del proyecto
docker build -t DFGroup-api -f backend/DFGroup.Api/Dockerfile .

docker run -p 5000:8080 \
  -e ConnectionStrings__DF_DTW_APP="Server=host.docker.internal;..." \
  DFGroup-api
```

## Logging

Los logs se escriben en:
- Consola
- Archivos en `logs/DFGroup-YYYY-MM-DD.log`

Configurar nivel en `appsettings.json`:
```json
{
  "Serilog": {
    "MinimumLevel": {
      "Default": "Information"
    }
  }
}
```

## Tests

```bash
dotnet test
```
