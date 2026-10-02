# Informe Diario GRIDO - Ejecucion automatica

Version desatendida de la app: corre sola todos los dias, genera el Excel y lo
manda por mail. La version web (`EJECUTAR_INFORME.bat`) sigue funcionando igual
que antes, para pruebas manuales; las dos comparten la misma logica de consulta
y de armado del Excel, asi que no se pueden desincronizar.

## Que hace

Todos los dias a las **13:00**, la tarea programada de Windows
**"GRIDO - Informe Diario"**:

1. Calcula la fecha de ayer (`GETDATE() - 1`) y se la pasa a `informe_cli.py`
   como parametro `--fecha`. Esa es la **jornada comercial que el informe
   cubre**: el mail que llega el dia D trae las ventas del dia D-1.
2. Consulta `SRV_GRIDO_ZSUR` en la instancia local `WIN-6ARG3SUELOE\SQLEXPRESS`.
3. Genera el Excel en `salidas\YYYY-MM-DD_InformeDiarioGRIDO.xlsx`.
4. Lo envia por mail desde `backupautomatico1234@gmail.com`, con un resumen por
   sucursal en el cuerpo, a los destinatarios listados en `config.ini`:
   `emiliano.rizzo1@gmail.com`, `df.damianfernandez@gmail.com`,
   `gridoreferenteescalada@gmail.com` y `auxiliaradmgrido@gmail.com`.
5. **Despues de enviar el mail**, deja una copia del Excel en la carpeta
   compartida de Google Drive `Referentes`, para que quede el historico.
6. Deja el detalle de la corrida en `logs\informe_YYYY-MM-DD.log`.

### Alerta por desvio de %SV

En la columna **L (%SV)**, todo cajero por debajo del **15%** de sobreventas
aceptadas sale en rojo con texto blanco, con la leyenda del criterio en `A8`.

El estandar se cambia en un solo lugar: `UMBRAL_SV`, en `informe_grido.py`
(la regla y la leyenda lo leen de ahi). Va como formato condicional, no como
relleno fijo, asi que si alguien corrige aceptadas o activadas en el Excel el
color se recalcula solo. Un cajero sin sobreventas activadas queda **sin**
marcar: no es bajo rendimiento, es ausencia de dato.

### Sobre la copia a Google Drive

En `config.ini`, `[archivo] -> carpeta_historico`. Apunta al acceso directo
`G:\Other computers\Mi PC\Google Drive\Referentes.lnk`.

Google Drive representa las carpetas **compartidas** como archivos `.lnk`, no
como carpetas: no se puede copiar "dentro" de un `.lnk`. El script lo resuelve
solo en cada corrida (termina en
`G:\.shortcut-targets-by-id\<id>\Referentes`). Resolverlo en caliente y no
hardcodear el destino evita que se rompa si Drive cambia el id interno.

La copia va **despues** del mail a proposito: el envio es lo critico, y un
problema de Drive (no montado, sin permisos, sin espacio) no debe impedir que el
informe llegue. Si el mail sale pero la copia falla, la corrida termina con
codigo **5** y el log lo dice explicitamente.

Dejar `carpeta_historico` vacio desactiva la copia.

## Archivos

| Archivo | Para que sirve |
|---------|----------------|
| `informe_cli.py` | El proceso desatendido |
| `config.ini` | Servidor, base, casilla y destinatarios. **Contiene la contrasena** |
| `TAREA_INFORME_DIARIO.bat` | Lo que ejecuta la tarea programada |
| `logs\` | Un log por dia de ejecucion |
| `salidas\` | Los Excel generados |

## Que tuvo que configurarse a mano: la contrasena de aplicacion

Estar logueado en Gmail en el navegador **no alcanza** para que un script mande
mails. Google bloquea el acceso SMTP con la contrasena normal de la cuenta desde
2022. Hace falta una **contrasena de aplicacion**:

1. La cuenta `backupautomatico1234@gmail.com` debe tener la **verificacion en 2
   pasos activada** (sin eso, Google ni siquiera muestra la opcion).
2. Entrar a https://myaccount.google.com/apppasswords
3. Crear una con cualquier nombre (por ejemplo "Informe GRIDO").
4. Google devuelve 16 caracteres tipo `abcd efgh ijkl mnop`.
5. Pegarlos en `config.ini`, en `[correo] -> clave`. Los espacios no molestan.

Esa contrasena da acceso **solo a SMTP**, no a la cuenta entera, y se puede
revocar cuando se quiera desde la misma pagina sin cambiar la contrasena real.

## Uso manual

```
:: informe de ayer, generar y enviar
TAREA_INFORME_DIARIO.bat

