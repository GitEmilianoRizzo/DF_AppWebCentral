<#
===============================================================================
 Auditar-Ventas.ps1
-------------------------------------------------------------------------------
 Auditoria de montos del modulo de ventas. Cruza, por jornada y sucursal, las
 cinco fuentes que muestran ventas y exige que toda diferencia entre ellas
 este EXPLICADA. Lo usa el agente AgenteAuditoriaVentas despues de cada cambio
 en el modulo, y se puede correr a mano.

 POR QUE EXISTE
 --------------
 Escalada 26/09: el Informe Diario daba 1.298.360, Estadistica 1.354.140 y
 SmartFran 2.894.550 / 2.950.330. Habia DOS problemas mezclados (una carga a
 medias y un descuento de plataformas) y separarlos llevo horas. Este script
 hace esa separacion solo, todos los dias, antes de que lo vea el cliente.

 FUENTES
 -------
   ORIGEN       SRV_GRIDO_ZSUR (SmartFran), leido directo
   HUELLA       DF_DTW.dbo.TRX_HUELLA_VENTA
   AGREGADO     DF_DTW.dbo.AGG_VENTA_DIA
   INFORME      dbo.usp_InformeDiarioGrido      (el SP real de la pantalla)
   ESTADISTICA  dbo.usp_EstadisticaVentas       (el SP real de la pantalla)
 Los informes se auditan ejecutando SUS PROPIOS SP, no una copia de la
 formula: si alguien cambia un SP, el cambio queda auditado.

 CONTROLES (por jornada y sucursal)
 ---------------------------------
   C1 ORIGEN = HUELLA        tickets, total de cabecera y suma de lineas
   C2 HUELLA = AGREGADO      tickets e importe
   C3 INFORME = HUELLA       ventas (cabecera) y tickets
   C4 ESTADISTICA = HUELLA   venta (lineas) y tickets
   C5 PUENTE                 Estadistica suma lineas y el Informe suma el total
                             del ticket. Se reconstruye la diferencia TICKET
                             POR TICKET en el origen y se exige que:
                             a) ESTADISTICA - INFORME = suma de esas
                                diferencias (si no, FALLA: los informes no
                                salen de los mismos tickets), y
                             b) cada ticket con diferencia tenga causa. La
                                causa conocida es el descuento de plataforma
                                (diferencia = pedidos.descuento). Los demas
                                se listan uno por uno como AVISO, con numero
                                de venta, para que ninguna diferencia quede
                                sin identificar.
                             OJO: NO alcanza con sumar pedidos.descuento del
                             dia. Medido en septiembre 2026: 153 pedidos
                             traen descuento pero sus lineas ya lo reflejan,
                             y sumarlos inventaba restos de miles de pesos.
   C6 PROMOS                 Promos del INFORME = lineas en promocion de la huella
   C7 KILOS                  INFORME = ESTADISTICA = HUELLA
   C9 VENTA NETA             las columnas Venta neta / Desc. plataformas de
                             Estadistica = cobrado de la huella / puente C5,
                             y Venta - Desc - Otros = Neta
   C8 CAJA SILENCIOSA        una caja que vendio en los 14 dias previos y no
                             tiene ninguna venta en la jornada (aviso: suele
                             ser una caja que no sincronizo con el central)

 VENTANA
 -------
 Jornada comercial D = [D 02:00, D+1 02:00). Estadistica se llama con
 exactamente esa ventana para que los universos sean el mismo; con su
 default (hora calendario) no serian comparables.

 SALIDA
 ------
   codigo 0  todo cuadra
   codigo 1  hay FALLAS (numeros que no cuadran o diferencias sin explicar)
   codigo 2  solo AVISOS (cajas silenciosas)
 Con -Json devuelve el detalle en JSON para que lo procese el agente.

 USO
 ---
   .\Auditar-Ventas.ps1                         # ultimos 7 dias hasta ayer
   .\Auditar-Ventas.ps1 -Desde 2026-09-26 -Hasta 2026-09-26
   .\Auditar-Ventas.ps1 -Dias 30 -Json

 Solo lectura: no escribe nada en ninguna base.

 Creado: 2026-10-01
