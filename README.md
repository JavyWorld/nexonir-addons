# Nexonir WoW Addons

Addons de World of Warcraft para la plataforma [Nexonir.com](https://nexonir.com).

## Addons incluidos

### Guild_Roster_Manager (GRM)
Recopila datos del roster de la hermandad, eventos de actividad, cambios de rango y más. Los datos se guardan en `SavedVariables/Guild_Roster_Manager.lua`.

### GuildActivityTracker (GAT)
Complemento de GRM que trackea datos adicionales de actividad de la guild como milestones, logros y métricas de participación. Los datos se guardan en `SavedVariables/GuildActivityTracker.lua`.

## Instalación

### Automática (recomendada)
[App Nexo](https://app.nexonir.com/gat-uploader/download) instala y actualiza estos addons automáticamente.

### Manual
1. Descarga el último release desde la [página de Releases](https://github.com/JavyWorld/nexonir-addons/releases/latest)
2. Extrae el contenido en tu carpeta de addons de WoW:
   ```
   C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\
   ```
3. Reinicia WoW o escribe `/reload` en el chat

## Estructura

```
nexonir-addons/
  Guild_Roster_Manager/   ← Addon GRM
  GuildActivityTracker/   ← Addon GAT
```

## Versiones

Los releases se crean automáticamente al hacer push de un tag `vX.X.X`. Cada release incluye:
- `Guild_Roster_Manager.zip` — solo el addon GRM
- `GuildActivityTracker.zip` — solo el addon GAT
- `nexonir-addons.zip` — ambos addons combinados
