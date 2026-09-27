# WebApp Central - instalacion en este servidor

Clonado de https://github.com/GitEmilianoRizzo/DF_AppWebCentral el 16/09/2026.

## Como se levanta

```
INICIAR_APP.bat
```

Abre dos ventanas. Despues:

| | |
|---|---|
| Aplicacion | http://localhost:3000 |
| API / Swagger | http://localhost:7100/swagger |
| Usuario | `admin@DFGroup.com` / `Admin123!` |

El frontend hace de proxy: lo que pida a `/api` lo reenvia al 7100, asi que
alcanza con abrir el 3000.

## Stack instalado

Nada quedo instalado a nivel maquina: **no hay permisos de administrador en
este equipo y no hay winget**, asi que se siguio la convencion que el proyecto
ya usaba para Python (runtimes portables bajo `C:\PILL-DF\_runtime`).

| | Version | Ubicacion |
|---|---|---|
| .NET SDK | 9.0.318 | `C:\PILL-DF\_runtime\dotnet` |
| Node.js | v24.21.0 + npm 11.19.0 | `C:\PILL-DF\_runtime\node` |
| Git (MinGit) | 2.55.0 | `C:\PILL-DF\_runtime\git` |
| Python | 3.13.9 (ya estaba) | `C:\PILL-DF\_runtime\Python313` |

Las tres primeras rutas se agregaron al PATH **del usuario**. Si abris una
consola nueva, `dotnet`, `node`, `npm` y `git` responden solos.

## Cambios que hubo que hacerle al codigo

### 1. Base de datos: `DF_DTW_APP` -> `DF_DTW`

El repo apuntaba a una base `DF_DTW_APP` en un servidor `PILLOWSRV001` que no
existe en este equipo. Se cambio a la instancia local y a `DF_DTW`:

- `backend/DFGroup.Api/appsettings.json`
- `backend/DFGroup.Api/appsettings.Development.json`
- 22 scripts de `database/scripts` y `database/migrations` (39 referencias)

```
Server=WIN-6ARG3SUELOE\SQLEXPRESS;Database=DF_DTW;Integrated Security=True;...
```

### 2. Bug: la cadena de Development nunca se aplicaba

`appsettings.Development.json` declaraba la cadena bajo la clave
**`DF_DTW_APP`**, pero `Program.cs` la lee como **`DFGroupDb`**:

```csharp
new SqlConnectionFactory(builder.Configuration.GetConnectionString("DFGroupDb")!)
```

O sea que el override de desarrollo se ignoraba y la app caia al
`PILLOWSRV001` de `appsettings.json`. Se renombro la clave a `DFGroupDb`.

## Convivencia con la huella de venta

`DF_DTW` ya contenia `TRX_HUELLA_VENTA` (1,28 M de filas, 2,8 GB) y las tablas
del clima, todas en el esquema **`dbo`**.

La app crea sus objetos en esquemas propios: `cfg`, `dim`, `fact`, `stg`, `api`,
`auth`, `log`. Se verifico antes de correr nada que **ningun script crea objetos
en `dbo`** y que todo lo destructivo (`DELETE`, `TRUNCATE`) apunta solo a
`fact` y `stg`. Las dos cosas conviven sin pisarse.

**Al agregar scripts nuevos, respetar esa separacion.** Un `CREATE TABLE dbo.X`
o un `DROP` sin esquema pone en riesgo la huella, que tarda ~40 minutos en
reconstruirse.

## Scripts de base que se corrieron

En orden, contra `DF_DTW`:

```
01, 02, 03, 04, 05, 09, 10, 11, 12, 13, 14, 15, 16
003, 010, 011, 020, 025, 026, 027
```

**No** se corrieron:

| Script | Motivo |
|---|---|
| `00_create_database.sql` | `DF_DTW` ya existe. Ademas intenta `READ_COMMITTED_SNAPSHOT ON`, que pide acceso exclusivo a la base (ver abajo). |
| `06`, `06b`, `07` | Datos demo de ventas ficticias. |
| `99_drop_or_reset_demo_data.sql` | Borra datos demo. |

Tres scripts (`03`, `12`, `020`) fallan con `Msg 1934` si se corren con sqlcmd
sin `-I`: crean indices filtrados y necesitan `QUOTED_IDENTIFIER ON`, que
sqlcmd no activa por defecto.

```
sqlcmd -S WIN-6ARG3SUELOE\SQLEXPRESS -E -C -d DF_DTW -b -I -i script.sql
```

## Pendiente

- **`READ_COMMITTED_SNAPSHOT`**: el script 00 lo activaria. Conviene, porque la
  app lee mientras la tarea `PILL_huellaventaDiaria` escribe, y evitaria
  bloqueos. Pero requiere que no haya ninguna otra conexion abierta a `DF_DTW`.
  Aplicarlo en una ventana tranquila:
  ```sql
  ALTER DATABASE DF_DTW SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
  ```
- **Los cambios estan solo en el clon local, sin commitear.** Si haces `git pull`
  van a entrar en conflicto con `appsettings.json` y los scripts SQL.
- **Espacio**: `DF_DTW` va por 3,5 GB de los 10 GB que permite SQL Express, y la
  huella crece ~1 GB por ano de historia.
- `services/parser-service` (Python, puerto 8000) no se levanto: la app lo usa
  solo para importar archivos.
