/* ===========================================================================
   Sesion de Extended Events para ver TODA llamada a usp_EstadisticaVentas.

   POR QUE
   -------
   El log de la API no guarda la query string, y muestrear
   sys.dm_exec_requests cada 2 segundos se pierde las consultas rapidas: una
   corrida de 694 ms no aparece nunca. Extended Events registra la ejecucion
   entera, dure lo que dure, con los parametros reales que mando la pantalla.

   Es liviana: filtra por el nombre del SP, asi que no registra nada mas que
   estas llamadas.

   Para leerla:  ver el SELECT del final.
   Para apagarla: ALTER EVENT SESSION xe_EstadisticaVentas ON SERVER STATE=STOP;
   =========================================================================== */

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'xe_EstadisticaVentas')
    DROP EVENT SESSION xe_EstadisticaVentas ON SERVER;
GO

CREATE EVENT SESSION xe_EstadisticaVentas ON SERVER
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.sql_text)
    WHERE sqlserver.like_i_sql_unicode_string(statement, N'%EstadisticaVentas%')
),
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.sql_text)
    WHERE sqlserver.like_i_sql_unicode_string(batch_text, N'%EstadisticaVentas%')
),
ADD EVENT sqlserver.error_reported (
    ACTION (sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.sql_text)
    WHERE severity >= 11
)
ADD TARGET package0.ring_buffer (SET max_events_limit = 200)
WITH (MAX_DISPATCH_LATENCY = 2 SECONDS, STARTUP_STATE = OFF);
GO

ALTER EVENT SESSION xe_EstadisticaVentas ON SERVER STATE = START;
GO

PRINT 'Sesion xe_EstadisticaVentas iniciada.';
GO
