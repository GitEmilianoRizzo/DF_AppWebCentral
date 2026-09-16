-- Update Miami Coconut to use FILE_PARSER and TOAST_HTML
UPDATE dim.NodoConexion
SET TipoConector = 'FILE_PARSER',
    ParserId = (SELECT ParserId FROM cfg.Parser WHERE Codigo = 'TOAST_HTML'),
    ConfiguracionJson = '{"connection_type":"TXT_PARSER","parser_code":"TOAST_HTML"}'
WHERE Codigo = 'NODO_MIAMI_COCONUT';

-- Create connection for Miami Sunny if not exists
IF NOT EXISTS (SELECT 1 FROM dim.NodoConexion WHERE Codigo = 'NODO_MIAMI_SUNNY')
BEGIN
    INSERT INTO dim.NodoConexion (Codigo, Nombre, FranquiciaId, TipoConector, Modo, Estado, Timezone, Moneda, ConvencionImportes, PoliticaDevoluciones, ToleranciaReconciliacion, Activo, ParserId, ConfiguracionJson)
    SELECT 'NODO_MIAMI_SUNNY', 'Conector Miami Sunny', f.FranquiciaId, 'FILE_PARSER', 'FILE', 'ACTIVE', 'America/New_York', 'USD', 'VAT_INCLUDED', 'NEGATIVE_LINES', 0.01, 1, p.ParserId, '{"connection_type":"TXT_PARSER","parser_code":"TOAST_HTML"}'
    FROM dim.Franquicia f, cfg.Parser p
    WHERE f.Codigo = 'MIAMI_SUNNY' AND p.Codigo = 'TOAST_HTML';
END

-- Create connection for Miami Midtown if not exists
IF NOT EXISTS (SELECT 1 FROM dim.NodoConexion WHERE Codigo = 'NODO_MIAMI_MIDTOWN')
BEGIN
    INSERT INTO dim.NodoConexion (Codigo, Nombre, FranquiciaId, TipoConector, Modo, Estado, Timezone, Moneda, ConvencionImportes, PoliticaDevoluciones, ToleranciaReconciliacion, Activo, ParserId, ConfiguracionJson)
    SELECT 'NODO_MIAMI_MIDTOWN', 'Conector Miami Midtown', f.FranquiciaId, 'FILE_PARSER', 'FILE', 'ACTIVE', 'America/New_York', 'USD', 'VAT_INCLUDED', 'NEGATIVE_LINES', 0.01, 1, p.ParserId, '{"connection_type":"TXT_PARSER","parser_code":"TOAST_HTML"}'
    FROM dim.Franquicia f, cfg.Parser p
    WHERE f.Codigo = 'MIAMI_MIDTOWN' AND p.Codigo = 'TOAST_HTML';
END

-- Verify results
SELECT n.NodoConexionId, n.Codigo, n.Nombre, n.TipoConector, n.ParserId, p.Codigo as ParserCode
FROM dim.NodoConexion n
LEFT JOIN cfg.Parser p ON n.ParserId = p.ParserId
WHERE n.Codigo LIKE '%MIAMI%';
