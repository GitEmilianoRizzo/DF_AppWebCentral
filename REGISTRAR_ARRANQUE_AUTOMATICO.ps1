<#
===============================================================================
 Arranque automatico de la WebApp Central al encender el servidor
===============================================================================

 Registra tres tareas programadas:

   DF WebApp - Deploy 7100      la app PRODUCTIVA, la que usa la gente
   DF WebApp - Dev API 7200     la API de desarrollo (compilacion Debug)
   DF WebApp - Dev Front 3000   el frontend de desarrollo (Vite)

 HAY QUE CORRERLO ELEVADO, UNA SOLA VEZ
 --------------------------------------
 Crear tareas con disparador "al iniciar el sistema" requiere permisos de
 administrador. Abrir PowerShell como administrador y correr:

     Set-ExecutionPolicy -Scope Process Bypass -Force
     & 'C:\PILL-DF\APPs\00.00_WebApp_Central\REGISTRAR_ARRANQUE_AUTOMATICO.ps1'

 Es idempotente: si las tareas ya existen, las reemplaza.

 POR QUE S4U Y NO "INTERACTIVE"
 ------------------------------
 Las tareas que ya existian en este servidor (GRIDO - Informe Diario,
 PILL_huellaventaDiaria, Restore SRV_GRIDO_ZSUR) estan en modo Interactive, que
 significa "corre solo si ese usuario tiene sesion abierta". Para un horario
 fijo con alguien siempre conectado alcanza; para arrancar despues de un
 reinicio no sirve, porque si nadie se loguea nunca arrancan.

 S4U (Service For User) corre aunque no haya sesion abierta y, a diferencia del
 modo con contrasena, NO guarda ninguna credencial. MayonesaOne es
 administrador local, asi que ya tiene el derecho "Log on as a batch job" que
 S4U necesita.

 LO QUE ESTE SCRIPT NO TOCA, A PROPOSITO
 ---------------------------------------
 Las tres tareas diarias siguen en modo Interactive. Convertirlas a S4U las
 haria sobrevivir a un reinicio desatendido, pero el Informe Diario copia el
 Excel al historico de Google Drive, y Drive vive en la sesion del usuario: sin
 sesion no habria unidad G: y esa copia fallaria. Cambiarlas sin resolver eso
 primero cambiaria un problema por otro peor, porque el segundo pasa
 desapercibido.

 Queda entonces esta limitacion conocida: si el servidor se reinicia y nadie
 inicia sesion, las aplicaciones web SI levantan, pero las tareas diarias de
 las 12:00, 12:30 y 13:00 NO corren.
===============================================================================
#>

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------- elevacion
$esAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
    Write-Host ''
    Write-Host '  Este script necesita permisos de administrador.' -ForegroundColor Yellow
    Write-Host '  Abri PowerShell con boton derecho -> "Ejecutar como administrador" y corre:'
    Write-Host ''
    Write-Host "      & '$PSCommandPath'" -ForegroundColor Cyan
    Write-Host ''
    exit 1
}

$base    = 'C:\PILL-DF\APPs\00.00_WebApp_Central'
$usuario = "$env:COMPUTERNAME\MayonesaOne"

$tareas = @(
    @{
        Nombre  = 'DF WebApp - Deploy 7100'
        Script  = "$base\SERVICIO_7100_Deploy.bat"
        Desc    = 'Aplicacion productiva de DF Group en el puerto 7100. Arranca al encender el servidor, despues de esperar a Tailscale y a SQL Server.'
        # Produccion primero y casi sin demora: el .bat ya espera a sus
        # dependencias por su cuenta, con reintentos.
        Retraso = 'PT30S'
    },
    @{
        Nombre  = 'DF WebApp - Dev API 7200'
        Script  = "$base\SERVICIO_7200_DevApi.bat"
        Desc    = 'API de desarrollo en 127.0.0.1:7200 (compilacion Debug). Se puede desactivar sin afectar a produccion.'
        # Detras de produccion: si el arranque viene pesado, que el puerto que
        # usa la gente sea el primero en quedar disponible.
        Retraso = 'PT2M'
    },
    @{
        Nombre  = 'DF WebApp - Dev Front 3000'
        Script  = "$base\SERVICIO_3000_DevFront.bat"
        Desc    = 'Frontend de desarrollo (Vite) en el puerto 3000, con proxy hacia la API de desarrollo del 7200.'
        # Ultimo: Vite no sirve de nada si su API todavia no levanto.
        Retraso = 'PT3M'
    }
)

Write-Host ''
foreach ($t in $tareas) {
    if (-not (Test-Path $t.Script)) { throw "Falta el lanzador: $($t.Script)" }

    if (Get-ScheduledTask -TaskName $t.Nombre -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t.Nombre -Confirm:$false
        Write-Host "  (se reemplaza la tarea que ya existia)" -ForegroundColor DarkGray
    }

    $accion = New-ScheduledTaskAction -Execute $t.Script -WorkingDirectory $base

    $disparador = New-ScheduledTaskTrigger -AtStartup
    $disparador.Delay = $t.Retraso

    $principal = New-ScheduledTaskPrincipal -UserId $usuario -LogonType S4U -RunLevel Limited

    # ExecutionTimeLimit 0 = sin limite. Son procesos que tienen que quedar
    # corriendo, no tareas que terminan: con el limite por defecto de 72 horas
    # el Programador los mataria cada tres dias.
    #
    # RestartCount/RestartInterval: si el proceso se cae, se reintenta tres
    # veces. No reemplaza entender por que se cayo, pero evita que la app quede
    # abajo todo un fin de semana por algo transitorio.
    #
    # IgnoreNew: si la tarea ya esta corriendo, no se lanza una segunda
    # instancia. Dos procesos peleando por el mismo puerto es peor que uno.
    $opciones = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 2) `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $t.Nombre -Description $t.Desc `
        -Action $accion -Trigger $disparador -Principal $principal `
        -Settings $opciones | Out-Null

    Write-Host "  OK  $($t.Nombre)   (retraso al arrancar: $($t.Retraso))" -ForegroundColor Green
}

Write-Host ''
Write-Host '=== tareas registradas ===' -ForegroundColor Cyan
Get-ScheduledTask | Where-Object { $_.TaskName -like 'DF WebApp*' } | ForEach-Object {
    $t = $_
    Write-Host ''
    Write-Host "  $($t.TaskName)"
    Write-Host "     estado     : $($t.State)"
    Write-Host "     usuario    : $($t.Principal.UserId)  ($($t.Principal.LogonType))"
    Write-Host "     disparador : al iniciar el sistema, retraso $($t.Triggers[0].Delay)"
    Write-Host "     lanzador   : $($t.Actions[0].Execute)"
}

Write-Host ''
Write-Host 'Para probarlas sin reiniciar, primero hay que bajar lo que este corriendo a mano.' -ForegroundColor Yellow
Write-Host 'Despues:  Start-ScheduledTask -TaskName "DF WebApp - Deploy 7100"'
Write-Host ''
Write-Host 'Para apagar desarrollo cuando no se este usando (son dos procesos mas en un'
Write-Host 'servidor con la memoria justa):'
Write-Host '  Disable-ScheduledTask -TaskName "DF WebApp - Dev API 7200"'
Write-Host '  Disable-ScheduledTask -TaskName "DF WebApp - Dev Front 3000"'
Write-Host ''
