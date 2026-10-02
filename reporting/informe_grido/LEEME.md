# Informe Diario GRIDO - Instrucciones

## Estado de la instalacion en WIN-6ARG3SUELOE (31/08/2026)

Ya esta todo instalado y verificado en este equipo:

| Componente | Estado | Ubicacion |
|------------|--------|-----------|
| Python 3.13.9 | Instalado | `C:\PILL-DF\_runtime\Python313\python.exe` |
| Entorno virtual de la app | Creado | `.venv\` (dentro de esta carpeta) |
| streamlit / pandas / pyodbc / openpyxl | Instalados | dentro del `.venv` |
| ODBC Driver 17 y 18 for SQL Server | Ya estaban instalados | sistema |
| Conectividad a la base de datos | **PENDIENTE** | ver seccion "Conexion" |

Nota: en este equipo no hay permisos de administrador y el instalador MSI de
Python esta bloqueado por politica (error 1625), por eso Python se instalo
como copia portable en `C:\PILL-DF\_runtime\Python313` (paquete NuGet oficial
de CPython). Funciona igual que una instalacion normal, pero **no esta en el
PATH**: siempre invocarlo por ruta completa o usar el `.bat`.

## Requisitos Previos

1. **Windows 10 o superior**
2. **Python 3.10 o superior** — ya instalado (ver tabla arriba)
3. **ODBC Driver 17 o 18 for SQL Server** — ya instalado
   - Descargar de: https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server
4. **Acceso de red al servidor de base de datos** — pendiente

## Como Ejecutar

1. Hacer doble clic en `EJECUTAR_INFORME.bat`
2. Abrir el navegador en http://localhost:8501 (suele abrirse solo)
3. Configurar la conexion a la base de datos en el panel izquierdo
4. Seleccionar la fecha del informe
5. Click en "Generar Informe"
6. Descargar el Excel generado

Para cerrar la app: `Ctrl+C` en la ventana negra del `.bat`.

### Recrear el entorno desde cero (si hiciera falta)

```
C:\PILL-DF\_runtime\Python313\python.exe -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
```

## Configuracion de Conexion

Valores que funcionan en este equipo (ya vienen precargados en el panel lateral):

| Parametro | Valor |
|-----------|-------|
| Servidor | `WIN-6ARG3SUELOE\SQLEXPRESS` (instancia local) |
| Base de Datos | `SRV_GRIDO_ZSUR` |
| Autenticacion | Windows (Trusted) |

La base es local (SQL Server 2025 Express corriendo en este mismo equipo) y esta
poblada: ~1.9M filas en VENTAS con datos hasta el 31/08/2026. No hace falta red.

Nota: `PILLOWSRV001` / `Gestion_DB_Fernandez` (los valores originales del codigo)
**no son alcanzables** desde aca — ese nombre no resuelve. Si en el futuro hay que
apuntar a ese servidor, habra que resolver conectividad y credenciales aparte.

### Sucursales

| ID | Nombre | Se incluye |
|----|--------|------------|
| 1 | Lanus Oeste | Si |
| 2 | Escalada | Si |
| 3 | Fiorito | Si |
| 4 | Mayorista | No (excluida a proposito) |

## Archivos Incluidos

| Archivo | Descripcion |
|---------|-------------|
| `EJECUTAR_INFORME.bat` | Script para iniciar la aplicacion |
| `informe_grido.py` | Codigo fuente de la aplicacion |
| `requirements.txt` | Lista de dependencias Python |
| `LEEME.md` | Este archivo |

## Soporte

En caso de problemas, verificar:

1. Python esta instalado y en el PATH (abrir CMD y escribir: `python --version`)
2. ODBC Driver 17 esta instalado
3. Hay conectividad de red al servidor de base de datos
4. Las credenciales de acceso son correctas

---

*Generado automaticamente - Agosto 2026*