:: una fecha puntual
TAREA_INFORME_DIARIO.bat 2026-08-30

:: probar sin mandar el mail
TAREA_INFORME_DIARIO.bat 2026-08-30 --sin-mail

:: probar SOLO el envio (mail corto, no consulta la base).
:: Es la forma rapida de validar la contrasena de aplicacion.
.venv\Scripts\python.exe informe_cli.py --probar-mail

:: mandar a otro destinatario
.venv\Scripts\python.exe informe_cli.py --fecha 2026-08-30 --a alguien@dominio.com
```

## Codigos de salida

| Codigo | Significado |
|--------|-------------|
| 0 | Todo bien |
| 1 | Error de configuracion o de parametros |
| 2 | Error de base de datos |
| 3 | Error al armar el Excel |
| 4 | Error al enviar el mail |
| 5 | El mail **si** se envio, pero fallo la copia al historico de Drive |

## Administrar la tarea

```powershell
# ver estado y ultima ejecucion
Get-ScheduledTaskInfo -TaskName "GRIDO - Informe Diario"

# ejecutarla ahora mismo
Start-ScheduledTask -TaskName "GRIDO - Informe Diario"

# desactivar / reactivar
Disable-ScheduledTask -TaskName "GRIDO - Informe Diario"
Enable-ScheduledTask  -TaskName "GRIDO - Informe Diario"
```

## Dos limitaciones a tener presentes

**1. La tarea solo corre con la sesion de Windows iniciada.** Para que corriera
tambien con el usuario deslogueado hace falta privilegio de administrador
(modo S4U), y esta sesion no lo tiene: Windows rechaza el cambio con "Access is
denied". En la practica, en un VPS al que se entra por RDP, alcanza con
**desconectar** la sesion en vez de **cerrar sesion** — una sesion desconectada
sigue activa y la tarea se ejecuta. Si algun dia se cierra sesion del todo, ese
dia no sale el informe. Con un usuario administrador esto se arregla en un
comando.

**2. Que periodo cubre el informe.** La app define el dia operativo como
*"desde las 02:00 de la fecha del informe hasta las 02:00 del dia siguiente"*.
La jornada comercial no coincide con el dia calendario porque el turno noche
cierra pasada la medianoche.

La consecuencia practica es que **la fecha que rotula el informe es la jornada
que el informe contiene**: el mail que llega el dia D dice "Fecha del informe:
D-1" y trae las ventas del D-1. Por ejemplo, el mail del 06/09 rotulado 05/09
cubre desde el 05/09 02:00 hasta el 06/09 02:00.

El calculo vive en un solo lugar, `rango_dia_operativo()` en
`informe_grido.py`, y lo usan tanto la app web como el proceso desatendido,
asi que no se pueden desincronizar.

> **Hasta el 07/09/2026 esto era distinto.** El rango se calculaba hacia atras
> (`fecha-1 02:00` a `fecha 02:00`) y la tarea ya pasaba la fecha de ayer, asi
> que las dos restas se encadenaban: el informe llegaba con la jornada del
> **D-2**. Los Excel en `salidas\` y en Drive **anteriores** a esa fecha estan
> corridos un dia respecto de su nombre: `2026-09-05_InformeDiarioGRIDO.xlsx`
> contiene la jornada del 04/09. Los generados desde el 07/09/2026 en adelante
> contienen la jornada de la fecha que llevan en el nombre.