===============================================================================
#>
param(
    [datetime]$Desde,
    [datetime]$Hasta,
    [int]$Dias = 7,
    [string]$Servidor = 'WIN-6ARG3SUELOE\SQLEXPRESS',
    [string]$BaseDwh = 'DF_DTW',
    [string]$BaseOrigen = 'SRV_GRIDO_ZSUR',
    # La sucursal 4 (Mayorista) no esta en el Informe Diario.
    [int[]]$SucursalesFueraInforme = @(4),
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

if (-not $Hasta) { $Hasta = (Get-Date).Date.AddDays(-1) }
if (-not $Desde) { $Desde = $Hasta.AddDays(1 - $Dias) }
$Desde = $Desde.Date; $Hasta = $Hasta.Date
if ($Desde -gt $Hasta) { throw 'Desde no puede ser posterior a Hasta.' }

# Tolerancias. Los montos de origen son money (4 decimales) y la huella
# redondea por linea: un peso alcanza. Los kilos del Informe vienen
# redondeados a 0,1 por turno, asi que la tolerancia crece con los turnos.
$TOL_PESOS = 1.0
$TOL_KILOS_POR_TURNO = 0.06

$cs = "Server=$Servidor;Database=$BaseDwh;Integrated Security=True;TrustServerCertificate=True;Application Name=AuditoriaVentas"
$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()

function Consultar([string]$sql, [hashtable]$p = @{}) {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300
    foreach ($k in $p.Keys) { [void]$cmd.Parameters.AddWithValue($k, $p[$k]) }
    $ds = New-Object System.Data.DataSet
    [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($ds)
    , $ds
}
function EjecutarSP([string]$nombre, [hashtable]$p) {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $nombre; $cmd.CommandType = 'StoredProcedure'; $cmd.CommandTimeout = 300
    foreach ($k in $p.Keys) { [void]$cmd.Parameters.AddWithValue($k, $p[$k]) }
    $ds = New-Object System.Data.DataSet
    [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($ds)
    , $ds
}
function D($v) { if ($v -is [DBNull] -or $null -eq $v) { 0.0 } else { [double]$v } }

$hallazgos = New-Object System.Collections.Generic.List[object]
function Hallazgo($fecha, $suc, $control, $nivel, $detalle, $a, $b) {
    $hallazgos.Add([pscustomobject]@{
        Fecha = $fecha.ToString('yyyy-MM-dd'); Sucursal = $suc; Control = $control; Nivel = $nivel
        Detalle = $detalle; ValorA = [math]::Round($a, 2); ValorB = [math]::Round($b, 2); Diferencia = [math]::Round($a - $b, 2)
    })
}
function Comparar($fecha, $suc, $control, $etiqueta, $a, $b, $tol) {
    if ([math]::Abs($a - $b) -gt $tol) { Hallazgo $fecha $suc $control 'FALLA' $etiqueta $a $b }
}

$sqlOrigen = @"
SELECT v.SUCURSAL,
       tickets  = SUM(CASE WHEN v.VTAESTADO = 'NORMAL' THEN 1 ELSE 0 END),
       cabecera = SUM(CASE WHEN v.VTAESTADO = 'NORMAL' THEN v.VTAIMPORTE ELSE 0 END)
FROM [$BaseOrigen].dbo.VENTAS v
WHERE v.VTAFECHA >= @d AND v.VTAFECHA < @h
GROUP BY v.SUCURSAL;

-- Misma regla de linea facturable que la carga de la huella.
SELECT v.SUCURSAL, lineas = SUM(d.CANT * d.PRECIO)
FROM [$BaseOrigen].dbo.VENTAS v
JOIN [$BaseOrigen].dbo.DETVENTAS d ON d.VENTA = v.VENTA AND d.SUCURSAL = v.SUCURSAL AND d.CAJA = v.CAJA
WHERE v.VTAFECHA >= @d AND v.VTAFECHA < @h AND v.VTAESTADO = 'NORMAL' AND d.PROMO <> 2
GROUP BY v.SUCURSAL;

-- Tickets cuya suma de lineas no coincide con el total de cabecera, con la
-- causa. PLATAFORMA = pedido de PedidosYa/Rappi cuyo descuento es exactamente
-- la diferencia: el total cobrado lo descuenta y las lineas no.
SELECT t.SUCURSAL, t.CAJA, t.VENTA, t.VTAFECHA, t.VTAOPERACION, t.VTAIMPORTE, t.lineas,
       dif = t.lineas - t.VTAIMPORTE, desc_pedido = p.descuento,
       causa = CASE WHEN p.descuento IS NOT NULL AND ABS((t.lineas - t.VTAIMPORTE) - p.descuento) < 0.05
                    THEN 'PLATAFORMA' ELSE 'SIN CAUSA CONOCIDA' END
FROM (SELECT v.SUCURSAL, v.CAJA, v.VENTA, v.VTAFECHA, v.VTAOPERACION, v.VTAIMPORTE,
             lineas = SUM(CASE WHEN d.PROMO <> 2 THEN d.CANT * d.PRECIO ELSE 0 END)
      FROM [$BaseOrigen].dbo.VENTAS v
      JOIN [$BaseOrigen].dbo.DETVENTAS d ON d.VENTA = v.VENTA AND d.SUCURSAL = v.SUCURSAL AND d.CAJA = v.CAJA
      WHERE v.VTAFECHA >= @d AND v.VTAFECHA < @h AND v.VTAESTADO = 'NORMAL'
      GROUP BY v.SUCURSAL, v.CAJA, v.VENTA, v.VTAFECHA, v.VTAOPERACION, v.VTAIMPORTE) t
OUTER APPLY (SELECT TOP 1 pd.descuento FROM [$BaseOrigen].dbo.pedidos pd
             WHERE pd.Venta = t.VENTA AND pd.sucursal = t.SUCURSAL AND pd.caja = t.CAJA
             ORDER BY pd.idPedido DESC) p
WHERE ABS(t.lineas - t.VTAIMPORTE) >= 0.05;

-- Cajas que vendieron en los 14 dias previos y no en la jornada.
SELECT x.SUCURSAL, x.CAJA, ultima = MAX(x.VTAFECHA)
FROM [$BaseOrigen].dbo.VENTAS x
WHERE x.VTAFECHA >= DATEADD(day, -14, @d) AND x.VTAFECHA < @d
  AND NOT EXISTS (SELECT 1 FROM [$BaseOrigen].dbo.VENTAS y
                  WHERE y.SUCURSAL = x.SUCURSAL AND y.CAJA = x.CAJA
                    AND y.VTAFECHA >= @d AND y.VTAFECHA < @h)
GROUP BY x.SUCURSAL, x.CAJA;
"@

$sqlHuella = @"
SELECT t.SUCURSAL,
       tickets  = SUM(CASE WHEN t.anulada = 0 THEN 1 ELSE 0 END),
       cabecera = SUM(CASE WHEN t.anulada = 0 THEN t.cab ELSE 0 END),
       lineas   = SUM(CASE WHEN t.anulada = 0 THEN t.lin ELSE 0 END),
       promos   = SUM(CASE WHEN t.anulada = 0 THEN t.pro ELSE 0 END),
       kilos    = SUM(CASE WHEN t.anulada = 0 THEN t.kg  ELSE 0 END)
FROM (SELECT h.SUCURSAL, h.TICKET_KEY,
             anulada = MAX(CAST(h.ES_ANULADA AS int)),
             cab = MAX(h.VTAIMPORTE),
             lin = SUM(h.IMPORTE),
             pro = SUM(CASE WHEN h.LINEA_ES_PROMOCION = 1 THEN h.IMPORTE ELSE 0 END),
             kg  = SUM(h.KILOS)
      FROM dbo.TRX_HUELLA_VENTA h
      WHERE h.BASE_ORIGEN = @base AND h.FECHA_OPERATIVA = @f
      GROUP BY h.SUCURSAL, h.TICKET_KEY) t
GROUP BY t.SUCURSAL;

SELECT SUCURSAL, TICKETS, IMPORTE FROM dbo.AGG_VENTA_DIA WHERE BASE_ORIGEN = @base AND FECHA = @f;
"@

$resumen = New-Object System.Collections.Generic.List[object]

for ($f = $Desde; $f -le $Hasta; $f = $f.AddDays(1)) {
    $d = $f.AddHours(2); $h = $f.AddDays(1).AddHours(2)

    $o = Consultar $sqlOrigen @{ '@d' = $d; '@h' = $h }
    $hu = Consultar $sqlHuella @{ '@f' = $f; '@base' = $BaseOrigen }
    $inf = EjecutarSP 'dbo.usp_InformeDiarioGrido' @{ '@FechaDesde' = $f; '@FechaHasta' = $f; '@BaseOrigen' = $BaseOrigen }
    $est = EjecutarSP 'dbo.usp_EstadisticaVentas' @{ '@FechaDesde' = $d; '@FechaHasta' = $h; '@BaseOrigen' = $BaseOrigen; '@TopArticulos' = 1 }

    $sucs = @($o.Tables[0].Rows | ForEach-Object { [int]$_.SUCURSAL }) + @($hu.Tables[0].Rows | ForEach-Object { [int]$_.SUCURSAL }) | Sort-Object -Unique

    foreach ($s in $sucs) {
        $or  = $o.Tables[0].Select("SUCURSAL = $s") | Select-Object -First 1
        $ol  = $o.Tables[1].Select("SUCURSAL = $s") | Select-Object -First 1
        $tkDif = @($o.Tables[2].Select("SUCURSAL = $s"))
        $hr  = $hu.Tables[0].Select("SUCURSAL = $s") | Select-Object -First 1
        $ag  = $hu.Tables[1].Select("SUCURSAL = $s") | Select-Object -First 1
        $er  = $est.Tables[1].Select("Sucursal = $s") | Select-Object -First 1
        $ir  = @($inf.Tables[0].Select("Sucursal = $s"))

        $O_tk = D $or.tickets; $O_cab = D $or.cabecera; $O_lin = D $ol.lineas
        $O_dif = ($tkDif | ForEach-Object { D $_.dif } | Measure-Object -Sum).Sum; if ($null -eq $O_dif) { $O_dif = 0 }
        $O_pla = ($tkDif | Where-Object { $_.causa -eq 'PLATAFORMA' } | ForEach-Object { D $_.dif } | Measure-Object -Sum).Sum; if ($null -eq $O_pla) { $O_pla = 0 }
        $sinCausa = @($tkDif | Where-Object { $_.causa -ne 'PLATAFORMA' })
        $H_tk = D $hr.tickets; $H_cab = D $hr.cabecera; $H_lin = D $hr.lineas; $H_pro = D $hr.promos; $H_kg = D $hr.kilos
        $A_tk = D $ag.TICKETS; $A_imp = D $ag.IMPORTE
        $E_vta = D $er.Venta; $E_tk = D $er.Pedidos; $E_kg = D $er.Kilos

        # C1 ORIGEN = HUELLA
        Comparar $f $s 'C1 ORIGEN=HUELLA' 'Tickets (origen vs huella)' $O_tk $H_tk 0
        Comparar $f $s 'C1 ORIGEN=HUELLA' 'Total de cabecera (origen vs huella)' $O_cab $H_cab $TOL_PESOS
        Comparar $f $s 'C1 ORIGEN=HUELLA' 'Suma de lineas (origen vs huella)' $O_lin $H_lin $TOL_PESOS

        # C2 HUELLA = AGREGADO
        Comparar $f $s 'C2 HUELLA=AGREGADO' 'Tickets (huella vs AGG_VENTA_DIA)' $H_tk $A_tk 0
        Comparar $f $s 'C2 HUELLA=AGREGADO' 'Importe (huella vs AGG_VENTA_DIA)' $H_lin $A_imp $TOL_PESOS

        # C4 ESTADISTICA = HUELLA
        Comparar $f $s 'C4 ESTADISTICA=HUELLA' 'Venta (Estadistica vs lineas de la huella)' $E_vta $H_lin $TOL_PESOS
        Comparar $f $s 'C4 ESTADISTICA=HUELLA' 'Tickets (Estadistica vs huella)' $E_tk $H_tk 0
        # C9 VENTA NETA: la columna "Venta neta" de Estadistica tiene que ser
        # el total cobrado (= Informe Diario = Cierres de Turno) y "Desc.
        # plataformas" el mismo que reconstruye el puente ticket por ticket.
        # Solo si el SP desplegado ya trae las columnas (desde 02/10/2026).
        if ($er -and $er.Table.Columns.Contains('VentaNeta')) {
            Comparar $f $s 'C9 VENTA NETA' 'Venta neta de Estadistica vs total cobrado de la huella' (D $er.VentaNeta) $H_cab $TOL_PESOS
            Comparar $f $s 'C9 VENTA NETA' 'Desc. plataformas de Estadistica vs puente ticket por ticket' (D $er.DescPlataformas) $O_pla $TOL_PESOS
            Comparar $f $s 'C9 VENTA NETA' 'Venta - Desc. plataformas - Otros ajustes vs Venta neta' ($E_vta - (D $er.DescPlataformas) - (D $er.OtrosAjustes)) (D $er.VentaNeta) 0.05
        }

        $I_vta = $null
        if ($SucursalesFueraInforme -notcontains $s) {
            $I_vta = ($ir | ForEach-Object { D $_.Ventas } | Measure-Object -Sum).Sum; if ($null -eq $I_vta) { $I_vta = 0 }
            $I_tk  = ($ir | ForEach-Object { D $_.Tickets } | Measure-Object -Sum).Sum; if ($null -eq $I_tk) { $I_tk = 0 }
            $I_pro = ($ir | ForEach-Object { D $_.Promos } | Measure-Object -Sum).Sum; if ($null -eq $I_pro) { $I_pro = 0 }
            $I_kg  = ($ir | ForEach-Object { D $_.Kilos } | Measure-Object -Sum).Sum; if ($null -eq $I_kg) { $I_kg = 0 }
            $tolKg = [math]::Max(0.1, $TOL_KILOS_POR_TURNO * $ir.Count)

            # C3 INFORME = HUELLA
            Comparar $f $s 'C3 INFORME=HUELLA' 'Ventas (Informe Diario vs cabecera de la huella)' $I_vta $H_cab $TOL_PESOS
            Comparar $f $s 'C3 INFORME=HUELLA' 'Tickets (Informe Diario vs huella)' $I_tk $H_tk 0

            # C5 PUENTE a): la brecha entre los dos informes tiene que ser
            # exactamente la suma de las diferencias de los tickets.
            if ([math]::Abs(($E_vta - $I_vta) - $O_dif) -gt $TOL_PESOS) {
                Hallazgo $f $s 'C5 PUENTE' 'FALLA' ("DIFERENCIA NO EXPLICADA: Estadistica - Informe = {0:N2}, pero los tickets del origen solo explican {1:N2}. Los informes no estan saliendo de los mismos tickets." -f ($E_vta - $I_vta), $O_dif) ($E_vta - $I_vta) $O_dif
            }
            # C5 PUENTE b): cada ticket con diferencia que no sea de plataforma
            # queda identificado con su numero, para que nadie lo tenga que buscar.
            foreach ($t in $sinCausa) {
                $hallazgos.Add([pscustomobject]@{
                    Fecha = $f.ToString('yyyy-MM-dd'); Sucursal = $s; Control = 'C5 PUENTE'; Nivel = 'AVISO'
                    Detalle = ("Ticket caja {0} venta {1} ({2:HH:mm}, operacion {3}): lineas {4:N2} vs total cobrado {5:N2}. No es descuento de plataforma{6}. Diferencia del origen, ya identificada." -f $t.CAJA, $t.VENTA, [datetime]$t.VTAFECHA, "$($t.VTAOPERACION)".Trim(), (D $t.lineas), (D $t.VTAIMPORTE), $(if ($t.desc_pedido -isnot [DBNull]) { " (el pedido declara descuento {0:N2})" -f (D $t.desc_pedido) } else { '' }))
                    ValorA = [math]::Round((D $t.lineas), 2); ValorB = [math]::Round((D $t.VTAIMPORTE), 2); Diferencia = [math]::Round((D $t.dif), 2)
                })
            }

            # C6 PROMOS
            Comparar $f $s 'C6 PROMOS' 'Promos (Informe Diario vs lineas en promocion de la huella)' $I_pro $H_pro $TOL_PESOS

            # C7 KILOS
            Comparar $f $s 'C7 KILOS' 'Kilos (Informe Diario vs huella)' $I_kg $H_kg $tolKg
            Comparar $f $s 'C7 KILOS' 'Kilos (Estadistica vs huella)' $E_kg $H_kg 0.01
        }

        $resumen.Add([pscustomobject]@{
            Fecha = $f.ToString('yyyy-MM-dd'); Sucursal = $s
            Tickets = $H_tk; Informe = if ($null -ne $I_vta) { [math]::Round($I_vta, 2) } else { $null }
            Estadistica = [math]::Round($E_vta, 2); DescPlataformas = [math]::Round($O_pla, 2)
            OtrasDif = [math]::Round($O_dif - $O_pla, 2)
        })
    }

    # C8 CAJA SILENCIOSA
    foreach ($c in $o.Tables[3].Rows) {
        $hallazgos.Add([pscustomobject]@{
            Fecha = $f.ToString('yyyy-MM-dd'); Sucursal = [int]$c.SUCURSAL; Control = 'C8 CAJA SILENCIOSA'; Nivel = 'AVISO'
            Detalle = "La caja $($c.CAJA) vendio en los 14 dias previos (ultima venta $(([datetime]$c.ultima).ToString('dd/MM HH:mm'))) y no tiene ninguna venta en la jornada. Probable falta de sincronizacion con el central."
            ValorA = 0; ValorB = 0; Diferencia = 0
        })
    }
}
$cn.Close()

$fallas = @($hallazgos | Where-Object Nivel -eq 'FALLA').Count
$avisos = @($hallazgos | Where-Object Nivel -eq 'AVISO').Count
$codigo = if ($fallas -gt 0) { 1 } elseif ($avisos -gt 0) { 2 } else { 0 }

if ($Json) {
    [pscustomobject]@{
        Desde = $Desde.ToString('yyyy-MM-dd'); Hasta = $Hasta.ToString('yyyy-MM-dd')
        Resultado = @('OK', 'FALLAS', 'AVISOS')[$codigo]; Fallas = $fallas; Avisos = $avisos
        Hallazgos = $hallazgos; Resumen = $resumen
    } | ConvertTo-Json -Depth 5
} else {
    "AUDITORIA DE VENTAS  {0:yyyy-MM-dd} a {1:yyyy-MM-dd}  ->  {2}  ({3} fallas, {4} avisos)" -f $Desde, $Hasta, @('OK', 'FALLAS', 'AVISOS')[$codigo], $fallas, $avisos
    ''
    'Resumen por jornada y sucursal (Estadistica - Informe = DescPlataformas + OtrasDif, ticket por ticket):'
    $resumen | Format-Table -AutoSize | Out-String -Width 200
    if ($hallazgos.Count -gt 0) {
        'Hallazgos:'
        $hallazgos | Sort-Object Nivel, Fecha, Sucursal | Format-Table Fecha, Sucursal, Nivel, Control, Diferencia, Detalle -AutoSize -Wrap | Out-String -Width 250
    }
}
exit $codigo
