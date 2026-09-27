/*
================================================================================
  DF Group - Central de Informacion para Franquicias
  Script: 00_create_database.sql
  Descripcion: Crea la base de datos DF_DTW si no existe
  Autor: Claude Code
  Fecha: 2026-07-16

  INSTRUCCIONES:
  - Ejecutar con usuario con permisos de creacion de base de datos (sa o similar)
  - Este script es idempotente: puede ejecutarse multiples veces sin error
================================================================================
*/

USE [master]
GO

-- Verificar si la base de datos existe antes de crearla
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'DF_DTW')
BEGIN
    PRINT 'Creando base de datos DF_DTW...'

    CREATE DATABASE [DF_DTW]
    ON PRIMARY
    (
        NAME = N'DF_DTW',
        FILENAME = N'C:\SQLData\DF_DTW.mdf',  -- Ajustar ruta segun ambiente
        SIZE = 100MB,
        MAXSIZE = UNLIMITED,
        FILEGROWTH = 100MB
    )
    LOG ON
    (
        NAME = N'DF_DTW_log',
        FILENAME = N'C:\SQLData\DF_DTW_log.ldf',  -- Ajustar ruta segun ambiente
        SIZE = 50MB,
        MAXSIZE = 2048GB,
        FILEGROWTH = 50MB
    )

    PRINT 'Base de datos DF_DTW creada exitosamente.'
END
ELSE
BEGIN
    PRINT 'La base de datos DF_DTW ya existe. No se realizaron cambios.'
END
GO

-- Configuraciones basicas de la base de datos
USE [DF_DTW]
GO

-- Configurar el modo de recuperacion
ALTER DATABASE [DF_DTW] SET RECOVERY SIMPLE
GO

-- Habilitar snapshot isolation para evitar bloqueos en lecturas del dashboard
ALTER DATABASE [DF_DTW] SET ALLOW_SNAPSHOT_ISOLATION ON
GO

ALTER DATABASE [DF_DTW] SET READ_COMMITTED_SNAPSHOT ON
GO

PRINT 'Configuracion de base de datos completada.'
GO
