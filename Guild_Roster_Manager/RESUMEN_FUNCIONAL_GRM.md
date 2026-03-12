# Resumen Funcional Completo - Guild Roster Manager

## 1) Sistemas nucleo
- Base de datos por cuenta y por guild, con perfiles de configuracion y guardado en SavedVariables.
- Inicializacion por eventos (`ADDON_LOADED`, `PLAYER_ENTERING_WORLD`) con protecciones de carga.
- Sistema de parches/migraciones para actualizar estructuras antiguas de datos.
- Utilidades globales de tiempo, copias profundas, conteo, listas y validaciones.

## 2) Sistema de escaneo de roster y deteccion de cambios
- Escaneo incremental del roster (incluyendo metodo clasico y metodo Communities/Club API).
- Comparacion de snapshots para detectar altas/bajas/cambios de estado.
- Heartbeat de proteccion para escaneos colgados.
- Deteccion y limpieza de inconsistencias en nombres/realm.

## 3) Sistema de Log de guild (auditoria historica)
- Registra eventos de: promociones, demociones, subidas de nivel, cambios de nota publica/oficial,
  retornos de inactivos, cambios de nombre, joins/rejoins, kicks/leaves y eventos de recomendaciones.
- Reprocesa textos del log para idioma/formato de fecha del usuario.
- Busqueda, filtros y exportacion del log.
- Registro Hardcore de muertes (cuando aplica).

## 4) Sistema de fechas e historial de miembros
- Historial de fecha de ingreso por miembro.
- Historial de cambios de rango (promocion/democion).
- Herramientas para validar fechas no verificadas.
- Herramientas masivas API para fijar/limpiar fechas desconocidas.

## 5) Sistema Alt/Main (y metadatos relacionados)
- Crear grupos de alts, establecer main, remover/editar grupos.
- Obtener main de un alt, validar si un jugador es main/alt.
- Gestion de alts de ex-miembros.
- Auditoria de tamano de grupos (`altlimit X`).

## 6) Sistema de Nicknames
- Nickname por jugador o por grupo alt/main.
- Validacion de formato para evitar caracteres conflictivos.
- Eliminacion y sincronizacion de nickname segun reglas.

## 7) Sistema de Sync distribuido (GRM_GuildSync)
- Sincronizacion de metadata entre usuarios de GRM en la misma guild.
- Control por umbrales de rango para distintos tipos de datos.
- Seguimiento de progreso de sync (tracker/UI).
- Sincronizacion manual por slash command.
- Protecciones de throttling y estado para no saturar canales.

## 8) Interfaz principal y ventanas
- Ventana principal de GRM con pestanas de Log, Audit, Ban, Users, Events, Options, etc.
- Ventana de roster custom (`/roster`) con busqueda/ordenamiento.
- Ventanas de confirmacion reutilizables para acciones criticas.
- Guardado/restauracion de posiciones y escalas de frames.

## 9) Herramientas de gestion masiva (Macro Tool)
- Modos: Kick, Promote, Demote, Special Rules.
- Reglas por inactividad, nivel, rango y filtros custom por rank.
- Construccion de macros por lotes para ejecutar acciones protegidas por Blizzard.
- Generacion de recomendaciones y reportes de acciones sugeridas.

## 10) Sistema de Ban List
- Lista de baneados con soporte de sincronizacion.
- Deteccion de reingreso de baneados y alertas relacionadas.
- Soporte para ban de alts asociados.

## 11) Sistema de Export
- Export de miembros activos y ex-miembros.
- Export del log completo.
- Delimitadores configurables (CSV-like).
- Export de bloques de texto listos para copiar.

## 12) Sistema de backup y restauracion
- Snapshot/backup de datos de guild para transferencias o recuperacion.
- Estructuras `GRM_Restore_Members`, `GRM_Restore_FormerMembers`, `GRM_Restore_Log`.
- API de restauracion de notas publicas/oficiales en masa.
- Comandos de reset parcial/total/hard reset.

## 13) Sistema de calendario y eventos
- Cola de eventos para aniversario y cumpleanos (segun configuracion).
- Integracion con flujo de add-to-calendar del juego cuando corresponde.

## 14) Sistema de profesiones
- Captura y formateo de profesiones/rango.
- Insercion/actualizacion de profesiones en notas (sobre todo Classic Era).
- Reporte de jugadores que no pudieron actualizarse.

## 15) Sistema Hardcore
- Registro de muertes por canales/eventos de Hardcore compatibles.
- Marcado de jugador como muerto y export de etiqueta en nota.
- Reporte al log con fecha/nivel/clase.

## 16) Sistema de Activity Metrics (GRM_ActivityMetrics)
- Recoleccion de mensajes de chat de guild.
- Snapshots de presencia online por hora/dia.
- Metricas por jugador: mensajes totales, conexiones, actividad diaria/30d.
- Feed consolidado para consumo externo (`GRM.GetGuildActivityMetricsFeed`).
- Resumen por jugador (`GRM.GetPlayerActivitySummary`).

## 17) Sistema de minimapa
- Boton minimap custom con drag para posicion.
- Show/Hide y reset de posicion.
- Integracion con Addon Compartment (`GRM_ToggleOptionsWindow`).

## 18) Sistema de hyperlinks internos
- Links clickables tipo `GRM:` en chat.
- Acciones: abrir ventana de jugador, reportes de profesiones, etc.

## 19) Localizacion y tipografia
- Soporte multi-idioma (English, German, French, Italian, Korean, Chinese CN/TW,
  Portuguese, PortugueseBR, Russian, SpanishEU, SpanishMX, Dutch, Danish).
- Slash alternativos localizados (`/XXXX`, `/YYYY`).
- Ajustes de fuente y normalizacion por locale.

## 20) Compatibilidad externa
- Integracion con Chattynator para enrutar reportes de GRM a tabs especificas.
- Habilitar/deshabilitar tabs y crear tabs de Chattynator para GRM.

## 21) API publica y de administracion
- API publica de consulta (`GRM_API.GetMember`, `GetFormerMember`, `GetMemberAlts`, etc.).
- API de toolbox admin: limpiar/restaurar notas masivas, validar fechas, auditar alt groups.
- API de barras de progreso (`GRM_API.CreateNewProgressBar`, etc.).

## 22) Comandos slash soportados (principal)
- Base: `/grm`, `/roster`
- Ayuda/version: `help`, `version`, `ver`
- Reset/reparacion: `clearall`, `clearguild`, `hardreset`, `center/reset`, `minimap`
- Operacion: `sync`, `scan`, `dead`, `guid`, `prof`, `search`, `altlimit X`
- Navegacion de ventanas: `ban`, `audit`, `log`, `users/syncusers`, `event/events`, `opt/options`, `export`, `module/plugin`
- Macro tool: `kick`, `tool`, `promote`, `demote`, `macro`, `special`
- Debug: `debug <N>`

## 23) Archivos presentes pero no integrados plenamente en el flujo principal
- `GRM_AltsImport.lua`: esqueleto de import desde addon "Alts" (funciones vacias actualmente).
- `GRM_Modules.lua`: base para modulos custom; `AddModuleSetting` sin implementar.
- `GRM_Stats.lua`: API de progress bars (marcado como pending feature en comentarios).

## 24) Sub-addon adicional en el repositorio (GuildActivityTracker)
- Existe un addon separado en `GuildActivityTracker/` con su propio `.toc`.
- Incluye UI `/gat`, export, filtros, graficas, tendencias, presencia por rango y sincronizacion `GATSYNC`.
- No esta listado en el `.toc` principal de GRM; opera como modulo/addon aparte cuando se instala/carga por separado.
